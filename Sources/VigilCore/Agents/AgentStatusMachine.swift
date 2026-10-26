import Foundation

/// What an agent is doing in a worktree, as far as its hooks have told us.
public enum AgentActivity: Sendable, Hashable, Codable {
    case working(tool: String?, detail: String?)
    case needsPermission(tool: String, detail: String?)
    /// Blocked on a question for you: a clarifying question or a dialog asking for input.
    case askedQuestion(detail: String?)
    /// Finished its turn and ready for your next prompt. Nothing is blocked on you.
    case ready
    /// The session ended.
    case idle

    /// Blocked until you act: only permission requests and real questions.
    public var needsAttention: Bool {
        switch self {
        case .needsPermission, .askedQuestion: true
        case .working, .ready, .idle: false
        }
    }

    public var title: String {
        switch self {
        case .working(let tool, _): tool.map { "working · \($0)" } ?? "working"
        case .needsPermission(let tool, _): "needs permission for \(tool)"
        case .askedQuestion: "has a question for you"
        case .ready: "ready for your next prompt"
        case .idle: "idle"
        }
    }
}

/// One tool invocation seen through PreToolUse/PostToolUse.
public struct AgentToolCall: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var toolName: String
    public var summary: String?
    public var filePath: String?
    public var startedAt: Date
    public var finishedAt: Date?
    /// The call failed (a command exiting non-zero) or was interrupted.
    public var failed: Bool

    public init(id: String, toolName: String, summary: String?, filePath: String?, startedAt: Date, finishedAt: Date? = nil,
                failed: Bool = false) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.filePath = filePath
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.failed = failed
    }

    public var isMutating: Bool { HookEvent.mutatingTools.contains(toolName) }
    public var category: AgentToolCategory { AgentToolCategory(toolName: toolName) }
}

/// What kind of step a tool call is, across agents' differing tool names.
public enum AgentToolCategory: String, Sendable, Hashable, CaseIterable {
    case edit, command, read, search, web, subagent, question, other

    public init(toolName: String) {
        switch toolName {
        case "Edit", "Write", "MultiEdit", "NotebookEdit",
             "write_file", "patch", "apply_patch", "edit_file", "delete_file":
            self = .edit
        case "Bash", "BashOutput", "KillShell", "terminal", "execute_code", "process":
            self = .command
        case "Read", "NotebookRead", "read_file", "view_file":
            self = .read
        case "Grep", "Glob", "LS", "search_files", "list_files", "find_files":
            self = .search
        case "WebFetch", "WebSearch", "web_search", "web_extract":
            self = .web
        case "Task", "Agent", "delegate_task":
            self = .subagent
        case "AskUserQuestion", "clarify":
            self = .question
        default:
            self = toolName.hasPrefix("browser") ? .web : .other
        }
    }
}

/// A permission request still open: which call asked, and for whom.
public struct PendingPermission: Sendable, Hashable, Codable {
    /// The tool call waiting on you, when it could be matched to one.
    public var callID: String?
    /// The subagent that asked; nil for the main agent.
    public var agentID: String?
    /// For a Claude Code shell command, the command's first line.
    public var command: String?

    public init(callID: String?, agentID: String?, command: String? = nil) {
        self.callID = callID
        self.agentID = agentID
        self.command = command
    }
}

public struct AgentStatus: Sendable, Hashable, Codable {
    public var agent: AgentKind
    public var activity: AgentActivity
    public var since: Date
    public var lastEventAt: Date
    public var sessionID: String?
    public var turnStartedAt: Date?
    public var toolCallsThisTurn: Int
    public var recentToolCalls: [AgentToolCall]
    /// The prompt that started the current (or, once it ends, the last) turn.
    public var task: String?
    /// When the last turn began; unlike `turnStartedAt` it survives the turn's end.
    public var lastTurnStartedAt: Date?
    /// Set while `activity` is `needsPermission`.
    public var pendingPermission: PendingPermission?

    public init(agent: AgentKind, activity: AgentActivity, since: Date, lastEventAt: Date, sessionID: String? = nil,
                turnStartedAt: Date? = nil, toolCallsThisTurn: Int = 0, recentToolCalls: [AgentToolCall] = []) {
        self.agent = agent
        self.activity = activity
        self.since = since
        self.lastEventAt = lastEventAt
        self.sessionID = sessionID
        self.turnStartedAt = turnStartedAt
        self.toolCallsThisTurn = toolCallsThisTurn
        self.recentToolCalls = recentToolCalls
    }

    /// The current turn's tool calls, or the last turn's once it has ended, oldest first.
    public var turnToolCalls: [AgentToolCall] {
        guard let start = turnStartedAt ?? lastTurnStartedAt else { return Array(recentToolCalls.suffix(10)) }
        return recentToolCalls.filter { $0.startedAt >= start }
    }

    /// The Claude Code shell command waiting on your permission, and since when.
    public var commandAwaitingPermission: (command: String, since: Date)? {
        guard agent == .claudeCode, case .needsPermission = activity, let command = pendingPermission?.command else { return nil }
        return (command, since)
    }

    /// The tool call running at `date`, or one that finished within `grace` seconds before it.
    public func toolCall(activeAt date: Date, grace: TimeInterval = 3) -> AgentToolCall? {
        recentToolCalls.last { call in
            call.startedAt <= date.addingTimeInterval(1) && (call.finishedAt ?? .distantFuture) >= date.addingTimeInterval(-grace)
        }
    }
}

/// A feed-worthy consequence of applying a hook event.
public struct AgentNote: Sendable, Hashable {
    public enum Kind: String, Sendable { case sessionStarted, sessionEnded, turnStarted, turnFinished, needsPermission, waiting, toolCall, notification }
    public var kind: Kind
    public var title: String
    public var detail: String?
    public var filePath: String?
    public var isMutatingTool: Bool

    public init(kind: Kind, title: String, detail: String? = nil, filePath: String? = nil, isMutatingTool: Bool = false) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.filePath = filePath
        self.isMutatingTool = isMutatingTool
    }
}

/// Folds hook events into an `AgentStatus` for one worktree.
public struct AgentStatusMachine: Sendable {
    public private(set) var status: AgentStatus?
    private let maxToolCalls = 200

    public init() {}

    public mutating func apply(_ event: HookEvent) -> [AgentNote] {
        let now = event.receivedAt
        var current = status ?? AgentStatus(agent: event.agent, activity: .idle, since: now, lastEventAt: now)
        current.agent = event.agent
        current.lastEventAt = now
        if let session = event.sessionID { current.sessionID = session }
        var notes: [AgentNote] = []
        let agentName = event.agent.displayName

        func set(_ activity: AgentActivity) {
            if case .needsPermission = activity {} else { current.pendingPermission = nil }
            if current.activity != activity {
                current.activity = activity
                current.since = now
            }
        }

        /// Marks a call finished; returns its id when one matched.
        @discardableResult
        func finish(id: String?, tool: String?, failed: Bool = false) -> String? {
            let index = id.flatMap { id in current.recentToolCalls.lastIndex { $0.id == id } }
                ?? current.recentToolCalls.lastIndex { $0.finishedAt == nil && $0.toolName == tool }
            guard let index else { return nil }
            if current.recentToolCalls[index].finishedAt == nil { current.recentToolCalls[index].finishedAt = now }
            if failed { current.recentToolCalls[index].failed = true }
            return current.recentToolCalls[index].id
        }

        /// Whether a call ending (`id`, from `agentID`) answers the open permission request, if any.
        /// While a subagent waits on you, the others carry on; their calls settle nothing.
        func settlesPermission(_ id: String?, agentID: String?) -> Bool {
            guard case .needsPermission = current.activity, let pending = current.pendingPermission else { return true }
            if let pendingID = pending.callID { return pendingID == id }
            return pending.agentID == agentID
        }

        /// A turn that ended (or was abandoned for a new one) leaves nothing running.
        func closeOpenCalls() {
            for index in current.recentToolCalls.indices where current.recentToolCalls[index].finishedAt == nil {
                current.recentToolCalls[index].finishedAt = now
            }
        }

        switch event.name {
        case .sessionStart:
            set(.ready)
            current.turnStartedAt = nil
            current.toolCallsThisTurn = 0
            notes.append(AgentNote(kind: .sessionStarted, title: "\(agentName) session started", detail: event.message))

        case .sessionEnd:
            set(.idle)
            closeOpenCalls()
            notes.append(AgentNote(kind: .sessionEnded, title: "\(agentName) session ended", detail: event.message))

        case .userPromptSubmit:
            // Hermes fires its equivalent before every model call, and again when you answer its
            // question; only a fresh turn resets the counters.
            let midTurn: Bool
            switch current.activity {
            case .working, .askedQuestion, .needsPermission: midTurn = current.turnStartedAt != nil
            case .ready, .idle: midTurn = false
            }
            // A prompt while a dialog was open means it was dismissed (Esc ends the turn without a Stop).
            if case .needsPermission = current.activity, let id = current.pendingPermission?.callID {
                finish(id: id, tool: nil)
            }
            if midTurn {
                set(.working(tool: nil, detail: nil))
                if current.task == nil, let message = event.message { current.task = message }
            } else {
                closeOpenCalls()
                set(.working(tool: nil, detail: nil))
                current.turnStartedAt = now
                current.lastTurnStartedAt = now
                current.task = event.message
                current.toolCallsThisTurn = 0
                notes.append(AgentNote(kind: .turnStarted, title: "\(agentName) started a turn", detail: event.message))
            }

        case .preToolUse:
            let tool = event.toolName ?? "tool"
            current.toolCallsThisTurn += 1
            let call = AgentToolCall(id: event.toolUseID ?? UUID().uuidString, toolName: tool, summary: event.summary,
                                     filePath: event.filePath, startedAt: now)
            current.recentToolCalls.append(call)
            if current.recentToolCalls.count > maxToolCalls { current.recentToolCalls.removeFirst(current.recentToolCalls.count - maxToolCalls) }
            let waitingElsewhere: Bool
            if case .needsPermission = current.activity, let pending = current.pendingPermission {
                // One agent moving on settles its own request; a subagent waiting on you does
                // not stop the others.
                waitingElsewhere = pending.agentID != event.agentID
            } else {
                waitingElsewhere = false
            }
            if event.isQuestionTool {
                // The tool waits for your answer; PostToolUse arrives once you give it.
                set(.askedQuestion(detail: event.summary))
                notes.append(AgentNote(kind: .waiting, title: "\(agentName) has a question for you", detail: event.summary))
            } else {
                if !waitingElsewhere { set(.working(tool: tool, detail: event.summary)) }
                notes.append(AgentNote(kind: .toolCall, title: "\(agentName): \(tool)", detail: event.summary,
                                       filePath: event.filePath, isMutatingTool: event.isMutatingTool))
            }

        case .postToolUse, .postToolUseFailure, .permissionDenied:
            let finished = finish(id: event.toolUseID, tool: event.toolName, failed: event.name != .postToolUse)
            if settlesPermission(finished ?? event.toolUseID, agentID: event.agentID) { set(.working(tool: nil, detail: nil)) }

        case .postToolBatch:
            // Denied calls get no PostToolUse; the batch is the only word that they are done.
            for id in event.batchToolUseIDs { finish(id: id, tool: nil) }
            let settled: Bool
            if case .needsPermission = current.activity, let pending = current.pendingPermission {
                settled = pending.callID.map(event.batchToolUseIDs.contains) ?? (pending.agentID == event.agentID)
            } else {
                settled = event.agentID == nil
            }
            if settled, current.turnStartedAt != nil { set(.working(tool: nil, detail: nil)) }

        case .permissionRequest:
            // The request carries no tool_use_id: it belongs to the call PreToolUse just announced.
            let tool = event.toolName ?? "a tool"
            let call = current.recentToolCalls.last { call in
                call.finishedAt == nil && call.toolName == tool && (event.summary == nil || call.summary == event.summary)
            }
            set(.needsPermission(tool: tool, detail: event.summary))
            current.pendingPermission = PendingPermission(
                callID: event.toolUseID ?? call?.id, agentID: event.agentID,
                command: event.agent == .claudeCode && tool == "Bash" ? event.summary : nil)
            notes.append(AgentNote(kind: .needsPermission, title: "\(agentName) needs permission: \(tool)", detail: event.summary,
                                   filePath: event.filePath))

        case .notification:
            switch NotificationKind(event) {
            case .permission:
                // Claude Code reminds you six seconds into an unanswered dialog; the request
                // itself already said what the permission is for.
                if case .needsPermission = current.activity { break }
                let tool = event.toolName ?? Self.permissionTool(in: event.message) ?? "a tool"
                set(.needsPermission(tool: tool, detail: event.summary ?? event.message))
                current.pendingPermission = PendingPermission(callID: nil, agentID: event.agentID)
                notes.append(AgentNote(kind: .needsPermission, title: "\(agentName) needs permission", detail: event.message))
            case .question:
                set(.askedQuestion(detail: event.message))
                notes.append(AgentNote(kind: .waiting, title: "\(agentName) has a question for you", detail: event.message))
            case .idleReminder:
                // "Claude is waiting for your input": a nudge some time after the turn ended,
                // not a question. Nothing new to say beyond the turn having finished.
                set(.ready)
            case .other:
                notes.append(AgentNote(kind: .notification, title: "\(agentName): \(event.message ?? "notification")"))
            }

        case .stop, .stopFailure:
            set(.ready)
            closeOpenCalls()
            var detail: String? = nil
            if let started = current.turnStartedAt {
                let seconds = Int(now.timeIntervalSince(started))
                let calls = current.toolCallsThisTurn == 1 ? "1 tool call" : "\(current.toolCallsThisTurn) tool calls"
                detail = "\(calls) in \(seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s")"
            }
            if event.name == .stopFailure {
                let reason = event.message.map { $0.replacingOccurrences(of: "_", with: " ") }
                notes.append(AgentNote(kind: .turnFinished, title: "\(agentName)'s turn ended on an error",
                                       detail: [reason, detail].compactMap { $0 }.joined(separator: " · ")))
            } else {
                notes.append(AgentNote(kind: .turnFinished, title: "\(agentName) finished a turn", detail: detail))
            }
            current.turnStartedAt = nil

        case .subagentStop:
            notes.append(AgentNote(kind: .notification, title: "\(agentName) subagent finished"))

        case .preCompact, .other:
            break
        }

        status = current
        return notes
    }

    /// You approved the shell command that was waiting: it is running. Claude Code sends no
    /// hook between the approval and the command finishing, so this comes from seeing the
    /// command's process. Returns false when nothing was waiting.
    public mutating func noteApproved(at date: Date = Date()) -> Bool {
        guard var current = status, case .needsPermission(let tool, let detail) = current.activity else { return false }
        current.activity = .working(tool: tool, detail: detail)
        current.pendingPermission = nil
        current.since = date
        status = current
        return true
    }

    /// "Claude needs your permission to use Bash" → "Bash".
    static func permissionTool(in message: String?) -> String? {
        guard let message, let range = message.range(of: "permission to use ") else { return nil }
        return message[range.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    private enum NotificationKind {
        case permission, question, idleReminder, other

        init(_ event: HookEvent) {
            switch event.notificationType {
            case "permission_prompt": self = .permission
            case "idle_prompt": self = .idleReminder
            case "elicitation_dialog", "question": self = .question
            case .some: self = .other
            case nil:
                // Older Claude Code versions send only the message.
                let text = (event.message ?? "").lowercased()
                if text.contains("permission") {
                    self = .permission
                } else if text.contains("waiting for your input") || text.contains("idle") {
                    self = .idleReminder
                } else {
                    self = .other
                }
            }
        }
    }

    /// Forget a status whose agent has been silent and has no process alive.
    public mutating func expire(olderThan interval: TimeInterval, now: Date = Date()) {
        if let status, now.timeIntervalSince(status.lastEventAt) > interval {
            self.status = nil
        }
    }
}
