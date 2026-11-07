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

    /// In a turn: working, or stopped in one to wait on you.
    public var isMidTurn: Bool {
        switch self {
        case .working, .needsPermission, .askedQuestion: true
        case .ready, .idle: false
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
        case .working(let tool, let detail): tool.map { "working · \($0)" } ?? detail.map { "working · \($0)" } ?? "working"
        case .needsPermission(let tool, _): tool.isEmpty ? "needs permission" : "needs permission for \(tool)"
        case .askedQuestion: "has a question for you"
        case .ready: "ready for your next prompt"
        case .idle: "idle"
        }
    }
}

// AgentToolCall and AgentToolCategory are in MimamoriShared, for the iPhone companion's cards.
extension AgentToolCall {
    public var isMutating: Bool { HookEvent.mutatingTools.contains(toolName) }
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
    /// The session's title, such as the desktop app shows it; nil when it has none, or for an
    /// agent that keeps none.
    public var title: String?
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
    /// Subagents the session started, running or lately finished.
    public var subagents: [Subagent] = []
    /// Agent calls in the foreground whose subagent hasn't been heard from yet.
    public var pendingLaunches: [SubagentLaunchRecord] = []
    /// Commands it runs in the background, running or lately finished.
    public var commands: [BackgroundCommand] = []
    /// How many of them run now.
    public var backgroundCommands: Int { commands.filter(\.isRunning).count }
    /// The agent stopped while subagents ran: its turn ends when the last of them does.
    public var waitingOnSubagents = false
    /// How the agent's own stop went, kept for when the turn finally ends.
    public var deferredStopFailure: String?? = nil

    public var runningSubagents: [Subagent] { subagents.filter(\.isRunning) }

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

    /// Subagents finished half an hour ago are forgotten, and no more than 30 are kept: steps keep
    /// their `agentID` either way.
    mutating func forgetOldSubagents(now: Date) {
        subagents.removeAll { $0.finishedAt.map { now.timeIntervalSince($0) > 30 * 60 } ?? false }
        if subagents.count > 30 { subagents.removeFirst(subagents.count - 30) }
        commands.removeAll { $0.finishedAt.map { now.timeIntervalSince($0) > 30 * 60 } ?? false }
        if commands.count > 30 { commands.removeFirst(commands.count - 30) }
    }

    /// Ends the turn: Ready, nothing left running, and the note saying so. `failure` is a
    /// StopFailure's reason (nil for a turn that ended well, `.some(nil)` for a failure with none).
    mutating func endTurn(at now: Date, failure: String?? = nil) -> AgentNote {
        if activity != .ready {
            activity = .ready
            since = now
        }
        pendingPermission = nil
        for index in recentToolCalls.indices where recentToolCalls[index].finishedAt == nil {
            recentToolCalls[index].finishedAt = now
        }
        waitingOnSubagents = false
        deferredStopFailure = nil
        var detail: String? = nil
        if let started = turnStartedAt {
            let seconds = Int(now.timeIntervalSince(started))
            let calls = toolCallsThisTurn == 1 ? "1 tool call" : "\(toolCallsThisTurn) tool calls"
            detail = "\(calls) in \(seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s")"
        }
        turnStartedAt = nil
        turnStartUnheard = false
        lastTurnEndedAt = now
        let agentName = agent.displayName
        if let failure {
            let reason = failure.map { $0.replacingOccurrences(of: "_", with: " ") }
            return AgentNote(kind: .turnFinished, title: "\(agentName)'s turn ended on an error",
                             detail: [reason, detail].compactMap { $0 }.joined(separator: " · "))
        }
        return AgentNote(kind: .turnFinished, title: "\(agentName) finished a turn", detail: detail)
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
    /// Open calls Hermes's `execute_code` ran, which no end event will close.
    private var codeCalls: Set<String> = []

    public init() {}

    public mutating func apply(_ event: HookEvent) -> [AgentNote] {
        let now = event.receivedAt
        var current = status ?? AgentStatus(agent: event.agent, activity: .idle, since: now, lastEventAt: now)
        var codeCalls = self.codeCalls
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
            current.subagents = []
            current.pendingLaunches = []
            current.commands = []
            current.waitingOnSubagents = false
            current.deferredStopFailure = nil
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
            codeCalls.removeAll()
        }

        /// The tools `execute_code` ran have ended: it runs one at a time, and they end with it.
        func finishCodeCalls() {
            guard !codeCalls.isEmpty else { return }
            for index in current.recentToolCalls.indices
            where codeCalls.contains(current.recentToolCalls[index].id) && current.recentToolCalls[index].finishedAt == nil {
                current.recentToolCalls[index].finishedAt = now
            }
            codeCalls.removeAll()
        }

        func subagentIndex(_ id: String) -> Int {
            if let index = current.subagents.firstIndex(where: { $0.id == id }) { return index }
            current.subagents.append(Subagent(id: id, startedAt: now))
            return current.subagents.count - 1
        }

        /// While the agent waits on its subagents, the status says how many are left, and the
        /// turn ends with the last of them.
        func settleWaiting() {
            guard current.waitingOnSubagents else { return }
            let running = current.runningSubagents.count
            if running == 0 {
                notes.append(current.endTurn(at: now, failure: current.deferredStopFailure))
            } else {
                set(.working(tool: nil, detail: Subagent.waitingDetail(running)))
            }
        }

        // A subagent's event says it's alive; its first may say which Agent call started it.
        if let id = event.agentID {
            let known = current.subagents.contains { $0.id == id }
            let index = subagentIndex(id)
            if current.subagents[index].type == nil { current.subagents[index].type = event.agentType }
            if let own = event.subagentWorktree { current.subagents[index].worktreePath = own }
            current.subagents[index].lastEventAt = now
            if !known, let launch = current.pendingLaunches.firstIndex(where: { $0.type == nil || $0.type == event.agentType }) {
                if current.subagents[index].description == nil {
                    current.subagents[index].description = current.pendingLaunches[launch].description
                }
                current.pendingLaunches.remove(at: launch)
            }
        }
        // What's still in flight: the running subagents, with what each was asked, and commands run
        // in the background. A background subagent no longer listed has finished.
        if let tasks = event.backgroundTasks {
            let listed = tasks.filter { $0.isSubagent && $0.isRunning }
            for task in listed {
                let index = subagentIndex(task.id)
                current.subagents[index].background = true
                if current.subagents[index].type == nil { current.subagents[index].type = task.agentType }
                if current.subagents[index].description == nil { current.subagents[index].description = task.description }
            }
            let ids = Set(listed.map(\.id))
            for index in current.subagents.indices {
                let subagent = current.subagents[index]
                if subagent.background, subagent.isRunning, !ids.contains(subagent.id) { current.subagents[index].finishedAt = now }
            }
            let shells = tasks.filter { $0.type == "shell" && $0.isRunning }
            for task in shells {
                if let index = current.commands.firstIndex(where: { $0.id == task.id }) {
                    if current.commands[index].description == nil { current.commands[index].description = task.description }
                } else {
                    current.commands.append(BackgroundCommand(id: task.id, description: task.description, startedAt: now))
                }
            }
            let running = Set(shells.map(\.id))
            for index in current.commands.indices where current.commands[index].isRunning && !running.contains(current.commands[index].id) {
                current.commands[index].finishedAt = now
            }
        }
        // Claude Code telling the agent a background task ended: that task is done, whatever it was.
        if let notification = event.taskNotification {
            if let index = current.commands.firstIndex(where: { $0.id == notification.taskID }) {
                if current.commands[index].finishedAt == nil { current.commands[index].finishedAt = now }
                current.commands[index].status = notification.status
                current.commands[index].exitCode = notification.exitCode
            }
            if let index = current.subagents.firstIndex(where: { $0.id == notification.taskID }), current.subagents[index].isRunning {
                current.subagents[index].finishedAt = now
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
            for index in current.subagents.indices where current.subagents[index].isRunning {
                current.subagents[index].finishedAt = now
            }
            for index in current.commands.indices where current.commands[index].isRunning {
                current.commands[index].finishedAt = now
            }
            current.waitingOnSubagents = false
            current.deferredStopFailure = nil
            current.lastTurnEndedAt = now
            notes.append(AgentNote(kind: .sessionEnded, title: "\(agentName) session ended", detail: event.message))

        case .userPromptSubmit:
            // Hermes fires its equivalent before every model call, and again when you answer its
            // question; only a fresh turn resets the counters.
            let midTurn: Bool
            switch current.activity {
            case .working, .askedQuestion, .needsPermission: midTurn = current.turnStartedAt != nil && !current.waitingOnSubagents
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
                current.waitingOnSubagents = false
                current.deferredStopFailure = nil
                notes.append(AgentNote(kind: .turnStarted, title: "\(agentName) started a turn", detail: event.message))
            }

        case .preToolUse:
            let tool = event.toolName ?? "tool"
            // A subagent's step after the agent's turn ended is the subagent's: no turn starts, and
            // the agent's own status stays as it is.
            let subagentAfterTurn = event.agentID != nil && current.turnStartedAt == nil
            // A call with no turn under way: Mimamori started (or restarted) mid-turn and never saw
            // the prompt. The turn starts here, so its steps, files and timeline still show.
            if current.turnStartedAt == nil, !subagentAfterTurn {
                current.turnStartedAt = now
                current.lastTurnStartedAt = now
                current.turnStartUnheard = true
                current.toolCallsThisTurn = 0
            }
            if !subagentAfterTurn { current.toolCallsThisTurn += 1 }
            if event.ranFromCode { finishCodeCalls() }
            let call = AgentToolCall(id: event.toolUseID ?? UUID().uuidString, toolName: tool, summary: event.summary,
                                     filePath: event.filePath, startedAt: now, agentID: event.agentID)
            current.recentToolCalls.append(call)
            if event.ranFromCode { codeCalls.insert(call.id) }
            if current.recentToolCalls.count > maxToolCalls { current.recentToolCalls.removeFirst(current.recentToolCalls.count - maxToolCalls) }
            if let id = event.agentID {
                let index = subagentIndex(id)
                current.subagents[index].steps += 1
                current.subagents[index].lastStep = call
            }
            // An Agent call in the foreground: its subagent's first step will say which it is.
            if event.agentID == nil, let launch = event.subagentLaunch, !launch.background {
                current.pendingLaunches.append(SubagentLaunchRecord(toolUseID: event.toolUseID, type: launch.subagentType,
                                                                    description: launch.description))
            }
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
                if !waitingElsewhere, !subagentAfterTurn, !current.waitingOnSubagents { set(.working(tool: tool, detail: event.summary)) }
                notes.append(AgentNote(kind: .toolCall, title: "\(agentName): \(tool)", detail: event.summary,
                                       filePath: event.filePath, isMutatingTool: event.isMutatingTool))
            }

        case .postToolUse, .postToolUseFailure, .permissionDenied:
            let finished = finish(id: event.toolUseID, tool: event.toolName, failed: event.name != .postToolUse)
            if event.toolName == "execute_code" { finishCodeCalls() }
            // An Agent call ending says which subagent it started: at once for one sent to the
            // background (`async_launched`), when it finished for one in the foreground.
            if let launch = event.subagentLaunch, let id = launch.agentID {
                let index = subagentIndex(id)
                if current.subagents[index].type == nil { current.subagents[index].type = launch.subagentType }
                if current.subagents[index].description == nil { current.subagents[index].description = launch.description }
                if launch.status == "async_launched" { current.subagents[index].background = true }
                current.pendingLaunches.removeAll { $0.toolUseID != nil && $0.toolUseID == event.toolUseID }
            }
            if let launch = event.commandLaunch, let id = launch.taskID, event.name == .postToolUse,
               !current.commands.contains(where: { $0.id == id }) {
                let started = current.recentToolCalls.last { $0.id == finished }?.startedAt ?? now
                current.commands.append(BackgroundCommand(id: id, description: launch.description, command: launch.command,
                                                          startedAt: started))
            }
            if settlesPermission(endedCall: finished) {
                if current.waitingOnSubagents {
                    settleWaiting()
                } else if event.agentID == nil || current.turnStartedAt != nil {
                    set(.working(tool: nil, detail: nil))
                }
            }

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
            // Claude Code's request carries no tool_use_id: it belongs to the call PreToolUse just
            // announced. Hermes's names the call but not its tool.
            let named = event.toolUseID.flatMap { id in current.recentToolCalls.last { $0.id == id && $0.finishedAt == nil } }
            let tool = event.toolName ?? named?.toolName ?? "a tool"
            let call = named ?? current.recentToolCalls.last { call in
                call.finishedAt == nil && call.toolName == tool && (event.summary == nil || call.summary == event.summary)
            }
            if event.isQuestionTool {
                // Claude Code asks permission for its question tool too. What waits on you is the
                // question, which its PreToolUse announced, and which Mimamori can answer.
                set(.askedQuestion(detail: event.summary))
                current.pendingPermission = PendingPermission(callID: event.toolUseID ?? call?.id, agentID: event.agentID)
                break
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
                // The same reminder for a question: it still asks you something, not for permission.
                if case .askedQuestion = current.activity, HookEvent.questionTools.contains(tool) { break }
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
            let failure: String?? = event.name == .stopFailure ? .some(event.message) : nil
            if event.agentID == nil, !current.runningSubagents.isEmpty {
                // The agent is done but its subagents aren't: the turn goes on until they finish.
                for index in current.recentToolCalls.indices
                where current.recentToolCalls[index].finishedAt == nil && current.recentToolCalls[index].agentID == nil {
                    current.recentToolCalls[index].finishedAt = now
                }
                current.waitingOnSubagents = true
                current.deferredStopFailure = failure
                settleWaiting()
            } else {
                notes.append(current.endTurn(at: now, failure: failure))
            }

        case .subagentStop:
            var title = "\(agentName) subagent finished", detail: String? = nil
            if let id = event.agentID {
                let index = subagentIndex(id)
                if current.subagents[index].finishedAt == nil { current.subagents[index].finishedAt = now }
                current.subagents[index].lastMessage = event.lastMessage
                for call in current.recentToolCalls.indices
                where current.recentToolCalls[call].agentID == id && current.recentToolCalls[call].finishedAt == nil {
                    current.recentToolCalls[call].finishedAt = now
                }
                title = "\(agentName)'s \(current.subagents[index].title) subagent finished"
                detail = current.subagents[index].description
            }
            notes.append(AgentNote(kind: .notification, title: title, detail: detail))
            settleWaiting()

        case .preCompact, .other:
            break
        }

        current.forgetOldSubagents(now: now)
        self.codeCalls = codeCalls
        status = current
        return notes
    }

    /// Takes a subagent silent for `Subagent.quietLimit` to have finished, its stop unheard, and
    /// ends a turn waiting only on such subagents. Returns the note for a turn it ended; called
    /// now and then, since no event comes to say so.
    public mutating func expireSubagents(now: Date = Date()) -> [AgentNote] {
        guard var current = status else { return [] }
        var notes: [AgentNote] = []
        for index in current.subagents.indices
        where current.subagents[index].isRunning && now.timeIntervalSince(current.subagents[index].lastEventAt) > Subagent.quietLimit {
            current.subagents[index].finishedAt = now
        }
        if current.waitingOnSubagents {
            let running = current.runningSubagents.count
            if running == 0 {
                notes.append(current.endTurn(at: now, failure: current.deferredStopFailure))
            } else if case .working = current.activity {
                current.activity = .working(tool: nil, detail: Subagent.waitingDetail(running))
            }
        }
        current.forgetOldSubagents(now: now)
        if current != status { status = current }
        return notes
    }

    /// You approved the shell command that was waiting: it is running. Claude Code sends no
    /// hook between the approval and the command finishing, so this comes from seeing the
    /// command's process. Returns false when nothing was waiting.
    /// Sets the session's title (see `ClaudeSessionTitle`). Returns whether it changed.
    @discardableResult
    public mutating func setTitle(_ title: String?) -> Bool {
        guard var current = status, current.title != title else { return false }
        current.title = title
        status = current
        return true
    }

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
