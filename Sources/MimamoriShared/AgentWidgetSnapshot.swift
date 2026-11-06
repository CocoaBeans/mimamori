import Foundation

/// What the desktop widgets show: the agents at work, the most pressing first. Mimamori writes it
/// to a container it shares with its widget extension, which runs sandboxed in its own process
/// and cannot reach Mimamori's socket or state.
public struct AgentWidgetSnapshot: Codable, Sendable, Hashable {
    /// The App Group both the app and the widget extension are signed for. Team-prefixed, so it
    /// needs no registration and no provisioning profile on macOS.
    public static let appGroup = "555LXJXR4U.com.kevinross.Mimamori"
    public static let fileName = "widgets.json"
    /// The widget's kind, for asking WidgetKit to reload it.
    public static let widgetKind = "AgentsWidget"
    /// Older than this, the snapshot is not trusted: Mimamori writes one at least every 15 minutes.
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
        /// The repository's color, for the tag on the agent's row; nil in snapshots from before it.
        public var repositoryColor: RepositoryColor?
        public var worktree: String
        public var agent: String
        /// The agent's SF Symbol (`AgentKind.symbolName`); nil in snapshots from before it existed.
        public var symbol: String?
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
        /// What the Agents window's card adds, for the iPhone companion; nil in the widgets' snapshot.
        public var card: Card?
        /// The permission request you can answer from the iPhone, for the companion only: nil in the
        /// widgets' snapshot, which can't answer, and while Mimamori doesn't answer requests.
        public var permissionRequest: PermissionRequest?

        public var id: String { worktreePath }

        public init(worktreePath: String, repository: String, repositoryColor: RepositoryColor? = nil, worktree: String,
                    agent: String, symbol: String? = nil,
                    state: State, status: String, since: Date, task: String? = nil, steps: [Step] = [], others: Int = 0,
                    collision: String? = nil, card: Card? = nil, permissionRequest: PermissionRequest? = nil) {
            self.worktreePath = worktreePath
            self.repository = repository
            self.repositoryColor = repositoryColor
            self.worktree = worktree
            self.agent = agent
            self.symbol = symbol
            self.state = state
            self.status = status
            self.since = since
            self.task = task
            self.steps = steps
            self.others = others
            self.collision = collision
            self.card = card
            self.permissionRequest = permissionRequest
        }

        /// Opens Mimamori on this agent's worktree.
        public var link: URL { AgentWidgetSnapshot.link(to: worktreePath) }
    }

    /// A Claude Code permission request waiting on you, which an answer from the phone settles as
    /// Mimamori's own Allow and Deny do. Only Claude Code hands Mimamori its prompts.
    public struct PermissionRequest: Codable, Sendable, Hashable, Identifiable {
        /// What the phone's answer names, so an answer can only settle this request.
        public var id: String
        public var tool: String
        /// The exact command or file, so you know what you allow.
        public var detail: String?
        public var since: Date
        /// When Mimamori answers by itself, and how; nil while it waits for you.
        public var autoAnswer: AutoAnswer?

        public struct AutoAnswer: Codable, Sendable, Hashable {
            public var allow: Bool
            public var at: Date

            public init(allow: Bool, at: Date) {
                self.allow = allow
                self.at = at
            }
        }

        public init(id: String, tool: String, detail: String? = nil, since: Date, autoAnswer: AutoAnswer? = nil) {
            self.id = id
            self.tool = tool
            self.detail = detail
            self.since = since
            self.autoAnswer = autoAnswer
        }
    }

    /// An agent's card as the Agents window draws it: the turn's steps along its time, the files
    /// it touched and what's left to review. Times are absolute, so it changes only when the agent
    /// does, and the phone draws the timeline up to its own now.
    public struct Card: Codable, Sendable, Hashable {
        /// Hooks report the agent's steps; seen from its process only, there are none.
        public var reportsSteps: Bool
        /// A turn is under way (working, or waiting on you): its timeline runs to now.
        public var turnUnderway: Bool
        public var turnStartedAt: Date?
        /// The turn's tool calls, oldest first, paths relative to the worktree. Without their
        /// targets when tasks and steps are kept on the Mac.
        public var calls: [AgentToolCall]
        /// How many calls the turn has made, more than `calls` holds once the oldest are dropped.
        public var callsThisTurn: Int
        /// The call waiting for your permission.
        public var waitingCallID: String?
        /// The last call, for an agent between turns.
        public var lastCall: AgentToolCall?
        /// Changed files it touched this turn, most recent first; empty when tasks and steps are
        /// kept on the Mac.
        public var files: [File]
        public var changes: Changes
        /// The other agents in the worktree.
        public var others: [Other]
        /// Its subagents, running or finished in the last minute; nil from a Mac before them.
        public var subagents: [Subagent]?
        /// Commands it runs in the background, running or finished in the last minute.
        public var commands: [Command]?

        public init(reportsSteps: Bool, turnUnderway: Bool, turnStartedAt: Date? = nil, calls: [AgentToolCall] = [],
                    callsThisTurn: Int = 0, waitingCallID: String? = nil, lastCall: AgentToolCall? = nil,
                    files: [File] = [], changes: Changes = Changes(), others: [Other] = [],
                    subagents: [Subagent]? = nil, commands: [Command]? = nil) {
            self.reportsSteps = reportsSteps
            self.turnUnderway = turnUnderway
            self.turnStartedAt = turnStartedAt
            self.calls = calls
            self.callsThisTurn = callsThisTurn
            self.waitingCallID = waitingCallID
            self.lastCall = lastCall
            self.files = files
            self.changes = changes
            self.others = others
            self.subagents = subagents
            self.commands = commands
        }

        /// A subagent, in a line: what kind, what it was asked, how far it has got.
        public struct Subagent: Codable, Sendable, Hashable, Identifiable {
            public var id: String
            /// Its kind: "Explore", "general-purpose".
            public var title: String
            /// What it was asked; nil when tasks are kept on the Mac.
            public var description: String?
            public var background: Bool
            public var steps: Int
            public var startedAt: Date
            public var finishedAt: Date?
            /// Its latest step, "Read Sources/App.swift"; nil when tasks are kept on the Mac.
            public var lastStep: String?

            public init(id: String, title: String, description: String? = nil, background: Bool = false, steps: Int = 0,
                        startedAt: Date, finishedAt: Date? = nil, lastStep: String? = nil) {
                self.id = id
                self.title = title
                self.description = description
                self.background = background
                self.steps = steps
                self.startedAt = startedAt
                self.finishedAt = finishedAt
                self.lastStep = lastStep
            }
        }

        /// A command run in the background.
        public struct Command: Codable, Sendable, Hashable, Identifiable {
            public var id: String
            /// What it's for, and its first line; nil when tasks are kept on the Mac.
            public var description: String?
            public var command: String?
            public var startedAt: Date
            public var finishedAt: Date?
            /// "completed (exit 0)", "failed (exit 1)"; nil while it runs.
            public var outcome: String?
            public var failed: Bool

            public init(id: String, description: String? = nil, command: String? = nil, startedAt: Date, finishedAt: Date? = nil,
                        outcome: String? = nil, failed: Bool = false) {
                self.id = id
                self.description = description
                self.command = command
                self.startedAt = startedAt
                self.finishedAt = finishedAt
                self.outcome = outcome
                self.failed = failed
            }
        }

        public struct File: Codable, Sendable, Hashable, Identifiable {
            /// Relative to the worktree.
            public var path: String
            /// Nil for a binary file.
            public var additions: Int?
            public var deletions: Int?
            /// A rule flagged it: a secret, a lockfile, a migration.
            public var flagged: Bool

            public var id: String { path }
            public var name: String { path.split(separator: "/").last.map(String.init) ?? path }

            public init(path: String, additions: Int? = nil, deletions: Int? = nil, flagged: Bool = false) {
                self.path = path
                self.additions = additions
                self.deletions = deletions
                self.flagged = flagged
            }
        }

        /// The worktree's uncommitted changes: "9 changed · 4 to review".
        public struct Changes: Codable, Sendable, Hashable {
            public var files: Int
            public var toReview: Int
            public var flagged: Int
            public var additions: Int
            public var deletions: Int

            public init(files: Int = 0, toReview: Int = 0, flagged: Int = 0, additions: Int = 0, deletions: Int = 0) {
                self.files = files
                self.toReview = toReview
                self.flagged = flagged
                self.additions = additions
                self.deletions = deletions
            }
        }

        /// Another agent in the same worktree, in one line.
        public struct Other: Codable, Sendable, Hashable {
            public var agent: String
            public var symbol: String?
            public var state: State
            public var status: String
            public var since: Date

            public init(agent: String, symbol: String? = nil, state: State, status: String, since: Date) {
                self.agent = agent
                self.symbol = symbol
                self.state = state
                self.status = status
                self.since = since
            }
        }
    }

    public var writtenAt: Date
    /// False once Mimamori has quit: the states below are no longer being kept current.
    public var mimamoriRunning: Bool
    /// Agents, the most pressing first.
    public var agents: [Agent]

    public init(writtenAt: Date = Date(), mimamoriRunning: Bool = true, agents: [Agent] = []) {
        self.writtenAt = writtenAt
        self.mimamoriRunning = mimamoriRunning
        self.agents = agents
    }

    public var needingYou: Int { agents.filter { $0.state == .needsYou }.count }
    public var working: Int { agents.filter { $0.state == .working }.count }

    /// Whether the states can be trusted: Mimamori is running and wrote this recently.
    public func isCurrent(at now: Date = Date()) -> Bool {
        mimamoriRunning && now.timeIntervalSince(writtenAt) < Self.staleAfter
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

    /// `mimamori://worktree?path=…`: what clicking an agent in a widget opens.
    public static func link(to worktreePath: String) -> URL {
        var components = URLComponents()
        components.scheme = "mimamori"
        components.host = "worktree"
        components.queryItems = [URLQueryItem(name: "path", value: worktreePath)]
        return components.url ?? URL(string: "mimamori://")!
    }

    /// The worktree a `mimamori://worktree?path=…` link names.
    public static func worktree(in url: URL) -> String? {
        guard url.scheme == "mimamori", url.host == "worktree",
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
