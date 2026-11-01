import Foundation

/// What the desktop widgets show: the agents at work, the most pressing first. Vigil writes it
/// to a container it shares with its widget extension, which runs sandboxed in its own process
/// and cannot reach Vigil's socket or state.
public struct AgentWidgetSnapshot: Codable, Sendable, Hashable {
    /// The App Group both the app and the widget extension are signed for. Team-prefixed, so it
    /// needs no registration and no provisioning profile on macOS.
    public static let appGroup = "555LXJXR4U.com.kevinross.Vigil"
    public static let fileName = "widgets.json"
    /// The widget's kind, for asking WidgetKit to reload it.
    public static let widgetKind = "AgentsWidget"
    /// Older than this, the snapshot is not trusted: Vigil writes one at least every 15 minutes.
    public static let staleAfter: TimeInterval = 45 * 60

    public enum State: String, Codable, Sendable, Hashable {
        /// Waiting for your permission or your answer.
        case needsYou
        case working
        /// Finished its turn, ready for your next prompt.
        case ready
        /// Seen from its process only: hooks have not reported.
        case running
        case ended
    }

    public struct Step: Codable, Sendable, Hashable {
        public var tool: String
        /// What it worked on, relative to the worktree: a file, a command.
        public var target: String?
        public var running: Bool

        public init(tool: String, target: String? = nil, running: Bool = false) {
            self.tool = tool
            self.target = target
            self.running = running
        }
    }

    public struct Agent: Codable, Sendable, Hashable, Identifiable {
        public var worktreePath: String
        public var repository: String
        public var worktree: String
        public var agent: String
        public var state: State
        /// "needs permission · Bash", "working · Edit", "ready for your next prompt".
        public var status: String
        /// When it entered `state`.
        public var since: Date
        /// The prompt behind the current or last turn; nil when tasks are kept off widgets.
        public var task: String?
        /// The turn's latest steps, newest first; empty when tasks are kept off widgets.
        public var steps: [Step]
        /// Other agents working in the same worktree.
        public var others: Int
        /// "Codex and Cursor Agent both edited PLAN.md", when two of them collide.
        public var collision: String?

        public var id: String { worktreePath }

        public init(worktreePath: String, repository: String, worktree: String, agent: String, state: State, status: String,
                    since: Date, task: String? = nil, steps: [Step] = [], others: Int = 0, collision: String? = nil) {
            self.worktreePath = worktreePath
            self.repository = repository
            self.worktree = worktree
            self.agent = agent
            self.state = state
            self.status = status
            self.since = since
            self.task = task
            self.steps = steps
            self.others = others
            self.collision = collision
        }

        /// Opens Vigil on this agent's worktree.
        public var link: URL { AgentWidgetSnapshot.link(to: worktreePath) }
    }

    public var writtenAt: Date
    /// False once Vigil has quit: the states below are no longer being kept current.
    public var vigilRunning: Bool
    /// Agents, the most pressing first.
    public var agents: [Agent]

    public init(writtenAt: Date = Date(), vigilRunning: Bool = true, agents: [Agent] = []) {
        self.writtenAt = writtenAt
        self.vigilRunning = vigilRunning
        self.agents = agents
    }

    public var needingYou: Int { agents.filter { $0.state == .needsYou }.count }
    public var working: Int { agents.filter { $0.state == .working }.count }

    /// Whether the states can be trusted: Vigil is running and wrote this recently.
    public func isCurrent(at now: Date = Date()) -> Bool {
        vigilRunning && now.timeIntervalSince(writtenAt) < Self.staleAfter
    }

    /// The shared container's copy, where the app writes and the widget reads.
    public static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent(fileName)
    }

    public static func load(from url: URL? = fileURL) -> AgentWidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(AgentWidgetSnapshot.self, from: data)
    }

    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    /// `vigil://worktree?path=…`: what clicking an agent in a widget opens.
    public static func link(to worktreePath: String) -> URL {
        var components = URLComponents()
        components.scheme = "vigil"
        components.host = "worktree"
        components.queryItems = [URLQueryItem(name: "path", value: worktreePath)]
        return components.url ?? URL(string: "vigil://")!
    }

    /// The worktree a `vigil://worktree?path=…` link names.
    public static func worktree(in url: URL) -> String? {
        guard url.scheme == "vigil", url.host == "worktree",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value,
              path.hasPrefix("/") else { return nil }
        return path
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
