import Foundation
import CryptoKit

public struct InspectorConfiguration: Sendable, Hashable, Codable {
    /// Untracked files larger than this are left out of the shadow index and the diff.
    public var largeFileLimit: Int64 = 20 * 1024 * 1024
    /// Upper bound on files whose content is scanned for flags in one refresh.
    public var maxContentScanFiles: Int = 150
    public var maxScannedAddedLines: Int = 5000
    public var rules = RuleConfiguration()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = InspectorConfiguration()
        largeFileLimit = c.decode(.largeFileLimit, or: defaults.largeFileLimit)
        maxContentScanFiles = c.decode(.maxContentScanFiles, or: defaults.maxContentScanFiles)
        maxScannedAddedLines = c.decode(.maxScannedAddedLines, or: defaults.maxScannedAddedLines)
        rules = c.decode(.rules, or: defaults.rules)
    }
}

/// One per watched worktree. Owns the shadow index, computes change sets
/// against any baseline, and records snapshots.
///
/// The shadow index is a private git index file kept outside the repository.
/// `git add -A` against it mirrors the working tree (including untracked files)
/// without touching the repository's own index, so `git diff --cached <base>`
/// yields a complete picture of what differs from `base`.
public actor WorktreeInspector {
    public nonisolated let git: GitClient
    public nonisolated let worktree: URL
    public nonisolated let layout: RepoLayout
    public nonisolated let worktreeID: String
    public nonisolated let shadowIndexURL: URL
    public var configuration: InspectorConfiguration
    /// The agents in this worktree as they are now, asked before each discard or restore writes.
    /// Without it nothing is written.
    private let agents: (@Sendable () async -> [WriteGate.Agent])?

    private var emptyTree: String?
    private var defaultBranchValue: String??
    private var defaultBranchFetchedAt: Date?
    private var diffCache: [String: FileDiff] = [:]
    private var contentFlagCache: [String: [AttentionFlag]] = [:]
    /// A commit's files with their flags; commits never change, so only new rules clear it.
    private var commitChangesCache: [String: [FileChange]] = [:]
    private var lastSnapshotTree: String?
    /// HEAD's commit subject, kept while HEAD stays put.
    private var headSubject: (oid: String, subject: String?)?
    private var loadedSnapshotsOnce = false
    /// Whether a writer holds the shadow index (see `exclusively`), and who waits for it, in order.
    private var shadowIndexHeld = false
    private var shadowIndexQueue: [CheckedContinuation<Void, Never>] = []

    public static func worktreeID(for path: URL) -> String {
        let standardized = path.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(standardized.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// `agents` lists the agents in the worktree for the `WriteGate`; with none given, discards
    /// and restores are refused.
    public init(git: GitClient, worktree: URL, shadowIndexDirectory: URL,
                configuration: InspectorConfiguration = InspectorConfiguration(),
                agents: (@Sendable () async -> [WriteGate.Agent])? = nil) async throws {
        let layout = try await git.layout(of: worktree)
        try FileManager.default.createDirectory(at: shadowIndexDirectory, withIntermediateDirectories: true)
        let id = Self.worktreeID(for: layout.topLevel)
        self.git = git
        self.layout = layout
        self.worktree = layout.topLevel
        self.worktreeID = id
        self.shadowIndexURL = shadowIndexDirectory.appendingPathComponent("\(id).index")
        self.configuration = configuration
        self.agents = agents
    }

    public func setConfiguration(_ configuration: InspectorConfiguration) {
        if configuration.rules != self.configuration.rules {
            contentFlagCache.removeAll()
            commitChangesCache.removeAll()
        }
        self.configuration = configuration
    }

    public nonisolated var snapshotRefPrefix: String { "refs/monitor/\(worktreeID)/snapshots/" }
    public nonisolated var startRef: String { "refs/monitor/\(worktreeID)/start" }
    public nonisolated var refNamespace: String { "refs/monitor/\(worktreeID)/" }

    // MARK: One writer at a time

    /// Runs `body` once every writer that asked before it is done, and holds the next one off
    /// until it is. The actor alone doesn't do this: another call gets in at every `await`, and
    /// two `git add` runs on one index fail on git's index.lock. Refreshes, snapshots, discards
    /// and restores all go through here; the methods named `…Locked` expect the caller to.
    private func exclusively<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        if shadowIndexHeld {
            await withCheckedContinuation { shadowIndexQueue.append($0) }
        } else {
            shadowIndexHeld = true
        }
        defer {
            // Handed straight to the next in line, so a newcomer can't get in first.
            if shadowIndexQueue.isEmpty { shadowIndexHeld = false } else { shadowIndexQueue.removeFirst().resume() }
        }
        return try await body()
    }

    // MARK: Refresh

    public func refresh(baseline: Baseline) async throws -> WorktreeState {
        try await exclusively { try await refreshLocked(baseline: baseline) }
    }

    private func refreshLocked(baseline: Baseline) async throws -> WorktreeState {
        // Status first: its list of untracked files saves the shadow index a walk of its own.
        let status = try await git.status(in: worktree)
        let excluded = try await syncShadowIndex(untracked: status.untracked)
        var branch = status.branchInfo
        if let head = branch.headOID {
            // The subject only changes with HEAD.
            if headSubject?.oid != head { headSubject = (head, await git.headSubject(in: worktree)) }
            branch.headSubject = headSubject?.subject
        }
        let headTreeish: String
        if let head = branch.headOID {
            headTreeish = head
        } else {
            headTreeish = try await emptyTreeOID()
        }
        let defaultBranch = await cachedDefaultBranch()
        let resolved = await resolve(baseline, branch: branch, headTreeish: headTreeish, defaultBranch: defaultBranch)

        var primary: [FileChange] = []
        if let base = resolved.treeish {
            primary = try await changes(against: base, status: status)
            try await applyFlags(to: &primary, base: base)
        }
        let headChanges: [FileChange]
        if resolved.treeish == headTreeish {
            headChanges = primary
        } else {
            headChanges = try await changes(against: headTreeish, status: status)
        }
        let tree = try? await git.writeTree(indexFile: shadowIndexURL, in: worktree)

        return WorktreeState(
            timestamp: Date(),
            branch: branch,
            baseline: resolved,
            defaultBranch: defaultBranch,
            changes: primary,
            headChanges: headChanges,
            excludedLargeFiles: excluded,
            shadowTreeOID: tree,
            operation: await operation(status: status))
    }

    /// The merge, rebase, cherry-pick, revert or bisect under way, with its commits named.
    private func operation(status: PorcelainStatus) async -> WorktreeOperation? {
        guard let found = WorktreeOperationReader.read(gitDir: layout.gitDir) else { return nil }
        var operation = found.operation
        operation.conflicted = status.entries.filter(\.isUnmerged).count
        if let onto = found.ontoOID {
            operation.onto = await git.name(pointingAt: onto, in: worktree) ?? String(onto.prefix(7))
        }
        if let incoming = found.incomingOID {
            operation.incoming = await git.commitTitle(incoming, in: worktree) ?? String(incoming.prefix(7))
        }
        return operation
    }

    /// Commits made between two HEADs when the move was a fast-forward; empty otherwise.
    public func commits(from oldHead: String?, to newHead: String?) async -> [CommitSummary] {
        guard let newHead else { return [] }
        guard let oldHead else {
            return await git.commits(from: "", to: newHead, in: worktree).map { CommitSummary(oid: $0.oid, subject: $0.subject) }
        }
        guard await git.isAncestor(oldHead, of: newHead, in: worktree) else { return [] }
        return await git.commits(from: oldHead, to: newHead, in: worktree).map { CommitSummary(oid: $0.oid, subject: $0.subject) }
    }

    /// Commits on HEAD since the baseline, newest first; none when the baseline is HEAD itself.
    public func commits(since state: WorktreeState, limit: Int = 200) async -> [CommitSummary] {
        guard let base = state.baseline.treeish, let head = state.branch.headOID, base != head else { return [] }
        return await git.commits(from: base, to: head, in: worktree, limit: limit).map { CommitSummary(oid: $0.oid, subject: $0.subject) }
    }

    /// Folders git ignores with nothing tracked inside (`.build`, `node_modules`), learned from
    /// changes in them, so later changes there need no git at all. Forgotten when ignore rules change.
    public private(set) var ignoredFolders: Set<String> = []

    /// True when every path is ignored by git, so a refresh can be skipped.
    public func allIgnored(_ relativePaths: [String]) async -> Bool {
        guard !relativePaths.isEmpty else { return false }
        let unknown = relativePaths.filter { !Self.isInside($0, ignoredFolders) }
        if unknown.isEmpty { return true }
        // Ask about each path's folders too: the shallowest one ignored is the folder to remember.
        var asked = Set(unknown)
        for path in unknown.prefix(200) {
            for folder in Self.folders(of: path).prefix(4) { asked.insert(folder + "/") }
        }
        let ignored = await git.ignoredPaths(among: Array(asked), in: worktree)
        var learned = Set<String>()
        for path in unknown where ignored.contains(path) {
            if let folder = Self.folders(of: path).first(where: { ignored.contains($0 + "/") }) { learned.insert(folder) }
        }
        if !learned.isEmpty {
            // A folder git still tracks files in keeps being watched.
            let tracked = await git.trackedFiles(under: Array(learned), in: worktree)
            learned = learned.filter { folder in !tracked.contains { $0.hasPrefix(folder + "/") } }
            if ignoredFolders.count + learned.count > 500 { ignoredFolders = [] }
            ignoredFolders.formUnion(learned)
        }
        return unknown.allSatisfy { ignored.contains($0) }
    }

    /// Ignore rules changed (a `.gitignore` or `info/exclude` was edited): learn the folders again.
    public func forgetIgnoredFolders() {
        ignoredFolders = []
    }

    /// Whether `path` (relative) is one of `ignored` or inside one.
    public nonisolated static func isInside(_ path: String, _ ignored: Set<String>) -> Bool {
        guard !ignored.isEmpty else { return false }
        if ignored.contains(path) { return true }
        return folders(of: path).contains { ignored.contains($0) }
    }

    /// The folders a relative path sits in, outermost first: "a/b/c.o" → ["a", "a/b"].
    nonisolated static func folders(of path: String) -> [String] {
        var result: [String] = []
        var index = path.startIndex
        while let slash = path[index...].firstIndex(of: "/") {
            result.append(String(path[..<slash]))
            index = path.index(after: slash)
        }
        return result
    }

    // MARK: Diffs

    public func diff(for change: FileChange, base: String) async throws -> FileDiff? {
        let key = change.contentKey
        if let cached = diffCache[key] { return cached }
        var paths = [change.path]
        if let old = change.oldPath { paths.append(old) }
        let patch = try await git.patch(base: base, paths: paths, indexFile: shadowIndexURL, in: worktree)
        let diffs = DiffParser.parse(patch)
        let diff = diffs.first { $0.path == change.path } ?? diffs.first
        if let diff {
            diffCache[key] = diff
            trimCaches()
        }
        return diff
    }

    /// What changed in a file since the version you reviewed: that blob against the current one.
    /// Nil when the file is gone or the reviewed blob is no longer in the object store
    /// (unreferenced objects are eventually pruned by `git gc`).
    public func diffSinceReview(for change: FileChange, reviewedBlob: String) async throws -> FileDiff? {
        guard let current = change.newOID else { return nil }
        let key = "review|\(reviewedBlob)|\(current)|\(change.path)"
        if let cached = diffCache[key] { return cached }
        guard await git.objectExists(reviewedBlob, in: worktree) else { return nil }
        let patch = try await git.blobPatch(from: reviewedBlob, to: current, in: worktree)
        // Identical content (a mode-only change, say) yields no patch at all.
        var diff = DiffParser.parse(patch).first ?? FileDiff()
        diff.oldPath = change.path
        diff.newPath = change.path
        // git names the sides after the blob ids; relabel them so a copied patch applies.
        diff.headerLines = ["diff --git a/\(change.path) b/\(change.path)"]
            + diff.headerLines.filter { $0.hasPrefix("index ") }
            + ["--- a/\(change.path)", "+++ b/\(change.path)"]
        diff.isNewFile = false
        diff.isDeletedFile = false
        diff.isRename = false
        diffCache[key] = diff
        trimCaches()
        return diff
    }

    // MARK: Commits

    /// The branch's history for the Commits list: what it added since it left the default branch
    /// (or, on that branch, since its upstream), then up to `limit` earlier commits.
    public func history(branch: BranchInfo, limit: Int = 100) async throws -> CommitHistory {
        guard let head = branch.headOID else { return CommitHistory() }
        var reference: String? = nil
        var base: String? = nil
        if let defaultBranch = await cachedDefaultBranch() {
            let onDefault = branch.branch == defaultBranch || branch.branch.map { "origin/\($0)" == defaultBranch } == true
            if let candidate = onDefault ? branch.upstream : defaultBranch,
               let mergeBase = await git.mergeBase(candidate, head, in: worktree) {
                reference = candidate
                base = mergeBase
            }
        }
        var since: [CommitRecord] = []
        if let base { since = try await git.log(head, excluding: base, limit: 500, in: worktree) }
        let from = base ?? head
        let earlier = try await git.log(from, limit: limit, in: worktree)
        return CommitHistory(head: head, reference: reference, sinceBranchPoint: since, earlier: earlier,
                             earlierFrom: from, hasMore: earlier.count == limit)
    }

    /// `history` with up to `limit` more of its earlier commits.
    public func loadingMore(of history: CommitHistory, limit: Int = 100) async throws -> CommitHistory {
        guard let from = history.earlierFrom, history.hasMore else { return history }
        let more = try await git.log(from, limit: limit, skip: history.earlier.count, in: worktree)
        var extended = history
        extended.earlier += more
        extended.hasMore = more.count == limit
        return extended
    }

    /// One commit, for a revision such as an abbreviated id; nil when it does not resolve.
    public func commit(_ revision: String) async -> CommitRecord? {
        try? await git.log(revision, limit: 1, in: worktree).first
    }

    public func message(of commit: CommitRecord) async -> String? {
        await git.commitMessage(commit.oid, in: worktree)
    }

    /// The files a commit changed against its first parent (an empty tree for the first commit),
    /// with the same flags a working-tree change gets, except for file size.
    public func changes(in commit: CommitRecord) async throws -> [FileChange] {
        if let cached = commitChangesCache[commit.oid] { return cached }
        let parent = try await parentTreeish(of: commit)
        async let rawTask = git.treeRawDiff(from: parent, to: commit.oid, in: worktree)
        async let numstatTask = git.treeNumstat(from: parent, to: commit.oid, in: worktree)
        let (raw, numstats) = try await (rawTask, numstatTask)
        var numstatByPath: [String: NumstatEntry] = [:]
        for entry in numstats { numstatByPath[entry.path] = entry }
        var changes = raw.map { entry in
            let numstat = numstatByPath[entry.path]
            return FileChange(
                path: entry.path,
                oldPath: entry.oldPath,
                kind: ChangeKind(rawStatus: entry.status),
                oldMode: entry.oldMode,
                newMode: entry.newMode,
                oldOID: entry.isNullOld ? nil : entry.oldOID,
                newOID: entry.isNullNew ? nil : entry.newOID,
                additions: numstat?.additions,
                deletions: numstat?.deletions,
                isBinary: numstat?.isBinary ?? false)
        }
        let commitOID = commit.oid
        try await applyFlags(to: &changes, sizeOnDisk: false) { paths in
            try await self.git.treePatch(from: parent, to: commitOID, paths: paths, in: self.worktree)
        }
        commitChangesCache[commit.oid] = changes
        if commitChangesCache.count > 200 { commitChangesCache.removeAll() }
        return changes
    }

    /// A file's diff in a commit, against the commit's first parent.
    public func diff(for change: FileChange, in commit: CommitRecord) async throws -> FileDiff? {
        let key = change.contentKey
        if let cached = diffCache[key] { return cached }
        var paths = [change.path]
        if let old = change.oldPath { paths.append(old) }
        let patch = try await git.treePatch(from: try await parentTreeish(of: commit), to: commit.oid, paths: paths, in: worktree)
        let diffs = DiffParser.parse(patch)
        let diff = diffs.first { $0.path == change.path } ?? diffs.first
        if let diff {
            diffCache[key] = diff
            trimCaches()
        }
        return diff
    }

    private func parentTreeish(of commit: CommitRecord) async throws -> String {
        if let parent = commit.parents.first { return parent }
        return try await emptyTreeOID()
    }

    // MARK: Snapshots

    public func snapshots() async -> [SnapshotRecord] {
        let records = (try? await git.refRecords(withPrefix: refNamespace, in: worktree)) ?? []
        let startOID = records.first { $0.name == startRef }?.oid
        var result: [SnapshotRecord] = []
        for record in records where record.name.hasPrefix(snapshotRefPrefix) {
            let millis = Double(record.name.dropFirst(snapshotRefPrefix.count)) ?? (record.date.timeIntervalSince1970 * 1000)
            result.append(SnapshotRecord(id: record.name, commitOID: record.oid, treeOID: record.tree,
                                         date: Date(timeIntervalSince1970: millis / 1000), isStart: record.oid == startOID))
        }
        if let startOID, let startRecord = records.first(where: { $0.name == startRef }),
           !result.contains(where: { $0.commitOID == startOID }) {
            result.append(SnapshotRecord(id: startRef, commitOID: startOID, treeOID: startRecord.tree,
                                         date: startRecord.date, isStart: true))
        }
        result.sort { $0.date > $1.date }
        if !loadedSnapshotsOnce {
            loadedSnapshotsOnce = true
            if lastSnapshotTree == nil { lastSnapshotTree = result.first?.treeOID }
        }
        return result
    }

    /// Records the current working tree. Returns nil when nothing changed since the last snapshot
    /// (unless `force` or `markStart`).
    @discardableResult
    public func takeSnapshot(markStart: Bool = false, force: Bool = false) async throws -> SnapshotRecord? {
        try await exclusively { try await takeSnapshotLocked(markStart: markStart, force: force) }
    }

    private func takeSnapshotLocked(markStart: Bool = false, force: Bool = false) async throws -> SnapshotRecord? {
        _ = try await syncShadowIndex()
        let tree = try await git.writeTree(indexFile: shadowIndexURL, in: worktree)
        if !markStart, !force, tree == lastSnapshotTree { return nil }
        let head = await git.revParse("HEAD", in: worktree)
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)
        let commit = try await git.commitTree(tree: tree, parent: head,
                                              message: markStart ? "Mimamori start marker \(stamp)" : "Mimamori snapshot \(stamp)",
                                              in: worktree)
        let ref = snapshotRefPrefix + String(Int(now.timeIntervalSince1970 * 1000))
        try await git.updateRef(ref, to: commit, in: worktree)
        if markStart {
            try await git.updateRef(startRef, to: commit, in: worktree)
        }
        lastSnapshotTree = tree
        return SnapshotRecord(id: ref, commitOID: commit, treeOID: tree, date: now, isStart: markStart)
    }

    public func clearStartMarker() async throws {
        try await exclusively { try await git.deleteRef(startRef, in: worktree) }
    }

    /// Keeps the newest `keep` snapshots.
    public func pruneSnapshots(keep: Int) async {
        await exclusively {
            let all = await snapshots().filter { $0.id.hasPrefix(snapshotRefPrefix) }
            guard all.count > keep else { return }
            for record in all.dropFirst(keep) {
                try? await git.deleteRef(record.id, in: worktree)
            }
        }
    }

    /// Disk space only this worktree's snapshots use, which deleting them frees once git collects
    /// its garbage; nil when git cannot say (before 2.38).
    public func snapshotDiskUsage() async -> Int64? {
        try? await git.exclusiveDiskUsage(ofRefsUnder: refNamespace, in: worktree)
    }

    public func deleteAllSnapshots() async {
        await exclusively {
            let records = (try? await git.refRecords(withPrefix: refNamespace, in: worktree)) ?? []
            for record in records {
                try? await git.deleteRef(record.name, in: worktree)
            }
            lastSnapshotTree = nil
        }
    }

    // MARK: Discarding changes

    /// Throws away one hunk of an uncommitted change, putting its lines back as HEAD has them.
    /// `change` is the change the hunk's diff was made from. Nothing is written while an agent here
    /// is mid-turn (`WriteGate`), nor unless the file on disk is still that version byte for byte,
    /// HEAD still has the other, and git agrees the hunk comes out cleanly. Then a snapshot is
    /// recorded, and Mimamori writes that one file: the same bytes with only the hunk's lines
    /// swapped, never the index.
    public func discard(_ hunk: DiffHunk, of change: FileChange) async throws -> DiscardedChange {
        try await exclusively { try await discardLocked(hunk, of: change) }
    }

    private func discardLocked(_ hunk: DiffHunk, of change: FileChange) async throws -> DiscardedChange {
        try await requireWriteGate()
        if let reason = Discarding.hunkUnsupportedReason(for: change) { throw HunkDiscardError.unsupported(reason) }
        guard let oldOID = change.oldOID, let newOID = change.newOID else {
            throw HunkDiscardError.unsupported("This kind of change can't be discarded a hunk at a time.")
        }
        let url = try fileURL(for: change.path)
        let original = try await currentContents(of: url, path: change.path, expecting: newOID)
        guard await git.blobOID(at: "HEAD", path: change.oldPath ?? change.path, in: worktree) == oldOID else {
            throw HunkDiscardError.headMoved
        }
        let oldBlob = try await git.blob(oldOID, in: worktree)
        let patch = try HunkPatch.build(path: change.path, hunk: hunk, old: oldBlob, new: original)
        let result = try HunkPatch.discarding(hunk, old: oldBlob, new: original)
        do {
            try await git.applyToWorkingTree(patch.discard, reverse: true, checkOnly: true, in: worktree)
        } catch let error as GitError {
            throw HunkDiscardError.doesNotApply(error.stderr)
        }
        let snapshot = try await snapshotHolding(change.path, blob: newOID)
        try await requireWriteGate()
        let permissions = Self.permissions(of: url)
        try Self.replace(url, expecting: original, with: result, permissions: permissions)
        return DiscardedChange(path: change.path, date: snapshot.date, scope: .hunk(header: hunk.header, patch: patch),
                               additions: hunk.additions, deletions: hunk.deletions, snapshot: snapshot,
                               originalBlob: newOID, originalPermissions: permissions, resultDigest: Self.digest(result))
    }

    /// Puts a whole uncommitted file back as HEAD has it: a changed file gets HEAD's bytes and
    /// mode, a new file goes (to the Trash, unless `trashNewFiles` is off), a deleted file is
    /// written again. Nothing is written while an agent here is mid-turn, nor unless the file is
    /// still the version the diff was made from and HEAD still has the other; then a snapshot is
    /// recorded first, holding the file.
    public func discardFile(_ change: FileChange, trashNewFiles: Bool = true) async throws -> DiscardedChange {
        try await exclusively { try await discardFileLocked(change, trashNewFiles: trashNewFiles) }
    }

    private func discardFileLocked(_ change: FileChange, trashNewFiles: Bool) async throws -> DiscardedChange {
        try await requireWriteGate()
        if let reason = Discarding.fileUnsupportedReason(for: change) { throw HunkDiscardError.unsupported(reason) }
        let url = try fileURL(for: change.path)
        guard await git.blobOID(at: "HEAD", path: change.path, in: worktree) == change.oldOID else {
            throw HunkDiscardError.headMoved
        }
        var original: Data? = nil
        if let newOID = change.newOID {
            original = try await currentContents(of: url, path: change.path, expecting: newOID)
        } else if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
            // Deleted when the diff was made, and something is there now.
            throw HunkDiscardError.fileChanged
        }
        var result: Data? = nil
        if let oldOID = change.oldOID {
            let blob = try await git.blob(oldOID, in: worktree)
            // Written as is, so it must be what git itself would write.
            guard try await git.filteredBlob(oldOID, path: change.path, in: worktree) == blob else {
                throw HunkDiscardError.converted
            }
            result = blob
        }
        let snapshot: SnapshotRecord
        if let newOID = change.newOID {
            snapshot = try await snapshotHolding(change.path, blob: newOID)
        } else {
            guard let taken = try await takeSnapshotLocked(force: true) else { throw HunkDiscardError.fileChanged }
            snapshot = taken
        }
        try await requireWriteGate()
        let permissions = Self.permissions(of: url)
        switch (original, result) {
        case (let original?, let result?):
            try Self.replace(url, expecting: original, with: result,
                             permissions: Self.permissions(permissions ?? 0o644, mode: change.oldMode))
        case (let original?, nil):
            try Self.remove(url, expecting: original, trash: trashNewFiles)
        case (nil, let result?):
            try Self.create(url, with: result, permissions: Self.permissions(0o644, mode: change.oldMode))
        case (nil, nil):
            throw HunkDiscardError.unsupported("This kind of change can't be discarded.")
        }
        return DiscardedChange(path: change.path, date: snapshot.date, scope: .file(change.kind),
                               additions: change.additions ?? 0, deletions: change.deletions ?? 0, snapshot: snapshot,
                               originalBlob: change.newOID, originalPermissions: permissions,
                               resultDigest: result.map(Self.digest))
    }

    /// Puts a discarded change back, after a snapshot, unless an agent here is mid-turn. A file
    /// still as the discard left it gets its earlier bytes back exactly. A hunk's file changed
    /// since gets the hunk's lines wherever their surroundings still match, as `git apply` places
    /// them; a whole file changed since is left alone, since putting it back would lose the change.
    public func restore(_ discarded: DiscardedChange) async throws -> DiscardRestore {
        try await exclusively { try await restoreLocked(discarded) }
    }

    private func restoreLocked(_ discarded: DiscardedChange) async throws -> DiscardRestore {
        try await requireWriteGate()
        let url = try fileURL(for: discarded.path)
        let exists = (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
        let current = exists ? try Self.contents(of: url) : nil
        let untouched = current.map(Self.digest) == discarded.resultDigest
        if untouched {
            let snapshot = try await takeSnapshotLocked(force: true)
            guard let snapshot else { throw HunkDiscardError.fileChanged }
            var original: Data? = nil
            if let blob = discarded.originalBlob { original = try await git.blob(blob, in: worktree) }
            try await requireWriteGate()
            switch (original, current) {
            case (let original?, let current?):
                try Self.replace(url, expecting: current, with: original, permissions: discarded.originalPermissions)
            case (let original?, nil):
                try Self.create(url, with: original, permissions: discarded.originalPermissions ?? 0o644)
            case (nil, let current?):
                try Self.remove(url, expecting: current, trash: false)
            case (nil, nil):
                break
            }
            return DiscardRestore(exact: true, snapshot: snapshot)
        }
        guard case .hunk(_, let patch) = discarded.scope, current != nil else { throw HunkDiscardError.restoreBlocked }
        do {
            try await git.applyToWorkingTree(patch.restore, reverse: false, checkOnly: true, in: worktree)
        } catch let error as GitError {
            throw HunkDiscardError.restoreDoesNotApply(error.stderr)
        }
        guard let snapshot = try await takeSnapshotLocked(force: true) else { throw HunkDiscardError.fileChanged }
        try await requireWriteGate()
        do {
            try await git.applyToWorkingTree(patch.restore, reverse: false, checkOnly: false, in: worktree)
        } catch let error as GitError {
            throw HunkDiscardError.restoreDoesNotApply(error.stderr)
        }
        return DiscardRestore(exact: false, snapshot: snapshot)
    }

    /// Throws the `WriteGate`'s reason while an agent here is mid-turn. Asked first, so a refusal
    /// leaves no snapshot behind, and again with nothing left to await before the write, since a
    /// turn may start while the write waits its turn or takes its snapshot.
    private func requireWriteGate() async throws {
        guard let agents else {
            throw HunkDiscardError.refused("Mimamori can't tell which agents are in this worktree, so it won't write to it.")
        }
        if let reason = WriteGate(await agents()).refusal { throw HunkDiscardError.refused(reason) }
    }

    /// The file's bytes, provided they are exactly the blob the diff was made from.
    private func currentContents(of url: URL, path: String, expecting blob: String) async throws -> Data {
        let contents = try Self.contents(of: url)
        guard contents == (try await git.blob(blob, in: worktree)) else {
            // The same blob once git's filters have had their way, or another version altogether.
            let hashed = try? await git.hashObject(path: path, in: worktree)
            throw hashed == blob ? HunkDiscardError.converted : HunkDiscardError.fileChanged
        }
        return contents
    }

    /// A snapshot taken now, checked to hold `path` as `blob`, so the discard can always be undone.
    private func snapshotHolding(_ path: String, blob: String) async throws -> SnapshotRecord {
        guard let snapshot = try await takeSnapshotLocked(force: true),
              await git.blobOID(at: snapshot.commitOID, path: path, in: worktree) == blob else {
            throw HunkDiscardError.notInSnapshot
        }
        return snapshot
    }

    /// A repository-relative path as a file URL, refused when it leads out of the worktree. The
    /// file need not exist: its nearest folder that does is where links are followed from.
    private func fileURL(for path: String) throws -> URL {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else { throw HunkDiscardError.notAFile }
        let url = worktree.appendingPathComponent(path)
        var existing = url
        var rest: [String] = []
        while (try? FileManager.default.attributesOfItem(atPath: existing.path)) == nil, existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        for component in rest { resolved.appendPathComponent(component) }
        let root = worktree.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { throw HunkDiscardError.notAFile }
        return url
    }

    /// A plain file's bytes; anything else (a link, a folder, nothing) is refused.
    private static func contents(of url: URL) throws -> Data {
        guard let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
              type == .typeRegular, let data = try? Data(contentsOf: url) else { throw HunkDiscardError.notAFile }
        return data
    }

    private static func permissions(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    /// `permissions` with the executable bits a git mode asks for.
    private static func permissions(_ permissions: Int, mode: String) -> Int {
        switch mode {
        case "100755": permissions | ((permissions & 0o444) >> 2)
        case "100644": permissions & ~0o111
        default: permissions
        }
    }

    /// Writes `data` over the file in one step, with `permissions`, provided it still holds
    /// `expected`: a write since the checks wins over the discard.
    private static func replace(_ url: URL, expecting expected: Data, with data: Data, permissions: Int?) throws {
        guard try contents(of: url) == expected else { throw HunkDiscardError.fileChanged }
        try data.write(to: url, options: .atomic)
        if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    }

    /// Writes a file where there is none, making its folders as needed.
    private static func create(_ url: URL, with data: Data, permissions: Int) throws {
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else { throw HunkDiscardError.fileChanged }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .withoutOverwriting)
        try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    /// Removes the file, to the Trash when `trash`, provided it still holds `expected`.
    private static func remove(_ url: URL, expecting expected: Data, trash: Bool) throws {
        guard try contents(of: url) == expected else { throw HunkDiscardError.fileChanged }
        if trash, (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Internals

    /// Brings the shadow index up to the working tree, leaving out untracked files over the size
    /// limit. `untracked` is the list from a status just run, if there is one.
    private func syncShadowIndex(untracked known: [String]? = nil) async throws -> [String] {
        var excluded: [String] = []
        let listed: [String]?
        if let known { listed = known } else { listed = try? await git.untrackedFiles(in: worktree) }
        let untracked = listed ?? []
        if !untracked.isEmpty {
            let limit = configuration.largeFileLimit
            for path in untracked {
                let url = worktree.appendingPathComponent(path)
                if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                   let size = values.fileSize, Int64(size) > limit {
                    excluded.append(path)
                }
            }
        }
        try await git.shadowAddAll(indexFile: shadowIndexURL, excluding: excluded, in: worktree)
        return excluded
    }

    private func emptyTreeOID() async throws -> String {
        if let emptyTree { return emptyTree }
        let oid = try await git.emptyTreeOID(in: worktree)
        emptyTree = oid
        return oid
    }

    private func cachedDefaultBranch() async -> String? {
        if let fetched = defaultBranchFetchedAt, Date().timeIntervalSince(fetched) < 120, let cached = defaultBranchValue {
            return cached
        }
        let value = await git.defaultBranch(in: worktree)
        defaultBranchValue = .some(value)
        defaultBranchFetchedAt = Date()
        return value
    }

    private func resolve(_ baseline: Baseline, branch: BranchInfo, headTreeish: String, defaultBranch: String?) async -> ResolvedBaseline {
        func unavailable(_ reason: String) -> ResolvedBaseline {
            ResolvedBaseline(baseline: baseline, treeish: nil, label: baseline.title, unavailableReason: reason)
        }
        switch baseline {
        case .head:
            let label = branch.shortHead.map { "HEAD \($0)" } ?? "empty repository"
            return ResolvedBaseline(baseline: .head, treeish: headTreeish, label: label)

        case .branchPoint:
            guard let head = branch.headOID else { return unavailable("The repository has no commits yet.") }
            guard let defaultBranch else { return unavailable("No default branch (main or master) was found.") }
            var reference = defaultBranch
            let onDefault = branch.branch == defaultBranch || branch.branch.map { "origin/\($0)" == defaultBranch } == true
            if onDefault {
                guard let upstream = branch.upstream else {
                    return unavailable("HEAD is on \(defaultBranch) and has no upstream to compare with.")
                }
                reference = upstream
            }
            guard let base = await git.mergeBase(reference, head, in: worktree) else {
                return unavailable("No common ancestor with \(reference).")
            }
            return ResolvedBaseline(baseline: .branchPoint, treeish: base,
                                    label: "since \(reference) at \(base.prefix(7))")

        case .start:
            guard let oid = await git.revParse(startRef, in: worktree) else {
                return unavailable("No start marker yet. Use Mark Start when you launch the agent.")
            }
            let date = await git.commitDate(oid, in: worktree)
            let when = date.map { Self.timeFormatter.string(from: $0) } ?? String(oid.prefix(7))
            return ResolvedBaseline(baseline: .start, treeish: oid, label: "since start at \(when)")

        case .snapshot(let ref):
            guard let oid = await git.revParse(ref, in: worktree) else {
                return unavailable("That snapshot no longer exists.")
            }
            let millis = Double(ref.dropFirst(snapshotRefPrefix.count))
            let when = millis.map { Self.timeFormatter.string(from: Date(timeIntervalSince1970: $0 / 1000)) } ?? String(oid.prefix(7))
            return ResolvedBaseline(baseline: baseline, treeish: oid, label: "since snapshot at \(when)")
        }
    }

    private func changes(against base: String, status: PorcelainStatus) async throws -> [FileChange] {
        let (raw, numstats) = try await git.rawDiffAndNumstat(base: base, indexFile: shadowIndexURL, in: worktree)
        let isUntracked = status.untrackedLookup()

        var numstatByPath: [String: NumstatEntry] = [:]
        for entry in numstats { numstatByPath[entry.path] = entry }
        var statusByPath: [String: StatusEntry] = [:]
        for entry in status.entries { statusByPath[entry.path] = entry }

        return raw.map { entry in
            let numstat = numstatByPath[entry.path]
            let statusEntry = statusByPath[entry.path]
            return FileChange(
                path: entry.path,
                oldPath: entry.oldPath,
                // Unmerged, whatever the comparison with the baseline makes of it.
                kind: statusEntry?.isUnmerged == true ? .unmerged : ChangeKind(rawStatus: entry.status),
                oldMode: entry.oldMode,
                newMode: entry.newMode,
                oldOID: entry.isNullOld ? nil : entry.oldOID,
                newOID: entry.isNullNew ? nil : entry.newOID,
                additions: numstat?.additions,
                deletions: numstat?.deletions,
                isBinary: numstat?.isBinary ?? false,
                isUntracked: isUntracked(entry.path),
                isStaged: statusEntry?.isStaged ?? false,
                hasConflict: statusEntry?.isUnmerged ?? false)
        }
    }

    private func applyFlags(to changes: inout [FileChange], base: String) async throws {
        try await applyFlags(to: &changes, sizeOnDisk: true) { paths in
            try await self.git.patch(base: base, paths: paths, indexFile: self.shadowIndexURL, in: self.worktree)
        }
    }

    /// Flags `changes` by path and content. `patch` gives the unified diff for some paths;
    /// `sizeOnDisk` reads file sizes from the working tree, which only fits working-tree changes.
    private func applyFlags(to changes: inout [FileChange], sizeOnDisk: Bool,
                            patch: ([String]) async throws -> String) async throws {
        let rules = configuration.rules
        var pending: [(index: Int, key: String)] = []

        for index in changes.indices {
            let change = changes[index]
            var size: Int64? = nil
            if sizeOnDisk, change.newOID != nil, !change.isSubmodule {
                let url = worktree.appendingPathComponent(change.path)
                if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let fileSize = values.fileSize {
                    size = Int64(fileSize)
                }
            }
            var flags = AttentionRules.pathFlags(for: change, config: rules, fileSize: size)
            if change.hasConflict, rules.isEnabled(.conflictMarkers) {
                flags.append(AttentionFlag(rule: .conflictMarkers, message: "Unresolved merge conflict"))
            }
            let needsScan = change.newOID != nil && !change.isBinary && change.kind != .deleted
                && !change.isSubmodule && (change.additions ?? 0) > 0
            if needsScan {
                if let cached = contentFlagCache[change.contentKey] {
                    flags += cached
                } else {
                    pending.append((index, change.contentKey))
                }
            }
            changes[index].flags = flags
        }

        guard !pending.isEmpty else { return }
        let batch = Array(pending.prefix(configuration.maxContentScanFiles))
        var paths: [String] = []
        for item in batch {
            paths.append(changes[item.index].path)
            if let old = changes[item.index].oldPath { paths.append(old) }
        }
        var diffsByPath: [String: FileDiff] = [:]
        for diff in DiffParser.parse(try await patch(paths)) { diffsByPath[diff.path] = diff }

        for item in batch {
            let change = changes[item.index]
            var flags: [AttentionFlag] = []
            if let diff = diffsByPath[change.path] {
                diffCache[item.key] = diff
                flags = AttentionRules.contentFlags(in: diff, config: rules, maxLines: configuration.maxScannedAddedLines)
            }
            contentFlagCache[item.key] = flags
            changes[item.index].flags += flags
        }
        trimCaches()
    }

    private func trimCaches() {
        if diffCache.count > 400 { diffCache.removeAll() }
        if contentFlagCache.count > 4000 { contentFlagCache.removeAll() }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

public struct RefRecord: Sendable, Hashable {
    public var name: String
    public var oid: String
    public var tree: String
    public var date: Date
}

extension GitClient {
    /// Tracked files under the given folders, relative to the worktree.
    public func trackedFiles(under folders: [String], in worktree: URL) async -> [String] {
        guard !folders.isEmpty, let result = try? await run(["ls-files", "-z", "--"] + folders, in: worktree) else { return [] }
        return result.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Refs with their commit, tree and committer date in one call.
    public func refRecords(withPrefix prefix: String, in worktree: URL) async throws -> [RefRecord] {
        let result = try await run(
            ["for-each-ref", "--format=%(refname)%09%(objectname)%09%(tree)%09%(committerdate:unix)", prefix],
            in: worktree)
        return result.stdoutText.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 4 else { return nil }
            let seconds = TimeInterval(parts[3]) ?? 0
            return RefRecord(name: String(parts[0]), oid: String(parts[1]), tree: String(parts[2]),
                             date: Date(timeIntervalSince1970: seconds))
        }
    }
}
