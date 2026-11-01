import Foundation

/// Translates Hermes Agent shell-hook payloads into Mimamori's hook events.
///
/// Hermes posts the same fields as Claude Code (`hook_event_name`, `tool_name`,
/// `tool_input`, `session_id`, `cwd`) but with its own event names and an `extra`
/// dictionary carrying `tool_call_id`, `user_message` and friends.
public enum HermesHookParser {
    /// Hermes event name → the Claude Code event Mimamori's status machine understands.
    static let eventMap: [String: HookEvent.Name] = [
        "on_session_start": .sessionStart,
        "on_session_end": .sessionEnd,
        "on_session_reset": .sessionEnd,
        "pre_llm_call": .userPromptSubmit,
        "pre_tool_call": .preToolUse,
        "post_tool_call": .postToolUse,
        "pre_approval_request": .permissionRequest,
        "post_approval_response": .postToolUse,
        "on_human_input_request": .notification,
        "on_human_input_resolved": .userPromptSubmit,
        "pre_verify": .stop,
        "subagent_stop": .subagentStop,
    ]

    /// Events Mimamori subscribes to when installing Hermes hooks.
    public static let subscribedEvents: [String] = [
        "on_session_start", "pre_llm_call", "pre_tool_call", "post_tool_call",
        "pre_approval_request", "post_approval_response", "on_human_input_request",
        "on_human_input_resolved", "pre_verify", "subagent_stop", "on_session_end",
    ]

    public static func parse(_ data: Data, receivedAt: Date = Date()) -> HookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(object, receivedAt: receivedAt)
    }

    public static func parse(_ object: [String: Any], receivedAt: Date = Date()) -> HookEvent? {
        var object = object
        guard let rawName = object["hook_event_name"] as? String else { return nil }
        let extra = object["extra"] as? [String: Any] ?? [:]
        if let id = extra["tool_call_id"] as? String, object["tool_use_id"] == nil {
            object["tool_use_id"] = id
        }
        if rawName == "pre_llm_call", let prompt = extra["user_message"] as? String {
            object["prompt"] = prompt
        }
        if rawName == "on_human_input_request" {
            // A real question for you, unlike Claude Code's idle reminder.
            object["notification_type"] = "question"
            object["message"] = (extra["prompt"] as? String) ?? "Hermes is asking for your input"
        }
        // Hermes reports the *process* working directory, which for gateway and desktop sessions
        // is ~/.hermes rather than the project. Prefer a working directory named by the tool call
        // or the session, and leave relative tool paths relative so the receiver can place them.
        let toolInput = object["tool_input"] as? [String: Any] ?? [:]
        let sessionDirectory = [toolInput["workdir"], toolInput["cwd"], toolInput["working_dir"], toolInput["directory"],
                                extra["session_cwd"], extra["cwd"], extra["working_directory"]]
            .compactMap { $0 as? String }.first { $0.hasPrefix("/") }
        if let sessionDirectory { object["cwd"] = sessionDirectory }
        let mapped = eventMap[rawName] ?? .other
        object["hook_event_name"] = mapped == .other ? rawName : mapped.rawValue
        guard var event = HookEventParser.parse(object, receivedAt: receivedAt, agent: .hermes,
                                                resolveRelativePaths: sessionDirectory != nil) else { return nil }
        event.rawName = rawName
        return event
    }
}
