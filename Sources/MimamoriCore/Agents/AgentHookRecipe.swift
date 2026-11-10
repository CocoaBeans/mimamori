import Foundation

/// Hook setups for agents Mimamori does not install into: copy one into the agent's own settings
/// file and its events reach Mimamori's socket. Every one runs the same command; only the agent's
/// file format and event names differ. pi's and OMP's hooks are code, so theirs is an extension instead.
public enum AgentHookRecipe: String, CaseIterable, Identifiable, Sendable {
    case codex, gemini, cursor, pi, omp, other

    public var id: String { rawValue }

    /// The agent that runs the extension, for pi and OMP.
    public var extensionHost: PiExtension.Host? {
        switch self {
        case .pi: .pi
        case .omp: .omp
        default: nil
        }
    }

    public var title: String {
        switch self {
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .cursor: "Cursor"
        case .pi: "pi"
        case .omp: "OMP"
        case .other: "Any other agent"
        }
    }

    /// Where the setup goes, with `~` for your home folder; nil for an agent Mimamori does not know.
    public var file: String? {
        switch self {
        case .codex: "~/.codex/hooks.json"
        case .gemini: "~/.gemini/settings.json"
        case .cursor: "~/.cursor/hooks.json"
        case .pi, .omp: extensionHost?.file
        case .other: nil
        }
    }

    /// What to do with the setup, above it.
    public var lead: String {
        switch self {
        case .pi, .omp: "Save this as \(file ?? "the agent's extensions"):"
        case .other: "Have the agent's hooks run:"
        default: "Add this to \(file ?? "the agent's settings"):"
        }
    }

    /// The Copy button's title and tooltip.
    public var copyTitle: String {
        switch self {
        case .pi, .omp: "Copy Extension"
        case .other: "Copy Command"
        default: "Copy Setup"
        }
    }

    public var copyHelp: String {
        switch self {
        case .pi, .omp: "Copy the extension to save as \(file ?? "the agent's extensions")"
        case .other: "Copy the command for the agent's hooks to run"
        default: "Copy the hooks to add to \(file ?? "the agent's settings")"
        }
    }

    /// The agent's own names for the events Mimamori wants.
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
        case .pi, .omp:
            PiExtension.events
        case .other:
            AgentEventTranslator.plainEvents.map(\.name)
        }
    }

    /// What to know before pasting.
    public var note: String {
        switch self {
        case .codex:
            "Codex runs a new or changed hook only after you trust it: open /hooks in Codex and trust Mimamori's. If hooks.json already exists, add these entries under its \"hooks\" key."
        case .gemini:
            "If settings.json already exists, add these entries under its \"hooks\" key. Gemini CLI's /hooks panel lists them."
        case .cursor:
            "Cursor reloads hooks.json when you save it. If the file already exists, add these entries under its \"hooks\" key."
        case .pi:
            "pi loads extensions when a session starts, and /reload loads a new one into a running session. Delete the file to stop."
        case .omp:
            "OMP loads extensions when it starts, so OMP started after you save the file reports to Mimamori. OMP that another app runs, such as Orca's chats, needs that app to start it again. Delete the file to stop."
        case .other:
            "Run this from the agent's hooks with the event's JSON on standard input. When the agent uses names Mimamori does not know, or sends no JSON, add &event= with one of: "
                + AgentEventTranslator.plainEvents.map(\.name).joined(separator: ", ") + "."
        }
    }

    /// The command every hook runs. It posts the event to Mimamori's socket, gives up after a second
    /// and always succeeds, so it can never hold up or block the agent.
    public static func command(socketPath: String, agent: String, home: String = HookCommand.defaultHome) -> String {
        HookCommand.event(socketPath: socketPath, address: address(agent: agent), home: home)
    }

    /// The address an agent's events go to on the socket, `/event?agent=<name>`, with only safe characters in the name.
    public static func address(agent: String) -> String {
        let name = AgentKind.named(agent)?.id ?? AgentKind.unnamed.id
        let safe = String(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) })
        return "/event?agent=\(safe.isEmpty ? AgentKind.unnamed.id : safe)"
    }

    /// The agent name the setup reports as.
    public var agentName: String {
        switch self {
        case .codex: AgentKind.codex.id
        case .gemini: AgentKind.gemini.id
        case .cursor: AgentKind.cursor.id
        case .pi: AgentKind.pi.id
        case .omp: AgentKind.omp.id
        case .other: "my-agent"
        }
    }

    /// The text to paste: the agent's settings JSON, pi's or OMP's extension, or the bare command for any other agent.
    public func setup(socketPath: String, agent: String? = nil, home: String = HookCommand.defaultHome) -> String {
        let command = Self.command(socketPath: socketPath, agent: agent ?? agentName, home: home)
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
                var group: [String: Any] = ["hooks": [["name": "mimamori", "type": "command", "command": command, "timeout": 5000]]]
                if event == "BeforeTool" || event == "AfterTool" { group["matcher"] = "*" }
                hooks[event] = [group]
            }
            return Self.json(["hooks": hooks])
        case .cursor:
            for event in events {
                hooks[event] = [["command": command, "timeout": 5]]
            }
            return Self.json(["version": 1, "hooks": hooks])
        case .pi, .omp:
            return PiExtension.source(for: extensionHost ?? .pi, socketPath: socketPath, home: home)
        case .other:
            return command
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
