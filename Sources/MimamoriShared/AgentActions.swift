import Foundation

/// An agent's list of actions, as the iPhone shows it when you tap its card: every step of the
/// turn under way, newest first, then the turns before it under their prompts.
public struct AgentActions: Codable, Sendable, Hashable {
    public struct Turn: Codable, Sendable, Hashable, Identifiable {
        /// The prompt that started it; nil when it isn't known, or tasks are kept on the Mac.
        public var prompt: String?
        /// When it started; nil for steps from before the first turn Mimamori saw start.
        public var startedAt: Date?
        /// Newest first.
        public var calls: [AgentToolCall]

        public var id: String { startedAt.map { String($0.timeIntervalSince1970) } ?? "before" }

        public init(prompt: String? = nil, startedAt: Date? = nil, calls: [AgentToolCall]) {
            self.prompt = prompt
            self.startedAt = startedAt
            self.calls = calls
        }
    }

    public var worktreePath: String
    public var agent: String
    /// Newest first.
    public var turns: [Turn]
    /// The step waiting for your permission.
    public var waitingCallID: String?
    /// What each subagent is called, by `agent_id`, for the steps they took: "Explore".
    public var subagentTitles: [String: String]?

    public init(worktreePath: String, agent: String, turns: [Turn], waitingCallID: String? = nil,
                subagentTitles: [String: String]? = nil) {
        self.worktreePath = worktreePath
        self.agent = agent
        self.turns = turns
        self.waitingCallID = waitingCallID
        self.subagentTitles = subagentTitles
    }

    /// A turn as it began: when, and with what prompt.
    public struct TurnStart: Sendable, Hashable {
        public var at: Date
        public var prompt: String?

        public init(at: Date, prompt: String? = nil) {
            self.at = at
            self.prompt = prompt
        }
    }

    /// `calls` (in any order) under the turns that `starts` began, newest turn first, each turn's
    /// calls newest first. A call belongs to the latest turn that started at or before it; calls
    /// before the first known start form a turn of their own with no prompt. Turns without calls
    /// are kept only when under way (the newest), so the turn you just started shows at once.
    public static func turns(calls: [AgentToolCall], starts: [TurnStart]) -> [Turn] {
        let starts = starts.sorted { $0.at < $1.at }
        var byTurn: [Int: [AgentToolCall]] = [:]
        var before: [AgentToolCall] = []
        for call in calls {
            if let index = starts.lastIndex(where: { $0.at <= call.startedAt }) {
                byTurn[index, default: []].append(call)
            } else {
                before.append(call)
            }
        }
        var turns: [Turn] = []
        for (index, start) in starts.enumerated().reversed() {
            let calls = (byTurn[index] ?? []).sorted { $0.startedAt > $1.startedAt }
            guard !calls.isEmpty || index == starts.count - 1 else { continue }
            turns.append(Turn(prompt: start.prompt, startedAt: start.at, calls: calls))
        }
        if !before.isEmpty {
            turns.append(Turn(calls: before.sorted { $0.startedAt > $1.startedAt }))
        }
        return turns
    }
}
