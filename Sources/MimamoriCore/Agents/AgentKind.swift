import Foundation

/// A family of coding agent, used to label processes and hook events.
public struct AgentKind: Hashable, Sendable, Codable, Identifiable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    public static let claudeCode = AgentKind(id: "claude", displayName: "Claude Code")
    public static let codex = AgentKind(id: "codex", displayName: "Codex")
    public static let aider = AgentKind(id: "aider", displayName: "Aider")
    public static let cursor = AgentKind(id: "cursor", displayName: "Cursor Agent")
    public static let gemini = AgentKind(id: "gemini", displayName: "Gemini CLI")
    public static let goose = AgentKind(id: "goose", displayName: "Goose")
    public static let opencode = AgentKind(id: "opencode", displayName: "OpenCode")
    public static let amp = AgentKind(id: "amp", displayName: "Amp")
    public static let hermes = AgentKind(id: "hermes", displayName: "Hermes")
    /// An agent whose events did not say which agent it is.
    public static let unnamed = AgentKind(id: "agent", displayName: "Agent")

    public static let known: [AgentKind] = [.claudeCode, .codex, .aider, .cursor, .gemini, .goose, .opencode, .amp, .hermes]

    /// The SF Symbol that stands for this agent wherever it appears. Generic symbols, never a
    /// product's logo; an agent Mimamori does not know gets the circled first letter of its name.
    public var symbolName: String {
        switch id {
        case Self.claudeCode.id: "sparkle"
        case Self.codex.id: "curlybraces"
        case Self.gemini.id: "diamond"
        case Self.cursor.id: "cursorarrow.rays"
        case Self.hermes.id: "paperplane"
        case Self.aider.id: "wrench.adjustable"
        case Self.goose.id: "bird"
        case Self.opencode.id: "chevron.left.forwardslash.chevron.right"
        case Self.amp.id: "bolt"
        default:
            if let letter = displayName.lowercased().first(where: { $0.isLetter && $0.isASCII }) { "\(letter).circle" } else { "person.crop.circle" }
        }
    }

    /// The symbol for an agent known only by its display name, as activity entries record it.
    public static func symbolName(forDisplayName name: String) -> String {
        (known.first { $0.displayName == name } ?? AgentKind(id: name.lowercased(), displayName: name)).symbolName
    }

    /// The agent a hook names itself as (`?agent=codex`, `gemini-cli`, `Claude Code`): a known
    /// agent when the name is one, otherwise a new kind with that name.
    public static func named(_ name: String) -> AgentKind? {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !trimmed.isEmpty else { return nil }
        let key = trimmed.lowercased().replacingOccurrences(of: " ", with: "-")
        for kind in known {
            let names = [kind.id, kind.displayName.lowercased().replacingOccurrences(of: " ", with: "-")]
            if names.contains(key) || key.hasPrefix(kind.id + "-") { return kind }
        }
        return AgentKind(id: key, displayName: trimmed)
    }
}

/// Decides whether a process is a coding agent, from its executable and arguments.
public struct AgentClassifier: Sendable {
    /// Extra executable or script names the user wants treated as agents.
    public var customNames: [String]

    public init(customNames: [String] = []) {
        self.customNames = customNames
    }

    /// Interpreters whose arguments must be inspected to find the real program.
    static let interpreters: Set<String> = ["node", "nodejs", "bun", "deno", "python", "python3", "Python", "ruby", "uv", "npx", "tsx"]

    /// True for interpreters, including versioned names such as `python3.14` or `node22`.
    static func isInterpreter(_ name: String) -> Bool {
        if interpreters.contains(name) { return true }
        let lower = name.lowercased()
        return lower.hasPrefix("python") || lower.hasPrefix("node") || lower.hasPrefix("ruby")
    }

    private static let rules: [(needle: String, kind: AgentKind)] = [
        ("claude-code", .claudeCode), ("claude", .claudeCode),
        ("codex", .codex),
        ("aider", .aider),
        ("cursor-agent", .cursor),
        ("gemini", .gemini),
        ("goose", .goose),
        ("opencode", .opencode),
        ("amp", .amp),
        ("hermes", .hermes),
    ]

    public func classify(executable: String, arguments: [String]) -> AgentKind? {
        let name = (executable as NSString).lastPathComponent
        if let kind = match(name: name) { return kind }
        if executable.contains("/claude-code/") || executable.hasSuffix("/claude.app/Contents/MacOS/claude") { return .claudeCode }
        guard Self.isInterpreter(name) else { return nil }
        // node /path/to/@anthropic-ai/claude-code/cli.js, python -m aider, .venv/bin/hermes gateway run, …
        for argument in arguments.dropFirst().prefix(6) where !argument.hasPrefix("-") || argument.hasPrefix("-m") {
            let components = argument.split(separator: "/").map(String.init)
            for component in components.reversed() {
                if let kind = match(name: component) { return kind }
            }
        }
        // Console scripts: the first argument is the script itself, e.g. ~/.hermes/hermes-agent/.hermes/bin/hermes
        if let script = arguments.first, let kind = match(name: (script as NSString).lastPathComponent) { return kind }
        return nil
    }

    private func match(name: String) -> AgentKind? {
        let lower = name.lowercased()
        for custom in customNames where !custom.isEmpty && lower == custom.lowercased() {
            return AgentKind(id: custom.lowercased(), displayName: custom)
        }
        for rule in Self.rules {
            if lower == rule.needle { return rule.kind }
        }
        // Variants such as "claude-code", "hermes-agent", "cursor-agent-1.2" or "hermes_cli".
        for rule in Self.rules where lower.hasPrefix(rule.needle + "-") || lower.hasPrefix(rule.needle + "_") {
            return rule.kind
        }
        return nil
    }
}

/// A running agent process matched to a worktree.
public struct AgentProcess: Identifiable, Hashable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let kind: AgentKind
    public let executable: String
    public let workingDirectory: String
    public let startedAt: Date
    /// Share of one core used since the previous scan, 0…1.
    public var cpuLoad: Double
    /// For Claude Code, the session it runs, as Claude Code records it.
    public var claudeSession: ClaudeSessionRecord?

    public init(pid: Int32, kind: AgentKind, executable: String, workingDirectory: String, startedAt: Date, cpuLoad: Double,
                claudeSession: ClaudeSessionRecord? = nil) {
        self.pid = pid
        self.kind = kind
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.cpuLoad = cpuLoad
        self.claudeSession = claudeSession
    }

    public var isBusy: Bool { cpuLoad > 0.02 }
}
