import Foundation

/// One event posted by an agent's hook (Claude Code's hook JSON shape, which other
/// agents' hooks are mapped onto).
public struct HookEvent: Sendable, Hashable {
    public enum Name: String, Sendable, Codable, CaseIterable {
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
    /// Set when the agent's hook waits for Mimamori to answer this permission request.
    public var permissionRequestID: String? = nil
    /// A shell tool's whole command (`summary` has its first line), for matching permission rules.
    public var command: String? = nil
    /// The command was longer than `commandLimit`, so `command` is cut short and can't be checked
    /// in full against ask rules.
    public var commandTruncated = false
    /// How much of a command is kept: far more than a real one, short of a runaway heredoc.
    public static let commandLimit = 64 * 1024
    /// The subagent's kind (`agent_type`, such as `Explore`) when one sent the event.
    public var agentType: String? = nil
    /// What's still in flight (`background_tasks`, on Stop and SubagentStop): running subagents and
    /// commands run in the background. Nil when the event doesn't say.
    public var backgroundTasks: [BackgroundTask]? = nil
    /// SubagentStop: the subagent's last words (`last_assistant_message`), shortened.
    public var lastMessage: String? = nil
    /// The `Agent` (or `Task`) call that launches a subagent, and on its PostToolUse what came back.
    public var subagentLaunch: SubagentLaunch? = nil
    /// A command run in the background (`run_in_background`), and on its PostToolUse its task id.
    public var commandLaunch: CommandLaunch? = nil
    /// A prompt that is Claude Code telling the agent a background task ended (`<task-notification>`).
    public var taskNotification: TaskNotification? = nil
    /// The worktree a subagent works in, when it isn't its session's: one Claude Code made for it.
    /// Set by whoever places the event.
    public var subagentWorktree: String? = nil
    /// Hermes: the task of the turn that made the call. A tool run from `execute_code` names it but
    /// no session, so it tells which session the call belongs to (see `HermesTaskSessions`).
    public var hermesTaskID: String? = nil

    public struct CommandLaunch: Sendable, Hashable {
        public var description: String?
        /// Its first line.
        public var command: String?
        /// `tool_response.backgroundTaskId`, on PostToolUse.
        public var taskID: String?

        public init(description: String? = nil, command: String? = nil, taskID: String? = nil) {
            self.description = description
            self.command = command
            self.taskID = taskID
        }
    }

    /// `<task-notification><task-id>…</task-id><status>completed</status><summary>Background command
    /// "Watch CI" completed (exit code 0)</summary>…`
    public struct TaskNotification: Sendable, Hashable {
        public var taskID: String
        /// `completed`, `failed`, `killed`, …
        public var status: String?
        public var summary: String?

        public init(taskID: String, status: String? = nil, summary: String? = nil) {
            self.taskID = taskID
            self.status = status
            self.summary = summary
        }

        /// The exit code its summary gives: "… (exit code 1)".
        public var exitCode: Int? {
            guard let summary, let range = summary.range(of: "(exit code ") else { return nil }
            return Int(summary[range.upperBound...].prefix { $0.isNumber || $0 == "-" })
        }

        /// The notification in a prompt, or nil for an ordinary prompt.
        public static func parse(_ prompt: String) -> TaskNotification? {
            guard prompt.hasPrefix("<task-notification>") else { return nil }
            func value(_ tag: String) -> String? {
                guard let open = prompt.range(of: "<\(tag)>"), let close = prompt.range(of: "</\(tag)>", range: open.upperBound..<prompt.endIndex)
                else { return nil }
                return String(prompt[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let id = value("task-id"), !id.isEmpty else { return nil }
            return TaskNotification(taskID: id, status: value("status"), summary: value("summary"))
        }
    }

    /// A task `background_tasks` lists.
    public struct BackgroundTask: Sendable, Hashable {
        /// For a subagent, its `agent_id`.
        public var id: String
        /// `subagent`, `shell`, …
        public var type: String
        public var status: String?
        public var description: String?
        public var agentType: String?

        public init(id: String, type: String, status: String? = nil, description: String? = nil, agentType: String? = nil) {
            self.id = id
            self.type = type
            self.status = status
            self.description = description
            self.agentType = agentType
        }

        public var isSubagent: Bool { type == "subagent" }
        public var isRunning: Bool { status == nil || status == "running" }
    }

    /// What an `Agent` call asked for: `tool_input`, and on PostToolUse `tool_response`'s
    /// `status` (`completed`, or `async_launched` for one sent to the background) and `agentId`.
    public struct SubagentLaunch: Sendable, Hashable {
        public var subagentType: String?
        public var description: String?
        public var background: Bool
        public var isolation: String?
        public var status: String?
        public var agentID: String?

        public init(subagentType: String? = nil, description: String? = nil, background: Bool = false,
                    isolation: String? = nil, status: String? = nil, agentID: String? = nil) {
            self.subagentType = subagentType
            self.description = description
            self.background = background
            self.isolation = isolation
            self.status = status
            self.agentID = agentID
        }
    }

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
        // Cursor
        "Shell", "Delete",
        // Gemini CLI
        "run_shell_command", "replace",
    ]
}

public enum HookEventParser {
    /// Names of tool inputs never shown as a summary: file contents, edits, credentials.
    static let privateInputNames = ["content", "string", "text", "body", "data", "patch", "diff", "token", "password",
                                    "secret", "key", "credential", "auth", "cookie"]

    /// A text input to describe an unknown tool by: the first, by name, that isn't private, so
    /// the same call reads the same each time and nothing secret or bulky is shown.
    static func describingValue(in input: [String: Any]) -> String? {
        for name in input.keys.sorted() {
            let lower = name.lowercased()
            guard !privateInputNames.contains(where: { lower.contains($0) }),
                  let value = input[name] as? String, !value.isEmpty else { continue }
            return value
        }
        return nil
    }

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

        func resolved(_ path: String) -> String {
            if path.hasPrefix("/") || !resolveRelativePaths { return path }
            return cwd.map { ($0 as NSString).appendingPathComponent(path) } ?? path
        }

        if let toolInput {
            if let path = (toolInput["file_path"] ?? toolInput["notebook_path"] ?? toolInput["path"] ?? toolInput["absolute_path"]) as? String,
               !path.isEmpty {
                filePath = resolved(path)
                summary = path
            } else if let command = toolInput["command"] as? String, let path = patchedFile(in: command) {
                filePath = resolved(path)  // Codex's apply_patch
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
            } else if let first = HookEventParser.describingValue(in: toolInput) {
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

        var event = HookEvent(
            name: name, rawName: rawName, agent: agent,
            // Hermes sends "" when it has no session for a call.
            sessionID: (object["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
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
        // Whole, up to a limit: ask rules are matched against it, and a part cut off could be the
        // part a rule is about. Longer than that, it's flagged, and never allowed by itself.
        if let command = toolInput?["command"] as? String {
            event.command = String(command.prefix(HookEvent.commandLimit))
            event.commandTruncated = command.count > HookEvent.commandLimit
        }
        event.agentType = object["agent_type"] as? String
        event.lastMessage = (object["last_assistant_message"] as? String).map { String(firstLine($0).prefix(300)) }
        if let tasks = object["background_tasks"] as? [[String: Any]] {
            event.backgroundTasks = tasks.compactMap { task -> HookEvent.BackgroundTask? in
                guard let id = task["id"] as? String, let type = task["type"] as? String else { return nil }
                return HookEvent.BackgroundTask(id: id, type: type, status: task["status"] as? String,
                                      description: task["description"] as? String, agentType: task["agent_type"] as? String)
            }
        }
        if let toolInput, toolInput["run_in_background"] as? Bool == true, toolName != "Agent", toolName != "Task" {
            let response = object["tool_response"] as? [String: Any]
            event.commandLaunch = HookEvent.CommandLaunch(
                description: toolInput["description"] as? String, command: (toolInput["command"] as? String).map(firstLine),
                taskID: response?["backgroundTaskId"] as? String)
        }
        if name == .userPromptSubmit, let prompt = object["prompt"] as? String,
           let notification = HookEvent.TaskNotification.parse(prompt) {
            event.taskNotification = notification
            // The turn's task reads as what happened, not as the notification's markup.
            event.message = notification.summary ?? event.message
        }
        if toolName == "Agent" || toolName == "Task", let toolInput {
            let response = object["tool_response"] as? [String: Any]
            event.subagentLaunch = HookEvent.SubagentLaunch(
                subagentType: toolInput["subagent_type"] as? String, description: toolInput["description"] as? String,
                background: toolInput["run_in_background"] as? Bool ?? false, isolation: toolInput["isolation"] as? String,
                status: response?["status"] as? String, agentID: response?["agentId"] as? String)
        }
        return event
    }

    /// The first file a patch in the `*** Begin Patch` format changes.
    static func patchedFile(in text: String) -> String? {
        guard text.hasPrefix("*** Begin Patch") else { return nil }
        for line in text.split(separator: "\n").prefix(20) {
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty { return path }
            }
        }
        return nil
    }

    private static func firstLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
    }
}
