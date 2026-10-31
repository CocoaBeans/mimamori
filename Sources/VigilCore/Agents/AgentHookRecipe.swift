import Foundation

/// Hook setups for agents Vigil does not install into: copy one into the agent's own settings
/// file and its events reach Vigil's socket. Every one runs the same command; only the agent's
/// file format and event names differ.
public enum AgentHookRecipe: String, CaseIterable, Identifiable, Sendable {
    case codex, gemini, cursor, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .cursor: "Cursor"
        case .other: "Any other agent"
        }
    }

    /// Where the setup goes, with `~` for your home folder; nil for an agent Vigil does not know.
    public var file: String? {
        switch self {
        case .codex: "~/.codex/hooks.json"
        case .gemini: "~/.gemini/settings.json"
        case .cursor: "~/.cursor/hooks.json"
        case .other: nil
        }
    }

    /// The agent's own names for the events Vigil wants.
    public var events: [String] {
        switch self {
        case .codex:
            ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "Interrupt",
             "SubagentStop", "SessionEnd"]
        case .gemini:
            ["SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "AfterAgent", "Notification", "SessionEnd"]
        case .cursor:
            ["sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure", "subagentStop", "stop",
             "sessionEnd"]
        case .other:
            AgentEventTranslator.plainEvents.map(\.name)
        }
    }

    /// What to know before pasting.
    public var note: String {
        switch self {
        case .codex:
            "Codex runs a new or changed hook only after you trust it: open /hooks in Codex and trust Vigil's. If hooks.json already exists, add these entries under its \"hooks\" key."
        case .gemini:
            "If settings.json already exists, add these entries under its \"hooks\" key. Gemini CLI's /hooks panel lists them."
        case .cursor:
            "Cursor reloads hooks.json when you save it. If the file already exists, add these entries under its \"hooks\" key."
        case .other:
            "Run this from the agent's hooks with the event's JSON on standard input. When the agent uses names Vigil does not know, or sends no JSON, add &event= with one of: "
                + AgentEventTranslator.plainEvents.map(\.name).joined(separator: ", ") + "."
        }
    }

    /// The command every hook runs. It posts the event to Vigil's socket, gives up after a second
    /// and always succeeds, so it can never hold up or block the agent.
    public static func command(socketPath: String, agent: String) -> String {
        // $HOME keeps the setup portable between machines and users.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let portable = socketPath.hasPrefix(home + "/") ? "$HOME" + socketPath.dropFirst(home.count) : socketPath
        let name = AgentKind.named(agent)?.id ?? AgentKind.unnamed.id
        let safe = String(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) })
        return "curl -s -m 1 -H 'Expect:' -H 'Content-Type: application/json' --unix-socket \"\(portable)\" --data-binary @- 'http://vigil/event?agent=\(safe.isEmpty ? AgentKind.unnamed.id : safe)' >/dev/null 2>&1 || true"
    }

    /// The agent name the setup reports as.
    public var agentName: String {
        switch self {
        case .codex: AgentKind.codex.id
        case .gemini: AgentKind.gemini.id
        case .cursor: AgentKind.cursor.id
        case .other: "my-agent"
        }
    }

    /// The text to paste: the agent's settings JSON, or the bare command for any other agent.
    public func setup(socketPath: String, agent: String? = nil) -> String {
        let command = Self.command(socketPath: socketPath, agent: agent ?? agentName)
        var hooks: [String: Any] = [:]
        switch self {
        case .codex:
            // Codex allows SessionEnd and Interrupt hooks three seconds at most.
            for event in events {
                hooks[event] = [["hooks": [["type": "command", "command": command, "timeout": 3]]]]
            }
            return Self.json(["hooks": hooks])
        case .gemini:
            for event in events {
                var group: [String: Any] = ["hooks": [["name": "vigil", "type": "command", "command": command, "timeout": 5000]]]
                if event == "BeforeTool" || event == "AfterTool" { group["matcher"] = "*" }
                hooks[event] = [group]
            }
            return Self.json(["hooks": hooks])
        case .cursor:
            for event in events {
                hooks[event] = [["command": command, "timeout": 5]]
            }
            return Self.json(["version": 1, "hooks": hooks])
        case .other:
            return command
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
