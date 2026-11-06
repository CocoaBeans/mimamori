import Foundation

/// A subagent an agent started (Claude Code's Agent tool), as its hooks tell of it: every step it
/// takes carries its `agent_id` and `agent_type`, and `background_tasks` lists it while it runs.
public struct Subagent: Sendable, Hashable, Codable, Identifiable {
    /// Its `agent_id`.
    public var id: String
    /// Its kind (`agent_type`): `Explore`, `general-purpose`, `security-reviewer`, …
    public var type: String?
    /// What it was asked to do, in a few words (the Agent call's `description`).
    public var description: String?
    /// Sent to the background: the agent carries on, and may finish its turn first.
    public var background: Bool
    public var startedAt: Date
    public var lastEventAt: Date
    public var steps: Int
    /// Its latest step.
    public var lastStep: AgentToolCall?
    public var finishedAt: Date?
    /// Its last words, once finished, shortened.
    public var lastMessage: String?

    public init(id: String, type: String? = nil, description: String? = nil, background: Bool = false, startedAt: Date,
                lastEventAt: Date? = nil, steps: Int = 0, lastStep: AgentToolCall? = nil, finishedAt: Date? = nil,
                lastMessage: String? = nil) {
        self.id = id
        self.type = type
        self.description = description
        self.background = background
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt ?? startedAt
        self.steps = steps
        self.lastStep = lastStep
        self.finishedAt = finishedAt
        self.lastMessage = lastMessage
    }

    public var isRunning: Bool { finishedAt == nil }

    /// "Explore", or "Subagent" when its kind isn't known.
    public var title: String { type.flatMap { $0.isEmpty ? nil : $0 } ?? "Subagent" }

    /// A subagent silent this long is taken to be gone: its stop may never have been heard.
    public static let quietLimit: TimeInterval = 10 * 60
    /// How long a finished subagent stays listed, so its end can be seen.
    public static let listedAfterFinishing: TimeInterval = 60

    /// "waiting on 2 subagents"
    public static func waitingDetail(_ count: Int) -> String {
        count == 1 ? "waiting on 1 subagent" : "waiting on \(count) subagents"
    }
}

/// An Agent call in the foreground, kept until its subagent's first step names it: steps carry
/// the subagent's `agent_id`, the call doesn't (until it ends).
public struct SubagentLaunchRecord: Sendable, Hashable, Codable {
    public var toolUseID: String?
    public var type: String?
    public var description: String?

    public init(toolUseID: String? = nil, type: String? = nil, description: String? = nil) {
        self.toolUseID = toolUseID
        self.type = type
        self.description = description
    }
}
