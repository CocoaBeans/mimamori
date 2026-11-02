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

    public static func worktreeID(for path: URL) -> String {
        let standardized = path.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(standardized.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public init(git: GitClient, worktree: URL, shadowIndexDirectory: URL, configuration: InspectorConfiguration = InspectorConfiguration()) async throws {
        let layout = try await git.layout(of: worktree)
        try FileManager.default.createDirectory(at: shadowIndexDirectory, withIntermediateDirectories: true)
        let id = Self.worktreeID(for: layout.topLevel)
        self.git = git
        self.layout = layout
        self.worktree = layout.topLevel
        self.worktreeID = id
        self.shadowIndexURL = shadowIndexDirectory.appendingPathComponent("\(id).index")
        self.configuration = configuration
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

    // MARK: Refresh

    public func refresh(baseline: Baseline) async throws -> WorktreeState {
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
        try await git.deleteRef(startRef, in: worktree)
    }

    /// Keeps the newest `keep` snapshots.
    public func pruneSnapshots(keep: Int) async {
        let all = await snapshots().filter { $0.id.hasPrefix(snapshotRefPrefix) }
        guard all.count > keep else { return }
        for record in all.dropFirst(keep) {
            try? await git.deleteRef(record.id, in: worktree)
        }
    }

    /// Disk space only this worktree's snapshots use, which deleting them frees once git collects
    /// its garbage; nil when git cannot say (before 2.38).
    public func snapshotDiskUsage() async -> Int64? {
        try? await git.exclusiveDiskUsage(ofRefsUnder: refNamespace, in: worktree)
    }

    public func deleteAllSnapshots() async {
        let records = (try? await git.refRecords(withPrefix: refNamespace, in: worktree)) ?? []
        for record in records {
            try? await git.deleteRef(record.name, in: worktree)
        }
        lastSnapshotTree = nil
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
