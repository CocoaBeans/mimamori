import Foundation

/// Where a worktree's git data lives.
public struct RepoLayout: Hashable, Sendable {
    public var topLevel: URL
    public var gitDir: URL
    public var commonDir: URL
    /// "sha1" or "sha256".
    public var objectFormat: String

    public init(topLevel: URL, gitDir: URL, commonDir: URL, objectFormat: String) {
        self.topLevel = topLevel
        self.gitDir = gitDir
        self.commonDir = commonDir
        self.objectFormat = objectFormat
    }

    public var isLinkedWorktree: Bool {
        gitDir.standardizedFileURL.path != commonDir.standardizedFileURL.path
    }
}

/// One entry from `git worktree list`.
public struct WorktreeInfo: Identifiable, Hashable, Sendable, Codable {
    public var id: String { path }
    public var path: String
    public var headOID: String?
    /// Short branch name, nil when detached or bare.
    public var branch: String?
    public var isMain: Bool
    public var isBare: Bool
    public var isDetached: Bool
    public var isLocked: Bool
    public var isPrunable: Bool

    public init(path: String, headOID: String? = nil, branch: String? = nil, isMain: Bool = false,
                isBare: Bool = false, isDetached: Bool = false, isLocked: Bool = false, isPrunable: Bool = false) {
        self.path = path
        self.headOID = headOID
        self.branch = branch
        self.isMain = isMain
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var url: URL { URL(fileURLWithPath: path) }
}

public struct BranchInfo: Hashable, Sendable, Codable {
    /// nil on an unborn branch (no commits yet).
    public var headOID: String?
    /// nil when HEAD is detached.
    public var branch: String?
    public var upstream: String?
    public var ahead: Int?
    public var behind: Int?
    public var headSubject: String?

    public init(headOID: String? = nil, branch: String? = nil, upstream: String? = nil,
                ahead: Int? = nil, behind: Int? = nil, headSubject: String? = nil) {
        self.headOID = headOID
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.headSubject = headSubject
    }

    public var isDetached: Bool { branch == nil && headOID != nil }
    public var isUnborn: Bool { headOID == nil }
    public var shortHead: String? { headOID.map { String($0.prefix(7)) } }
    public var displayName: String {
        if let branch { return branch }
        if let shortHead { return "detached at \(shortHead)" }
        return "no commits yet"
    }
}

/// What the working tree is compared against.
public enum Baseline: Hashable, Sendable, Codable {
    /// Everything not yet committed (working tree vs HEAD), including untracked files.
    case head
    /// Everything since the branch diverged from the default branch.
    case branchPoint
    /// Everything since the user pressed "Mark start".
    case start
    /// Everything since a particular snapshot (ref name).
    case snapshot(String)

    public var title: String {
        switch self {
        case .head: "Uncommitted"
        case .branchPoint: "Since branch point"
        case .start: "Since start"
        case .snapshot: "Since snapshot"
        }
    }
}

public struct ResolvedBaseline: Hashable, Sendable {
    public var baseline: Baseline
    /// Commit or tree to diff against. nil when the baseline cannot be computed.
    public var treeish: String?
    public var label: String
    public var unavailableReason: String?

    public init(baseline: Baseline, treeish: String?, label: String, unavailableReason: String? = nil) {
        self.baseline = baseline
        self.treeish = treeish
        self.label = label
        self.unavailableReason = unavailableReason
    }

    public var isAvailable: Bool { treeish != nil }
}

/// A working-tree snapshot stored as a commit under `refs/monitor/<worktree-id>/`.
public struct SnapshotRecord: Identifiable, Hashable, Sendable, Codable {
    /// Full ref name.
    public var id: String
    public var commitOID: String
    public var treeOID: String
    public var date: Date
    public var isStart: Bool

    public init(id: String, commitOID: String, treeOID: String, date: Date, isStart: Bool) {
        self.id = id
        self.commitOID = commitOID
        self.treeOID = treeOID
        self.date = date
        self.isStart = isStart
    }
}

/// The complete result of one refresh of a worktree.
public struct WorktreeState: Sendable, Hashable {
    public var timestamp: Date
    public var branch: BranchInfo
    public var baseline: ResolvedBaseline
    public var defaultBranch: String?
    /// Changes against the selected baseline, with flags applied.
    public var changes: [FileChange]
    /// Changes against HEAD, used to derive the activity feed independent of the selected baseline.
    public var headChanges: [FileChange]
    /// Untracked files skipped because they exceed the size limit.
    public var excludedLargeFiles: [String]
    /// Tree id of the working tree as captured by the shadow index.
    public var shadowTreeOID: String?
    /// A merge, rebase, cherry-pick or revert the worktree is in the middle of.
    public var operation: WorktreeOperation?

    /// Whether `other` shows the same as this, whenever each was taken.
    public func sameContent(as other: WorktreeState) -> Bool {
        var copy = self
        copy.timestamp = other.timestamp
        return copy == other
    }

    public init(timestamp: Date, branch: BranchInfo, baseline: ResolvedBaseline, defaultBranch: String?,
                changes: [FileChange], headChanges: [FileChange], excludedLargeFiles: [String], shadowTreeOID: String?,
                operation: WorktreeOperation? = nil) {
        self.timestamp = timestamp
        self.branch = branch
        self.baseline = baseline
        self.defaultBranch = defaultBranch
        self.changes = changes
        self.headChanges = headChanges
        self.excludedLargeFiles = excludedLargeFiles
        self.shadowTreeOID = shadowTreeOID
        self.operation = operation
    }
}
