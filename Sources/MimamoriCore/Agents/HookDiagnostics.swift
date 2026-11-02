import Foundation

/// One request to the hook socket and what became of it, so you can see a hook setup work, or
/// see why it does not. It holds names and folders, never a prompt, command or file's content.
public struct HookLogEntry: Identifiable, Sendable, Hashable {
    public enum Outcome: Sendable, Hashable {
        /// Placed in this watched worktree.
        case placed(worktree: String)
        /// Fit no watched worktree. `directory` is where the agent said it was working. With a
        /// session, the event waits for a later one that says where the session works.
        case unplaced(directory: String?, held: Bool)
        /// The socket turned the request down.
        case rejected(HookRejection)
        /// A test from Settings, sent through the hook command.
        case test
    }

    public var id = UUID()
    public var at: Date
    /// Nil for a rejected request, whose agent is not known.
    public var agent: AgentKind?
    /// The event's name as the agent sent it.
    public var event: String
    public var tool: String?
    public var outcome: Outcome

    public init(at: Date, agent: AgentKind?, event: String, tool: String? = nil, outcome: Outcome) {
        self.at = at
        self.agent = agent
        self.event = event
        self.tool = tool
        self.outcome = outcome
    }

    public init(_ event: HookEvent, outcome: Outcome) {
        self.init(at: event.receivedAt, agent: event.agent, event: event.rawName, tool: event.toolName, outcome: outcome)
    }

    /// "Claude Code · PostToolUse · Bash", "Rejected request", "Test event".
    public var title: String {
        switch outcome {
        case .rejected: return "Rejected request"
        case .test: return "Test event"
        case .placed, .unplaced: return ([agent?.displayName ?? "Unknown agent", event] + (tool.map { [$0] } ?? [])).joined(separator: " · ")
        }
    }

    /// What became of it, with folders under your home shortened to ~.
    public func detail(home: String) -> String {
        switch outcome {
        case .placed(let worktree):
            return "→ " + HookDiagnostics.shorten(worktree, home: home)
        case .unplaced(let directory, let held):
            let place = directory.map { "no watched worktree holds " + HookDiagnostics.shorten($0, home: home) }
                ?? "it said nothing of where it works"
            return "Not placed: " + place + (held ? "; held until the session's next event places it" : "")
        case .rejected(let rejection):
            let keys = rejection.keys.map { $0.isEmpty ? "; the JSON is empty" : "; JSON keys: " + $0.joined(separator: ", ") } ?? ""
            return "\(rejection.status): \(rejection.reason) (\(rejection.target))\(keys)"
        case .test:
            return "Arrived through the hook command"
        }
    }

    public var isProblem: Bool {
        switch outcome {
        case .placed, .test: false
        case .unplaced, .rejected: true
        }
    }
}

/// Everything about Mimamori's hooks that helps find out why an agent does not show up, as text
/// to paste into a bug report. It names agents, folders and events, never their content, and
/// writes folders under your home with ~.
public struct HookDiagnostics: Sendable {
    public struct Contact: Sendable {
        public var agent: String
        public var events: Int
        public var lastEventAt: Date
        public var lastEvent: String
        public var lastWorktree: String?

        public init(agent: String, events: Int, lastEventAt: Date, lastEvent: String, lastWorktree: String?) {
            self.agent = agent
            self.events = events
            self.lastEventAt = lastEventAt
            self.lastEvent = lastEvent
            self.lastWorktree = lastWorktree
        }
    }

    public var generatedAt = Date()
    public var app = ""
    public var system = ""
    public var socketPath = ""
    public var listening = false
    public var socketError: String?
    public var eventsReceived = 0
    public var eventsUnplaced = 0
    public var lastEventAt: Date?
    /// Each agent with an installer, and how its hooks stand: ("Claude Code", "installed in ~/.claude/settings.json").
    public var hooks: [(agent: String, state: String)] = []
    public var detection = ""
    public var watched = ""
    public var contacts: [Contact] = []
    /// Newest first.
    public var recent: [HookLogEntry] = []

    public init() {}

    /// How many recent requests the report lists.
    public static let recentLimit = 40

    public func text(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let clock = Self.formatter("HH:mm:ss")
        var lines = ["Mimamori diagnostics, \(Self.formatter("yyyy-MM-dd HH:mm:ss ZZZZZ").string(from: generatedAt))", ""]
        lines.append("App: \(app)")
        lines.append("System: \(system)")
        lines.append("Socket: \(listening ? "listening" : "not listening\(socketError.map { " (\($0))" } ?? "")") at \(Self.shorten(socketPath, home: home))")
        var events = "Events: \(eventsReceived) since launch"
        if eventsUnplaced > 0 { events += ", \(eventsUnplaced) not placed in a watched worktree" }
        if let lastEventAt { events += ", last at \(clock.string(from: lastEventAt))" }
        lines.append(events)
        for hook in hooks { lines.append("\(hook.agent) hooks: \(Self.shorten(hook.state, home: home))") }
        lines.append("Process detection: \(detection)")
        lines.append("Watching: \(watched)")
        lines.append("")
        lines.append("Heard from since launch:")
        if contacts.isEmpty { lines.append("  no agent") }
        for contact in contacts {
            let place = contact.lastWorktree.map { "in " + Self.shorten($0, home: home) } ?? "not in a watched worktree"
            lines.append("  \(contact.agent): \(contact.events) events, last \(contact.lastEvent) at \(clock.string(from: contact.lastEventAt)), \(place)")
        }
        lines.append("")
        lines.append("Recent requests, newest first:")
        if recent.isEmpty { lines.append("  none since launch") }
        for entry in recent.prefix(Self.recentLimit) {
            lines.append("  \(clock.string(from: entry.at))  \(entry.title)  \(entry.detail(home: home))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A path inside `home` written from ~; anything else as it is. Also shortens paths inside text.
    public static func shorten(_ text: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return text }
        if text == home { return "~" }
        return text.replacingOccurrences(of: home + "/", with: "~/")
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
