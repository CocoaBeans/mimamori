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

/// A command an agent runs in the background (Claude Code's `run_in_background`): it hands the turn
/// back to you while the command goes on, and is told when it ends.
public struct BackgroundCommand: Sendable, Hashable, Codable, Identifiable {
    /// Its task id (`backgroundTaskId`, the `id` in `background_tasks`).
    public var id: String
    public var description: String?
    /// Its first line.
    public var command: String?
    public var startedAt: Date
    public var finishedAt: Date?
    /// `completed`, `failed`, `killed`, … once it ends; nil while it runs or when the end wasn't told.
    public var status: String?
    public var exitCode: Int?

    public init(id: String, description: String? = nil, command: String? = nil, startedAt: Date, finishedAt: Date? = nil,
                status: String? = nil, exitCode: Int? = nil) {
        self.id = id
        self.description = description
        self.command = command
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.exitCode = exitCode
    }

    public var isRunning: Bool { finishedAt == nil }

    /// "completed (exit 0)", "failed (exit 1)", "stopped"; nil while it runs.
    public var outcome: String? {
        guard finishedAt != nil else { return nil }
        let word = status.map { $0 == "killed" ? "stopped" : $0 } ?? "ended"
        return exitCode.map { "\(word) (exit \($0))" } ?? word
    }

    /// "ready · 2 running in the background"
    public static func runningDetail(_ count: Int) -> String {
        "\(count) running in the background"
    }
}
