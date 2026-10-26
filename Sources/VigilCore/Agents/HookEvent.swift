import Foundation

/// One event posted by an agent's hook (Claude Code's hook JSON shape, which other
/// agents' hooks are mapped onto).
public struct HookEvent: Sendable, Hashable {
    public enum Name: String, Sendable, Codable {
        case sessionStart = "SessionStart"
        case sessionEnd = "SessionEnd"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        /// A tool call that failed (a command exiting non-zero) or was interrupted. Claude Code
        /// sends this instead of PostToolUse.
        case postToolUseFailure = "PostToolUseFailure"
        /// Every tool call from one model response has resolved, denied ones included.
        case postToolBatch = "PostToolBatch"
        case permissionRequest = "PermissionRequest"
        /// Auto mode's classifier turned a tool call down; no dialog was shown.
        case permissionDenied = "PermissionDenied"
        case notification = "Notification"
        case stop = "Stop"
        /// The turn ended on an API error (rate limit, overload, auth); sent instead of Stop.
        case stopFailure = "StopFailure"
        case subagentStop = "SubagentStop"
        case preCompact = "PreCompact"
        case other = "Other"
    }

    public var name: Name
    public var rawName: String
    public var agent: AgentKind
    public var sessionID: String?
    public var cwd: String?
    public var transcriptPath: String?
    public var toolName: String?
    public var toolUseID: String?
    /// Absolute path of the file a tool targets, when the tool input names one.
    public var filePath: String?
    /// Short human-readable description of the tool input (a command, a pattern, a path).
    public var summary: String?
    public var message: String?
    /// Claude Code's kind of notification: `permission_prompt`, `idle_prompt`, `elicitation_dialog`,
    /// `auth_success`. Hermes input requests are mapped to `question`.
    public var notificationType: String?
    /// Set when a subagent's tool sent the event; nil for the main agent.
    public var agentID: String?
    /// PostToolUseFailure: the call was stopped rather than failing on its own.
    public var isInterrupt: Bool
    /// PostToolBatch: the tool calls that resolved.
    public var batchToolUseIDs: [String]
    public var receivedAt: Date

    public init(name: Name, rawName: String, agent: AgentKind = .claudeCode, sessionID: String? = nil, cwd: String? = nil,
                transcriptPath: String? = nil, toolName: String? = nil, toolUseID: String? = nil, filePath: String? = nil,
                summary: String? = nil, message: String? = nil, notificationType: String? = nil, agentID: String? = nil,
                isInterrupt: Bool = false, batchToolUseIDs: [String] = [], receivedAt: Date = Date()) {
        self.name = name
        self.rawName = rawName
        self.agent = agent
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.toolName = toolName
        self.toolUseID = toolUseID
        self.filePath = filePath
        self.summary = summary
        self.message = message
        self.notificationType = notificationType
        self.agentID = agentID
        self.isInterrupt = isInterrupt
        self.batchToolUseIDs = batchToolUseIDs
        self.receivedAt = receivedAt
    }

    /// Absolute paths mentioned in the summary or message, for matching events whose `cwd`
    /// is not useful (gateway agents run with their own working directory).
    public var absolutePathHints: [String] {
        var hints: [String] = []
        for text in [summary, message].compactMap({ $0 }) {
            for token in text.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "`" }) {
                var piece = String(token)
                while let last = piece.last, ";:,)]}".contains(last) { piece.removeLast() }
                if piece.hasPrefix("/"), piece.count > 1 { hints.append(piece) }
            }
        }
        return hints
    }

    /// Tools that change files or run commands; the ones worth a feed entry by default.
    public var isMutatingTool: Bool {
        guard let toolName else { return false }
        return Self.mutatingTools.contains(toolName) || toolName.hasPrefix("mcp__") && toolName.lowercased().contains("write")
    }

    /// Tools that stop and ask you something; the agent is blocked until you answer.
    public var isQuestionTool: Bool { toolName.map(Self.questionTools.contains) ?? false }

    static let questionTools: Set<String> = ["AskUserQuestion"]

    static let mutatingTools: Set<String> = [
        // Claude Code
        "Edit", "Write", "MultiEdit", "NotebookEdit", "Bash", "Task", "Agent",
        // Hermes
        "terminal", "write_file", "patch", "apply_patch", "edit_file", "delete_file", "execute_code", "delegate_task",
    ]
}

public enum HookEventParser {
    public static func parse(_ data: Data, receivedAt: Date = Date(), agent: AgentKind = .claudeCode) -> HookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(object, receivedAt: receivedAt, agent: agent)
    }

    /// `resolveRelativePaths` joins a relative tool path with `cwd`; pass false when `cwd` is
    /// the agent process's directory rather than the session's.
    public static func parse(_ object: [String: Any], receivedAt: Date = Date(), agent: AgentKind = .claudeCode,
                             resolveRelativePaths: Bool = true) -> HookEvent? {
        guard let rawName = object["hook_event_name"] as? String else { return nil }
        let name = HookEvent.Name(rawValue: rawName) ?? .other
        let cwd = object["cwd"] as? String
        let toolName = object["tool_name"] as? String
        let toolInput = object["tool_input"] as? [String: Any]
        var filePath: String? = nil
        var summary: String? = nil

        if let toolInput {
            if let path = (toolInput["file_path"] ?? toolInput["notebook_path"] ?? toolInput["path"]) as? String, !path.isEmpty {
                if path.hasPrefix("/") || !resolveRelativePaths {
                    filePath = path
                } else {
                    filePath = cwd.map { ($0 as NSString).appendingPathComponent(path) } ?? path
                }
                summary = path
            } else if let questions = toolInput["questions"] as? [[String: Any]],
                      let question = questions.first?["question"] as? String {
                summary = firstLine(question)  // AskUserQuestion
            } else if let command = toolInput["command"] as? String {
                summary = firstLine(command)
            } else if let pattern = toolInput["pattern"] as? String {
                summary = pattern
            } else if let url = toolInput["url"] as? String {
                summary = url
            } else if let description = toolInput["description"] as? String {
                summary = description
            } else if let prompt = toolInput["prompt"] as? String {
                summary = firstLine(prompt)
            } else if let first = toolInput.values.first(where: { $0 is String }) as? String {
                summary = firstLine(first)
            }
        }
        var message = object["message"] as? String
        if message == nil, let prompt = object["prompt"] as? String, name == .userPromptSubmit {
            message = firstLine(prompt)
        }
        if message == nil, let reason = object["reason"] as? String { message = reason }
        if message == nil, let source = object["source"] as? String, name == .sessionStart { message = source }
        // A failed tool's error ("Exit code 1", then its output), or why a turn failed.
        if message == nil, let error = object["error"] as? String { message = firstLine(error) }
        let batch = (object["tool_calls"] as? [[String: Any]] ?? []).compactMap { $0["tool_use_id"] as? String }

        return HookEvent(
            name: name, rawName: rawName, agent: agent,
            sessionID: object["session_id"] as? String,
            cwd: cwd,
            transcriptPath: object["transcript_path"] as? String,
            toolName: toolName,
            toolUseID: object["tool_use_id"] as? String,
            filePath: filePath,
            // Long enough for a deep absolute path, so views can shorten it relative to its worktree.
            summary: summary.map { String($0.prefix(400)) },
            message: message.map { String($0.prefix(200)) },
            notificationType: object["notification_type"] as? String,
            agentID: object["agent_id"] as? String,
            isInterrupt: object["is_interrupt"] as? Bool ?? false,
            batchToolUseIDs: batch,
            receivedAt: receivedAt)
    }

    private static func firstLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
    }
}
