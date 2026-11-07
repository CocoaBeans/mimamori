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
        // Only what names the program the interpreter runs: never the program's own arguments,
        // which can be any path, such as one under a folder called claude-profiles.
        switch Self.program(arguments: arguments) {
        case .module(let module):
            return module.split(separator: ".").first.flatMap { match(name: String($0)) }
        case .script(let path):
            return classify(script: path)
        case .inline(let code):
            return Self.entryModule(in: code).flatMap { match(name: $0) }
        case nil:
            return nil
        }
    }

    enum Program: Equatable {
        /// `python -m aider`
        case module(String)
        /// A script's path, or a package a runner names: `node …/cli.js`, `npx @anthropic-ai/claude-code`.
        case script(String)
        /// Code given inline: `python -c '…'`.
        case inline(String)
    }

    /// Interpreter options followed by a value, which isn't the program.
    private static let optionsWithValues: Set<String> = [
        "-W", "-X", "-Q", "-r", "--require", "--loader", "--experimental-loader", "--import", "--input-type", "--with",
        "--from", "--python", "-p", "--package",
    ]
    /// Code given inline, which is the program; its arguments follow it.
    private static let inlineCode: Set<String> = ["-c", "-e", "--eval", "--print"]
    /// A runner's subcommands before the program: `uv run aider`, `uv tool run aider`, `bun x …`.
    private static let runnerSubcommands: Set<String> = ["run", "tool", "x", "exec"]

    /// The program the interpreter in `arguments` (its argv) runs, if it names one.
    static func program(arguments: [String]) -> Program? {
        guard let first = arguments.first else { return nil }
        // A console script's argv starts with the script itself (…/.venv/bin/hermes), not the interpreter.
        if !isInterpreter((first as NSString).lastPathComponent) { return .script(first) }
        var rest = arguments.dropFirst()[...]
        while let argument = rest.first {
            rest = rest.dropFirst()
            if argument == "-m", let module = rest.first { return .module(module) }
            if argument.hasPrefix("-m"), argument.count > 2 { return .module(String(argument.dropFirst(2))) }
            if inlineCode.contains(argument) { return rest.first.map(Program.inline) }
            // Code on standard input: there's no program to name.
            if argument == "-" { return nil }
            if optionsWithValues.contains(argument) {
                rest = rest.dropFirst()
                continue
            }
            if argument.hasPrefix("-") || runnerSubcommands.contains(argument) { continue }
            return .script(argument)
        }
        return nil
    }

    /// The package inline code starts, when it ends the way a console script does:
    /// `from hermes_cli.main import main` then `sys.exit(main())`. Hermes's launcher runs
    /// `python -I -c` with code like that, so no argument names Hermes. Other imports name
    /// nothing: anyone's one-liner can `import claude`.
    static func entryModule(in code: String) -> String? {
        let lines = code.split(separator: "\n")
        for (index, line) in lines.enumerated().reversed() {
            let words = line.split(separator: " ")
            guard words.count == 4, words[0] == "from", words[2] == "import", words[3] == "main" else { continue }
            // Imported and then called, as the console script calls it.
            guard lines[(index + 1)...].contains(where: { $0.contains("main()") }) else { return nil }
            return words[1].split(separator: ".").first.map(String.init)
        }
        return nil
    }

    /// Scripts named like an agent that are its helpers, started wherever its session works.
    /// `hermes_kernel_runner.py` is the kernel Hermes's `execute_code` runs code in.
    private static let helperScripts: Set<String> = ["hermes_kernel_runner"]

    /// Entry points too generic to name a program: the package around them does.
    private static let genericEntries: Set<String> = ["cli", "index", "main", "__main__", "entry", "run", "app", "start", "bin"]

    /// The agent a script is: by its own name, or for a generic entry point such as `cli.js`, by the
    /// package it's installed as: the folder after `node_modules` (with its scope) or `site-packages`.
    /// Not by other folders: anyone's `main.py` can sit in a folder called `hermes-notes`.
    private func classify(script: String) -> AgentKind? {
        let components = script.split(separator: "/").map(String.init)
        guard let last = components.last else { return nil }
        let base = (last as NSString).deletingPathExtension
        if Self.helperScripts.contains(base.lowercased()) { return nil }
        if let kind = match(name: base) { return kind }
        guard Self.genericEntries.contains(base.lowercased()) else { return nil }
        for marker in ["node_modules", "site-packages"] {
            guard let index = components.lastIndex(of: marker), index + 1 < components.count - 1 else { continue }
            var package = components[index + 1]
            if package.hasPrefix("@"), index + 2 < components.count - 1 { package = components[index + 2] }
            return match(name: package)
        }
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
