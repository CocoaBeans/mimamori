import Foundation

/// How a path differs from the baseline it is compared against.
public enum ChangeKind: String, Codable, Sendable, Hashable, CaseIterable {
    case added, modified, deleted, renamed, copied, typeChanged, unmerged, unknown

    public init(rawStatus: Character) {
        switch rawStatus {
        case "A": self = .added
        case "M": self = .modified
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "U": self = .unmerged
        default: self = .unknown
        }
    }

    /// Single-letter badge used in lists.
    public var glyph: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .unmerged: "U"
        case .unknown: "?"
        }
    }

    public var title: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type changed"
        case .unmerged: "Unmerged"
        case .unknown: "Unknown"
        }
    }
}

/// One path that differs between a baseline tree and the working tree.
public struct FileChange: Identifiable, Hashable, Sendable, Codable {
    public var id: String { path }

    /// Repository-relative path (the new path for renames).
    public var path: String
    /// Previous path for renames and copies.
    public var oldPath: String?
    public var kind: ChangeKind
    public var oldMode: String
    public var newMode: String
    /// Blob id on the baseline side; nil when the file did not exist there.
    public var oldOID: String?
    /// Blob id on the working-tree side; nil when the file was deleted.
    public var newOID: String?
    public var additions: Int?
    public var deletions: Int?
    public var isBinary: Bool
    /// Not present in the repository's real index (git would list it as `??`).
    public var isUntracked: Bool
    /// Has a staged component in the real index.
    public var isStaged: Bool
    public var hasConflict: Bool
    public var flags: [AttentionFlag]

    public init(
        path: String,
        oldPath: String? = nil,
        kind: ChangeKind,
        oldMode: String = "000000",
        newMode: String = "000000",
        oldOID: String? = nil,
        newOID: String? = nil,
        additions: Int? = nil,
        deletions: Int? = nil,
        isBinary: Bool = false,
        isUntracked: Bool = false,
        isStaged: Bool = false,
        hasConflict: Bool = false,
        flags: [AttentionFlag] = []
    ) {
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
        self.oldMode = oldMode
        self.newMode = newMode
        self.oldOID = oldOID
        self.newOID = newOID
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.isUntracked = isUntracked
        self.isStaged = isStaged
        self.hasConflict = hasConflict
        self.flags = flags
    }

    public var fileName: String { (path as NSString).lastPathComponent }
    public var directory: String { (path as NSString).deletingLastPathComponent }
    public var maxSeverity: Severity? { flags.map(\.severity).max() }
    public var isFlagged: Bool { flags.contains { $0.severity >= .warning } }
    public var modeChanged: Bool {
        oldMode != "000000" && newMode != "000000" && oldMode != newMode
    }
    public var isSymlink: Bool { newMode == "120000" }
    public var isSubmodule: Bool { newMode == "160000" }

    /// A stable key for caching anything derived from the two blob ids.
    public var contentKey: String { "\(oldOID ?? "0")|\(newOID ?? "0")|\(path)" }
}

public extension Sequence where Element == FileChange {
    var totalAdditions: Int { reduce(0) { $0 + ($1.additions ?? 0) } }
    var totalDeletions: Int { reduce(0) { $0 + ($1.deletions ?? 0) } }
    var flaggedCount: Int { filter(\.isFlagged).count }
}
