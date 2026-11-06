import Foundation

/// What the iPhone should tell you as the agents change, worked out from two snapshots in a row,
/// as the Mac tells you: an agent needs you, finished a turn, or collides with another.
public enum CompanionAlerts {
    public enum Kind: String, Sendable {
        case needsYou, turnFinished, collision
    }

    public struct Alert: Sendable, Equatable {
        public var kind: Kind
        /// Stable per agent and kind, so a newer alert replaces an older one.
        public var id: String
        public var title: String
        public var body: String
        /// The worktree, to group its alerts.
        public var thread: String
    }

    public struct Changes: Sendable, Equatable {
        public var post: [Alert] = []
        /// Alerts to take back: an agent that no longer needs you.
        public var withdraw: [String] = []

        public init(post: [Alert] = [], withdraw: [String] = []) {
            self.post = post
            self.withdraw = withdraw
        }
    }

    public static func needsYouID(_ agentID: String) -> String { "needs:\(agentID)" }

    /// What changed from `before` to `after`. With no `before`, nothing: the first snapshot after
    /// connecting only sets the baseline, so reopening the app doesn't announce old news.
    public static func changes(from before: [AgentWidgetSnapshot.Agent]?, to after: [AgentWidgetSnapshot.Agent]) -> Changes {
        guard let before else { return Changes() }
        let previous = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = Set(after.map(\.id))
        var changes = Changes()
        for agent in after {
            let old = previous[agent.id]
            if agent.state == .needsYou, old?.state != .needsYou || old?.since != agent.since {
                changes.post.append(needsYou(agent))
            } else if agent.state != .needsYou, old?.state == .needsYou {
                changes.withdraw.append(needsYouID(agent.id))
            }
            if agent.state == .ready, old?.state == .working || old?.state == .needsYou {
                changes.post.append(alert(.turnFinished, agent, title: "\(agent.agent) finished a turn", detail: agent.task))
            }
            if let collision = agent.collision, old?.collision != collision {
                changes.post.append(alert(.collision, agent, title: collision, detail: nil))
            }
        }
        // An agent that's gone no longer needs you.
        changes.withdraw += previous.keys.filter { !current.contains($0) }.sorted().map(needsYouID)
        return changes
    }

    /// "Claude Code needs permission: Bash", "Codex has a question for you", from the status line.
    private static func needsYou(_ agent: AgentWidgetSnapshot.Agent) -> Alert {
        let status = agent.status
        if status.hasPrefix("needs permission") {
            let rest = status.dropFirst("needs permission".count).drop { $0 == " " || $0 == "·" }
            let tool = rest.split(separator: " ").first.map(String.init)
            let command = rest.dropFirst(tool?.count ?? 0).trimmingCharacters(in: .whitespaces)
            return alert(.needsYou, agent, title: tool.map { "\(agent.agent) needs permission: \($0)" } ?? "\(agent.agent) needs permission",
                         detail: command.isEmpty ? nil : command)
        }
        if status.hasPrefix("asks: ") {
            return alert(.needsYou, agent, title: "\(agent.agent) has a question for you", detail: String(status.dropFirst("asks: ".count)))
        }
        return alert(.needsYou, agent, title: "\(agent.agent) needs you", detail: status)
    }

    private static func alert(_ kind: Kind, _ agent: AgentWidgetSnapshot.Agent, title: String, detail: String?) -> Alert {
        let id = kind == .needsYou ? needsYouID(agent.id) : "\(kind.rawValue):\(agent.id)"
        let body = [detail, "\(agent.repository) › \(agent.worktree)"].compactMap { $0 }.joined(separator: " · ")
        return Alert(kind: kind, id: id, title: title, body: body, thread: agent.id)
    }
}
