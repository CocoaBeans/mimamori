import Foundation

public enum ActivityKind: String, Codable, Sendable, Hashable {
    case created, modified, deleted, renamed, reverted
    case committed, headMoved, branchChanged
    case started, snapshot, flagged, watching
    /// A hunk thrown away in Mimamori, or put back.
    case discarded
    case agentSession, agentTurn, agentTool, agentAttention

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
        case .discarded: "trash.circle"
        case .agentSession: "sparkles"
        case .agentTurn: "checkmark.bubble"
        case .agentTool: "wrench.and.screwdriver"
        case .agentAttention: "hand.raised"
        }
    }

    /// A file created, changed, deleted, renamed or put back as HEAD has it.
    public var isFileChange: Bool {
        switch self {
        case .created, .modified, .deleted, .renamed, .reverted: true
        default: false
        }
    }

    public var isAgentEvent: Bool {
        switch self {
        case .agentSession, .agentTurn, .agentTool, .agentAttention: true
        default: false
        }
    }
}

/// Which agent tool call produced a file change, when hooks told us.
public struct ChangeAttribution: Sendable, Hashable, Codable {
    public var agent: String
    public var tool: String
    public var detail: String?
    public var at: Date

    public init(agent: String, tool: String, detail: String? = nil, at: Date) {
        self.agent = agent
        self.tool = tool
        self.detail = detail
        self.at = at
    }

    public var label: String { "\(agent) · \(tool)" }
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
    /// The agent behind the entry: its own events, and file changes traced to its tool calls.
    public var agent: String?

    public init(id: UUID = UUID(), date: Date = Date(), worktreePath: String, kind: ActivityKind,
                path: String? = nil, title: String, detail: String? = nil,
                additions: Int? = nil, deletions: Int? = nil, severity: Severity? = nil, agent: String? = nil) {
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
        self.agent = agent
    }

    /// An agent's own event, or a change Mimamori traced to one.
    public var isAgentWork: Bool { kind.isAgentEvent || agent != nil }
}
