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

    /// Lower is more pressing: waiting on you, then working, then ready, then ended.
    public var urgency: Int {
        switch self {
        case .needsPermission, .askedQuestion: 0
        case .working: 1
        case .ready: 2
        case .idle: 3
        }
    }

    public var title: String {
        switch self {
        case .working(let tool, _): tool.map { "working · \($0)" } ?? "working"
        case .needsPermission(let tool, _): tool.isEmpty ? "needs permission" : "needs permission for \(tool)"
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
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "Delete",
             "write_file", "patch", "apply_patch", "edit_file", "delete_file", "replace":
            self = .edit
        case "Bash", "BashOutput", "KillShell", "Shell", "terminal", "execute_code", "process", "run_shell_command":
            self = .command
        case "Read", "NotebookRead", "read_file", "view_file", "read_many_files":
            self = .read
        case "Grep", "Glob", "LS", "search_files", "list_files", "find_files", "glob", "search_file_content", "list_directory":
            self = .search
        case "WebFetch", "WebSearch", "web_search", "web_extract", "web_fetch", "google_web_search":
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

    /// Whether `event`, from the same session, settles this request: the call that asked ended
    /// (with no call matched to it, a call of the asking agent's ended), the turn or session
    /// ended, a new prompt came, or another request took its place. While a subagent waits on you
    /// the others carry on, so their calls settle nothing; nor does Claude Code's reminder that it
    /// is waiting, nor another call starting, since the request's hook may still wait meanwhile.
    /// `endedCall` is the call a PostToolUse, PostToolUseFailure or PermissionDenied ended, as
    /// the status matched it (by tool name, for an agent that sends no call id); by default, the
    /// call the event names.
    public func isSettled(by event: HookEvent, endedCall: String? = nil) -> Bool {
        switch event.name {
        case .postToolUse, .postToolUseFailure, .permissionDenied:
            if let callID { return callID == (endedCall ?? event.toolUseID) }
            return agentID == event.agentID
        case .postToolBatch:
            if let callID { return event.batchToolUseIDs.contains(callID) }
            return agentID == event.agentID
        case .permissionRequest, .stop, .stopFailure, .userPromptSubmit, .sessionStart, .sessionEnd:
            return true
        case .preToolUse, .notification, .subagentStop, .preCompact, .other:
            return false
        }
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
    /// The status comes from the agent's own record of the session, not its hooks: none has
    /// reported since Mimamori started. For Claude Code that is its session file, for Hermes the
    /// lease on a turn under way. The session's first hook event takes over.
    public var fromSessionRecord = false
    /// Mimamori did not hear the current turn begin: it started in the middle of the turn, which
    /// so far starts at the first step heard. `AgentStatusMachine.backdateTurn(to:)` moves the
    /// start back to when the agent's own record says the turn began.
    public var turnStartUnheard = false
    /// When the session's previous turn ended, as far as Mimamori heard.
    public var lastTurnEndedAt: Date?

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

    /// What tells this session apart from others in its worktree: its id, or for an agent whose
    /// hooks send none, the agent itself.
    public var key: String { Self.key(session: sessionID, agent: agent) }

    public static func key(session: String?, agent: AgentKind) -> String {
        session.flatMap { $0.isEmpty ? nil : $0 } ?? "agent:" + agent.id
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
    public enum Kind: String, Sendable {
        case sessionStarted, sessionEnded, turnStarted, turnFinished, needsPermission, waiting, toolCall, notification
        /// A second agent started working in the same worktree.
        case sharedWorktree
        /// Two agents edited the same file.
        case collision
    }
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
        let otherSession = event.sessionID.flatMap { session in current.sessionID.map { $0 != session } } ?? false
        let heardBefore = status != nil && !otherSession && current.agent == event.agent
        if status != nil, otherSession || current.agent != event.agent {
            // Another session took the worktree over, perhaps another agent: the last one's turn,
            // task and open steps are not this one's. Its calls stay, so its changes stay credited.
            for index in current.recentToolCalls.indices where current.recentToolCalls[index].finishedAt == nil {
                current.recentToolCalls[index].finishedAt = now
            }
            current.activity = .ready
            current.since = now
            current.task = nil
            current.turnStartedAt = nil
            current.lastTurnStartedAt = now
            current.toolCallsThisTurn = 0
            current.pendingPermission = nil
            current.sessionID = nil
            current.turnStartUnheard = false
            current.lastTurnEndedAt = nil
        }
        current.agent = event.agent
        current.lastEventAt = now
        current.fromSessionRecord = false
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

        /// Whether a call ending (`endedCall`) answers the open permission request, if any.
        func settlesPermission(endedCall: String?) -> Bool {
            guard case .needsPermission = current.activity, let pending = current.pendingPermission else { return true }
            return pending.isSettled(by: event, endedCall: endedCall)
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
            current.turnStartUnheard = false
            current.toolCallsThisTurn = 0
            notes.append(AgentNote(kind: .sessionStarted, title: "\(agentName) session started", detail: event.message))

        case .sessionEnd:
            set(.idle)
            closeOpenCalls()
            current.lastTurnEndedAt = now
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
                // Hermes's prompt hook fires before every model call: the first one heard from a
                // session may come in the middle of its turn.
                current.turnStartUnheard = event.agent == .hermes && !heardBefore
                current.task = event.message
                current.toolCallsThisTurn = 0
                notes.append(AgentNote(kind: .turnStarted, title: "\(agentName) started a turn", detail: event.message))
            }

        case .preToolUse:
            let tool = event.toolName ?? "tool"
            // A call with no turn under way: Mimamori started (or restarted) mid-turn and never saw
            // the prompt. The turn starts here, so its steps, files and timeline still show.
            if current.turnStartedAt == nil {
                current.turnStartedAt = now
                current.lastTurnStartedAt = now
                current.turnStartUnheard = true
                current.toolCallsThisTurn = 0
            }
            current.toolCallsThisTurn += 1
            let call = AgentToolCall(id: event.toolUseID ?? UUID().uuidString, toolName: tool, summary: event.summary,
                                     filePath: event.filePath, startedAt: now)
            current.recentToolCalls.append(call)
            if current.recentToolCalls.count > maxToolCalls { current.recentToolCalls.removeFirst(current.recentToolCalls.count - maxToolCalls) }
            let waitingElsewhere: Bool
            if case .needsPermission = current.activity, let pending = current.pendingPermission {
                // One agent moving on settles its own request; a subagent waiting on you does
                // not stop the others. Unlike `isSettled(by:)`, this guesses: for an agent with no
                // hook waiting on the request, the next call may be the only word it was answered.
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
            if settlesPermission(endedCall: finished) { set(.working(tool: nil, detail: nil)) }

        case .postToolBatch:
            // Denied calls get no PostToolUse; the batch is the only word that they are done.
            for id in event.batchToolUseIDs { finish(id: id, tool: nil) }
            let settled: Bool
            if case .needsPermission = current.activity, let pending = current.pendingPermission {
                settled = pending.isSettled(by: event)
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
                // Gemini CLI's alert names its tool, so the step waiting on you can be found.
                let call = event.toolName.flatMap { name in current.recentToolCalls.last { $0.finishedAt == nil && $0.toolName == name } }
                current.pendingPermission = PendingPermission(callID: call?.id, agentID: event.agentID)
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
            current.turnStartUnheard = false
            current.lastTurnEndedAt = now

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
        current.activity = .working(tool: tool.isEmpty ? nil : tool, detail: detail)
        current.pendingPermission = nil
        current.since = date
        status = current
        return true
    }

    /// You said no in the agent's own prompt: the call did not run, and the agent stopped to
    /// wait for what to do instead, sending no hook to say so (Claude Code ends the permission
    /// hook, and that is all). Returns false when nothing was waiting.
    public mutating func noteDeclined(at date: Date = Date()) -> Bool {
        guard var current = status, case .needsPermission = current.activity else { return false }
        if let id = current.pendingPermission?.callID,
           let index = current.recentToolCalls.firstIndex(where: { $0.id == id && $0.finishedAt == nil }) {
            current.recentToolCalls[index].finishedAt = date
            current.recentToolCalls[index].failed = true
        }
        current.activity = .ready
        current.pendingPermission = nil
        current.since = date
        current.turnStartedAt = nil
        current.turnStartUnheard = false
        current.lastTurnEndedAt = date
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

    /// Takes the status Claude Code records for a session its hooks have not reported. Keeps
    /// following that record while the hooks stay silent; never overrides what they said.
    /// Returns whether the status changed.
    @discardableResult
    public mutating func adopt(_ record: ClaudeSessionRecord, now: Date = Date()) -> Bool {
        guard let activity = record.activity else { return false }
        let at = record.statusUpdatedAt ?? now
        if var current = status, current.sessionID == record.sessionID {
            guard current.fromSessionRecord, current.activity != activity else { return false }
            current.activity = activity
            current.since = at
            current.lastEventAt = at
            status = current
            return true
        }
        var fresh = AgentStatus(agent: .claudeCode, activity: activity, since: at, lastEventAt: at, sessionID: record.sessionID)
        fresh.fromSessionRecord = true
        status = fresh
        return true
    }

    /// Takes a Hermes turn under way, from its lease, for a session its hooks have not reported:
    /// working since the turn began. A new turn's lease replaces the last; the session's first
    /// hook event takes over, and the turn keeps its start. Never overrides what the hooks said,
    /// unless they said the session ended before this turn began. Returns whether the status changed.
    @discardableResult
    public mutating func adopt(_ turn: HermesTurn) -> Bool {
        if let current = status, current.sessionID == turn.sessionID {
            if current.fromSessionRecord {
                guard current.turnStartedAt != turn.startedAt else { return false }
            } else {
                guard current.activity == .idle, turn.startedAt > current.lastEventAt else { return false }
            }
        }
        var fresh = AgentStatus(agent: .hermes, activity: .working(tool: nil, detail: nil), since: turn.startedAt,
                                lastEventAt: turn.startedAt, sessionID: turn.sessionID, turnStartedAt: turn.startedAt)
        fresh.lastTurnStartedAt = turn.startedAt
        fresh.fromSessionRecord = true
        fresh.turnStartUnheard = true
        status = fresh
        return true
    }

    /// Moves the start of a turn whose beginning Mimamori did not hear (it started mid-turn, so
    /// the turn starts at the first step it heard) back to `date`, when the agent's own record
    /// says the turn began: Hermes's lease, or Claude Code's session file while it says busy.
    /// Only ever earlier, and never before the session's previous turn ended: a record from
    /// before then is about an earlier turn. Returns whether the start moved.
    @discardableResult
    public mutating func backdateTurn(to date: Date) -> Bool {
        guard var current = status, current.turnStartUnheard, let start = current.turnStartedAt, date < start,
              current.lastTurnEndedAt.map({ date >= $0 }) ?? true else { return false }
        current.turnStartedAt = date
        current.lastTurnStartedAt = date
        status = current
        return true
    }

    /// Forget a status whose agent has been silent and has no process alive.
    public mutating func expire(olderThan interval: TimeInterval, now: Date = Date()) {
        if let status, now.timeIntervalSince(status.lastEventAt) > interval {
            self.status = nil
        }
    }
}
