import Foundation

/// Turns any agent's hook payload into Vigil's hook events.
///
/// Agents name the same moments differently: about to use a tool is `PreToolUse` to Claude Code
/// and Codex, `BeforeTool` to Gemini CLI, `preToolUse` to Cursor and `pre_tool_call` to Hermes,
/// and their fields differ a little too. This maps all of them, plus a plain vocabulary
/// (`turn_start`, `tool_start`, …) for agents wired up by hand.
public enum AgentEventTranslator {
    /// Event names for agents wired up by hand, and what each one tells Vigil.
    public static let plainEvents: [(name: String, meaning: String)] = [
        ("session_start", "a session opened"),
        ("turn_start", "you sent a prompt and the agent is working"),
        ("tool_start", "the agent is about to use a tool"),
        ("tool_end", "that tool finished"),
        ("tool_failed", "that tool failed"),
        ("needs_permission", "the agent is waiting for your permission"),
        ("question", "the agent asked you something"),
        ("turn_end", "the agent finished and is ready for your next prompt"),
        ("turn_failed", "the turn ended on an error"),
        ("session_end", "the session closed"),
    ]

    static let plainNames: [String: HookEvent.Name] = [
        "session_start": .sessionStart, "turn_start": .userPromptSubmit,
        "tool_start": .preToolUse, "tool_end": .postToolUse, "tool_failed": .postToolUseFailure,
        "needs_permission": .permissionRequest, "question": .notification,
        "turn_end": .stop, "turn_failed": .stopFailure, "session_end": .sessionEnd,
    ]

    /// Gemini CLI's own names; it shares SessionStart, SessionEnd and Notification with Claude Code.
    static let geminiNames: [String: HookEvent.Name] = [
        "BeforeAgent": .userPromptSubmit, "BeforeTool": .preToolUse, "AfterTool": .postToolUse,
        "AfterAgent": .stop, "PreCompress": .preCompact,
        "BeforeModel": .other, "AfterModel": .other, "BeforeToolSelection": .other,
    ]

    /// Cursor's names. The shell and MCP events are older forms of preToolUse and postToolUse.
    static let cursorNames: [String: HookEvent.Name] = [
        "sessionStart": .sessionStart, "sessionEnd": .sessionEnd, "beforeSubmitPrompt": .userPromptSubmit,
        "preToolUse": .preToolUse, "postToolUse": .postToolUse, "postToolUseFailure": .postToolUseFailure,
        "beforeShellExecution": .preToolUse, "afterShellExecution": .postToolUse,
        "beforeMCPExecution": .preToolUse, "afterMCPExecution": .postToolUse,
        "subagentStop": .subagentStop, "stop": .stop, "preCompact": .preCompact,
        "subagentStart": .other, "beforeReadFile": .other, "afterFileEdit": .other, "beforeTabFileRead": .other,
        "afterTabFileEdit": .other, "afterAgentResponse": .other, "afterAgentThought": .other, "workspaceOpen": .other,
    ]

    /// Claude Code's names, which Codex's hooks use too, and Codex's extras.
    static let claudeNames: [String: HookEvent.Name] = {
        var names = Dictionary(uniqueKeysWithValues: HookEvent.Name.allCases.filter { $0 != .other }.map { ($0.rawValue, $0) })
        names["Interrupt"] = .stop  // Codex: you stopped the turn
        names["agent-turn-complete"] = .stop  // Codex's `notify` program
        return names
    }()

    enum Dialect: Equatable {
        case claude, gemini, cursor, hermes, plain

        init(name: String, payload: [String: Any]) {
            if HermesHookParser.eventMap[name] != nil {
                self = .hermes
            } else if payload["cursor_version"] != nil || cursorNames[name] != nil {
                self = .cursor
            } else if geminiNames[name] != nil {
                self = .gemini
            } else if plainNames[name] != nil {
                self = .plain
            } else {
                self = .claude
            }
        }

        /// The agent the payload's shape proves, when it does.
        func provenAgent(_ payload: [String: Any]) -> AgentKind? {
            switch self {
            case .hermes: .hermes
            case .cursor: payload["cursor_version"] != nil ? .cursor : nil
            default: nil
            }
        }

        /// Whether `agent` sends events by these names. A hook can run far below the agent that
        /// started it (an agent run from Claude Code's terminal), so a calling agent counts only
        /// when its names match. Agents Vigil has no names for may use anyone's.
        func fits(_ agent: AgentKind) -> Bool {
            switch agent {
            case .claudeCode, .codex: self == .claude
            case .gemini: self == .gemini || self == .claude  // it shares SessionStart, SessionEnd, Notification
            case .cursor: self == .cursor
            case .hermes: self == .hermes
            default: true
            }
        }

        /// The agent these names suggest when nothing better says.
        func likelyAgent(_ payload: [String: Any]) -> AgentKind {
            switch self {
            case .claude: payload["turn_id"] != nil || payload["thread-id"] != nil ? .codex : .claudeCode
            case .gemini: .gemini
            case .cursor: .cursor
            case .hermes: .hermes
            case .plain: .unnamed
            }
        }

        func event(for name: String) -> HookEvent.Name {
            switch self {
            case .claude: claudeNames[name] ?? .other
            case .gemini: geminiNames[name] ?? .other
            case .cursor: cursorNames[name] ?? .other
            case .hermes: HermesHookParser.eventMap[name] ?? .other
            case .plain: plainNames[name] ?? .other
            }
        }
    }

    public static func translate(_ data: Data, agent: AgentKind? = nil, caller: HookCaller? = nil, eventName: String? = nil,
                                 receivedAt: Date = Date()) -> HookEvent? {
        var object: [String: Any] = [:]
        if !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            object = decoded
        }
        return translate(object, agent: agent, caller: caller, eventName: eventName, receivedAt: receivedAt)
    }

    /// Which agent sent an event: the one the hook names (`agent`), else the one its payload
    /// proves, else the agent process that ran the hook (`caller`) when it uses these event
    /// names, else the one the names suggest. `eventName` stands in for a payload that names no event, or has none.
    public static func translate(_ payload: [String: Any], agent: AgentKind? = nil, caller: HookCaller? = nil,
                                 eventName: String? = nil, receivedAt: Date = Date()) -> HookEvent? {
        var object = payload
        if let eventName, !eventName.isEmpty { object["hook_event_name"] = eventName }
        let rawName = (object["hook_event_name"] ?? object["event"] ?? object["type"]) as? String
        guard let rawName, !rawName.isEmpty else { return nil }
        object["hook_event_name"] = rawName

        let dialect = Dialect(name: rawName, payload: object)
        let kind = agent ?? dialect.provenAgent(object) ?? caller?.agent.flatMap { dialect.fits($0) ? $0 : nil }
            ?? dialect.likelyAgent(object)
        if dialect == .hermes || kind == .hermes {
            guard var event = HermesHookParser.parse(object, receivedAt: receivedAt) else { return nil }
            event.agent = kind
            return event
        }

        var name = dialect.event(for: rawName)
        normalizeFields(&object)
        switch dialect {
        case .cursor:
            if rawName.hasSuffix("ShellExecution") { object["tool_name"] = "Shell" }
            if name == .stop, object["status"] as? String == "error" { name = .stopFailure }
        case .gemini:
            if name == .postToolUse, let response = object["tool_response"] as? [String: Any],
               let error = response["error"], !(error is NSNull), "\(error)" != "" {
                name = .postToolUseFailure
                if object["error"] == nil { object["error"] = (error as? String) ?? "\(error)" }
            }
        case .plain:
            if name == .notification, object["notification_type"] == nil { object["notification_type"] = "question" }
        case .claude, .hermes:
            break
        }
        object["hook_event_name"] = name == .other ? rawName : name.rawValue
        if object["cwd"] == nil, let directory = caller?.directory { object["cwd"] = directory }

        guard var event = HookEventParser.parse(object, receivedAt: receivedAt, agent: kind) else { return nil }
        event.rawName = rawName
        return event
    }

    /// Brings other agents' field names to the ones `HookEventParser` reads.
    static func normalizeFields(_ object: inout [String: Any]) {
        // Cursor names its conversation, Codex's notify program its thread.
        if object["session_id"] == nil, let id = (object["conversation_id"] ?? object["thread-id"]) as? String {
            object["session_id"] = id
        }
        if object["cwd"] == nil, let root = (object["workspace_roots"] as? [String])?.first {
            object["cwd"] = root
        }
        // Cursor's MCP events carry the tool input as a JSON string.
        if let text = object["tool_input"] as? String,
           let decoded = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            object["tool_input"] = decoded
        }
        // Gemini CLI's permission alert keeps the tool's details apart.
        if object["notification_type"] as? String == "ToolPermission" {
            object["notification_type"] = "permission_prompt"
            if object["tool_input"] == nil, let details = object["details"] as? [String: Any] { object["tool_input"] = details }
            if object["tool_name"] == nil, let details = object["details"] as? [String: Any] {
                object["tool_name"] = (details["tool_name"] ?? details["toolName"] ?? details["name"]) as? String
            }
        }
        // A command or file at the top level, as Cursor's shell events and hand-written hooks send them.
        if object["tool_input"] == nil {
            var input: [String: Any] = [:]
            for key in ["file_path", "command"] { if let value = object[key] as? String { input[key] = value } }
            if !input.isEmpty { object["tool_input"] = input }
        }
        if object["error"] == nil, let message = object["error_message"] as? String { object["error"] = message }
        if object["tool"] != nil, object["tool_name"] == nil { object["tool_name"] = object["tool"] }
    }
}
