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
    private var lastSnapshotTree: String?
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
        }
        self.configuration = configuration
    }

    public nonisolated var snapshotRefPrefix: String { "refs/monitor/\(worktreeID)/snapshots/" }
    public nonisolated var startRef: String { "refs/monitor/\(worktreeID)/start" }
    public nonisolated var refNamespace: String { "refs/monitor/\(worktreeID)/" }

    // MARK: Refresh

    public func refresh(baseline: Baseline) async throws -> WorktreeState {
        let excluded = try await syncShadowIndex()
        let status = try await git.status(in: worktree)
        var branch = status.branchInfo
        if branch.headOID != nil {
            branch.headSubject = await git.headSubject(in: worktree)
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
            shadowTreeOID: tree)
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

    /// True when every path is ignored by git, so a refresh can be skipped.
    public func allIgnored(_ relativePaths: [String]) async -> Bool {
        guard !relativePaths.isEmpty else { return false }
        let ignored = await git.ignoredPaths(among: relativePaths, in: worktree)
        return relativePaths.allSatisfy { ignored.contains($0) }
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
                                              message: markStart ? "Vigil start marker \(stamp)" : "Vigil snapshot \(stamp)",
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

    public func deleteAllSnapshots() async {
        let records = (try? await git.refRecords(withPrefix: refNamespace, in: worktree)) ?? []
        for record in records {
            try? await git.deleteRef(record.name, in: worktree)
        }
        lastSnapshotTree = nil
    }

    // MARK: Internals

    private func syncShadowIndex() async throws -> [String] {
        var excluded: [String] = []
        let untracked = (try? await git.untrackedFiles(in: worktree)) ?? []
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
        async let rawTask = git.rawDiff(base: base, indexFile: shadowIndexURL, in: worktree)
        async let numstatTask = git.numstat(base: base, indexFile: shadowIndexURL, in: worktree)
        let (raw, numstats) = try await (rawTask, numstatTask)

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
                kind: ChangeKind(rawStatus: entry.status),
                oldMode: entry.oldMode,
                newMode: entry.newMode,
                oldOID: entry.isNullOld ? nil : entry.oldOID,
                newOID: entry.isNullNew ? nil : entry.newOID,
                additions: numstat?.additions,
                deletions: numstat?.deletions,
                isBinary: numstat?.isBinary ?? false,
                isUntracked: status.isUntracked(entry.path),
                isStaged: statusEntry?.isStaged ?? false,
                hasConflict: statusEntry?.isUnmerged ?? false)
        }
    }

    private func applyFlags(to changes: inout [FileChange], base: String) async throws {
        let rules = configuration.rules
        var pending: [(index: Int, key: String)] = []

        for index in changes.indices {
            let change = changes[index]
            var size: Int64? = nil
            if change.newOID != nil, !change.isSubmodule {
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
        let patch = try await git.patch(base: base, paths: paths, indexFile: shadowIndexURL, in: worktree)
        var diffsByPath: [String: FileDiff] = [:]
        for diff in DiffParser.parse(patch) { diffsByPath[diff.path] = diff }

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
