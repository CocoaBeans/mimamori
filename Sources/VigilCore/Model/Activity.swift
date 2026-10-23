import Foundation

public enum ActivityKind: String, Codable, Sendable, Hashable {
    case created, modified, deleted, renamed, reverted
    case committed, headMoved, branchChanged
    case started, snapshot, flagged, watching

    public var systemImage: String {
        switch self {
        case .created: "plus.circle"
        case .modified: "pencil.circle"
        case .deleted: "minus.circle"
        case .renamed: "arrow.right.circle"
        case .reverted: "arrow.uturn.backward.circle"
        case .committed: "checkmark.circle"
        case .headMoved: "arrow.triangle.swap"
        case .branchChanged: "arrow.triangle.branch"
        case .started: "flag"
        case .snapshot: "camera"
        case .flagged: "exclamationmark.triangle"
        case .watching: "eye"
        }
    }
}

/// One line in the activity feed.
public struct ActivityEntry: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var date: Date
    public var worktreePath: String
    public var kind: ActivityKind
    public var path: String?
    public var title: String
    public var detail: String?
    public var additions: Int?
    public var deletions: Int?
    public var severity: Severity?

    public init(id: UUID = UUID(), date: Date = Date(), worktreePath: String, kind: ActivityKind,
                path: String? = nil, title: String, detail: String? = nil,
                additions: Int? = nil, deletions: Int? = nil, severity: Severity? = nil) {
        self.id = id
        self.date = date
        self.worktreePath = worktreePath
        self.kind = kind
        self.path = path
        self.title = title
        self.detail = detail
        self.additions = additions
        self.deletions = deletions
        self.severity = severity
    }
}
