import Foundation

/// What an agent is doing in a worktree, as far as its hooks have told us.
public enum AgentActivity: Sendable, Hashable, Codable {
    case working(tool: String?, detail: String?)
    case needsPermission(tool: String, detail: String?)
    case waitingForInput
    case idle

    public var needsAttention: Bool {
        switch self {
        case .needsPermission, .waitingForInput: true
        case .working, .idle: false
        }
    }

    public var title: String {
        switch self {
        case .working(let tool, _): tool.map { "working · \($0)" } ?? "working"
        case .needsPermission(let tool, _): "needs permission for \(tool)"
        case .waitingForInput: "waiting for your input"
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

    public init(id: String, toolName: String, summary: String?, filePath: String?, startedAt: Date, finishedAt: Date? = nil) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.filePath = filePath
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var isMutating: Bool { HookEvent.mutatingTools.contains(toolName) }
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
            if current.activity != activity {
                current.activity = activity
                current.since = now
            }
        }

        switch event.name {
        case .sessionStart:
            set(.waitingForInput)
            current.turnStartedAt = nil
            current.toolCallsThisTurn = 0
            notes.append(AgentNote(kind: .sessionStarted, title: "\(agentName) session started", detail: event.message))

        case .sessionEnd:
            set(.idle)
            notes.append(AgentNote(kind: .sessionEnded, title: "\(agentName) session ended", detail: event.message))

        case .userPromptSubmit:
            // Hermes fires its equivalent before every model call; only a fresh turn resets the counters.
            if case .working = current.activity, current.turnStartedAt != nil {
                set(.working(tool: nil, detail: nil))
            } else {
                set(.working(tool: nil, detail: nil))
                current.turnStartedAt = now
                current.toolCallsThisTurn = 0
                notes.append(AgentNote(kind: .turnStarted, title: "\(agentName) started a turn", detail: event.message))
            }

        case .preToolUse:
            let tool = event.toolName ?? "tool"
            set(.working(tool: tool, detail: event.summary))
            current.toolCallsThisTurn += 1
            let call = AgentToolCall(id: event.toolUseID ?? UUID().uuidString, toolName: tool, summary: event.summary,
                                     filePath: event.filePath, startedAt: now)
            current.recentToolCalls.append(call)
            if current.recentToolCalls.count > maxToolCalls { current.recentToolCalls.removeFirst(current.recentToolCalls.count - maxToolCalls) }
            notes.append(AgentNote(kind: .toolCall, title: "\(agentName): \(tool)", detail: event.summary,
                                   filePath: event.filePath, isMutatingTool: event.isMutatingTool))

        case .postToolUse:
            if let id = event.toolUseID, let index = current.recentToolCalls.lastIndex(where: { $0.id == id }) {
                current.recentToolCalls[index].finishedAt = now
            } else if let index = current.recentToolCalls.lastIndex(where: { $0.finishedAt == nil && $0.toolName == event.toolName }) {
                current.recentToolCalls[index].finishedAt = now
            }
            set(.working(tool: nil, detail: nil))

        case .permissionRequest:
            let tool = event.toolName ?? "a tool"
            set(.needsPermission(tool: tool, detail: event.summary))
            notes.append(AgentNote(kind: .needsPermission, title: "\(agentName) needs permission: \(tool)", detail: event.summary,
                                   filePath: event.filePath))

        case .notification:
            let text = (event.message ?? "").lowercased()
            if text.contains("permission") {
                let tool = event.toolName ?? "a tool"
                set(.needsPermission(tool: tool, detail: event.summary ?? event.message))
                notes.append(AgentNote(kind: .needsPermission, title: "\(agentName) needs permission", detail: event.message))
            } else if text.contains("waiting") || text.contains("idle") {
                set(.waitingForInput)
                notes.append(AgentNote(kind: .waiting, title: "\(agentName) is waiting for you", detail: event.message))
            } else {
                notes.append(AgentNote(kind: .notification, title: "\(agentName): \(event.message ?? "notification")"))
            }

        case .stop:
            set(.waitingForInput)
            var detail: String? = nil
            if let started = current.turnStartedAt {
                let seconds = Int(now.timeIntervalSince(started))
                detail = "\(current.toolCallsThisTurn) tool calls in \(seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s")"
            }
            notes.append(AgentNote(kind: .turnFinished, title: "\(agentName) finished a turn", detail: detail))
            current.turnStartedAt = nil

        case .subagentStop:
            notes.append(AgentNote(kind: .notification, title: "\(agentName) subagent finished"))

        case .preCompact, .other:
            break
        }

        status = current
        return notes
    }

    /// Forget a status whose agent has been silent and has no process alive.
    public mutating func expire(olderThan interval: TimeInterval, now: Date = Date()) {
        if let status, now.timeIntervalSince(status.lastEventAt) > interval {
            self.status = nil
        }
    }
}
