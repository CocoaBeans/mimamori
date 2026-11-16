import Foundation

/// What the iPhone companion's Live Activity shows: the most pressing agents, cut down to fit an
/// update, and how many need you and are working. ActivityKit refuses an update over 4 KB, and
/// the Lock Screen has room for a few rows, so it carries no cards or permission requests.
public struct AgentsActivityState: Codable, Sendable, Hashable {
    /// ActivityKit's limit is 4 KB; this leaves room for how it wraps the state.
    public static let byteBudget = 3 * 1024
    /// The rows the Lock Screen has room for.
    public static let rows = 3
    static let textLength = 80

    /// The agents not ended, the most pressing first, as the Mac orders them; at most `rows`.
    public var agents: [AgentWidgetSnapshot.Agent]
    public var needingYou: Int
    /// Working, or busy as seen from its process.
    public var working: Int
    /// Every agent not ended, shown or not.
    public var total: Int
    /// False once the phone has lost touch with the Mac: what's shown is the last it heard.
    public var connected: Bool

    public init(agents: [AgentWidgetSnapshot.Agent] = [], needingYou: Int = 0, working: Int = 0, total: Int = 0,
                connected: Bool = true) {
        self.agents = agents
        self.needingYou = needingYou
        self.working = working
        self.total = total
        self.connected = connected
    }

    public init(snapshot: AgentWidgetSnapshot?, connected: Bool) {
        let live = (snapshot?.agents ?? []).filter { $0.state != .ended }
        let shown = live.prefix(Self.rows).map(Self.trimmed)
        self.init(agents: Array(shown),
                  needingYou: live.filter { $0.state == .needsYou }.count,
                  working: live.filter { $0.state == .working || $0.state == .running }.count,
                  total: live.count,
                  connected: connected)
        fitBudget()
    }

    /// The agent the Dynamic Island shows: the most pressing.
    public var featured: AgentWidgetSnapshot.Agent? { agents.first }

    /// Whether going from `old` to this should reach the Lock Screen at once: who needs you, the
    /// connection, which agents are shown, or one of them changing state (working, ready, needs
    /// you). A step or a task moving on can wait for the next routine update, as iOS limits how
    /// often an app may update a Live Activity; the timers count by themselves meanwhile.
    public func isUrgent(comparedTo old: AgentsActivityState?) -> Bool {
        guard let old else { return true }
        if connected != old.connected || needingYou != old.needingYou || working != old.working || total != old.total {
            return true
        }
        guard agents.map(\.id) == old.agents.map(\.id) else { return true }
        return zip(agents, old.agents).contains { $0.state != $1.state }
    }

    /// "1 needs you · 2 working", or how many agents there are; "No agents at work" with none.
    public var summary: String {
        var parts: [String] = []
        if needingYou > 0 { parts.append("\(needingYou) need\(needingYou == 1 ? "s" : "") you") }
        if working > 0 { parts.append("\(working) working") }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        switch total {
        case 0: return "No agents at work"
        case 1: return "1 agent"
        default: return "\(total) agents"
        }
    }

    /// The bytes an update carries, near enough: ActivityKit encodes the state as JSON too.
    public var encodedSize: Int {
        (try? JSONEncoder().encode(self).count) ?? .max
    }

    /// An agent as its row shows it: the latest step only, and its texts on one short line.
    static func trimmed(_ agent: AgentWidgetSnapshot.Agent) -> AgentWidgetSnapshot.Agent {
        var agent = agent
        agent.card = nil
        agent.permissionRequest = nil
        agent.task = agent.task.map(line).flatMap { $0.isEmpty ? nil : $0 }
        agent.status = line(agent.status)
        agent.collision = agent.collision.map(line)
        agent.steps = agent.steps.prefix(1).map { step in
            var step = step
            step.target = step.target.map(line)
            return step
        }
        return agent
    }

    /// The first line of `text`, cut to `textLength` characters.
    static func line(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.count > textLength ? String(trimmed.prefix(textLength - 1)) + "…" : trimmed
    }

    /// Long paths and names can still go over: drop tasks and steps, then rows from the end.
    private mutating func fitBudget() {
        guard encodedSize > Self.byteBudget else { return }
        for index in agents.indices {
            agents[index].task = nil
            agents[index].steps = []
        }
        while encodedSize > Self.byteBudget, !agents.isEmpty {
            agents.removeLast()
        }
    }
}
