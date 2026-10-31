import Foundation

/// Who is working in one worktree, and whether two of them are editing the same files.
///
/// Two agents in one folder trip over each other: one edits a file, the other reads it back
/// changed or undoes the edit. A session counts while it is live; an agent process no session
/// accounts for counts too, once it has stayed a while and no other agent started it.
public struct WorktreeAgents: Sendable, Hashable {
    /// A session silent this long, with no process of its own, no longer counts.
    public static let liveWindow: TimeInterval = 10 * 60
    /// Edits this old no longer count towards a collision…
    public static let editWindow: TimeInterval = 30 * 60
    /// …and one of the two edits must be at least this recent.
    public static let recentEditWindow: TimeInterval = 10 * 60

    /// Two or more sessions edited one file.
    public struct Collision: Sendable, Hashable {
        /// Absolute path of the file.
        public var path: String
        /// The sessions that edited it (their `AgentStatus.key`), first editor first.
        public var sessions: [String]
        public var agents: [AgentKind]
        public var lastEditAt: Date
    }

    /// Live sessions, the most pressing first.
    public var live: [AgentStatus]
    /// The agent processes each live session accounts for, by session key.
    public var claims: [String: [Int32]]
    /// Agent processes no live session accounts for, which count as agents of their own.
    public var unclaimed: [AgentProcess]
    /// Files more than one session edited recently, most recent first.
    public var collisions: [Collision]

    public var agentCount: Int { live.count + unclaimed.count }
    public var isShared: Bool { agentCount > 1 }

    /// - Parameters:
    ///   - statuses: every session Vigil places in the worktree, ended ones included.
    ///   - processes: the agent processes found in it.
    ///   - established: processes seen by an earlier scan; a newer one may be a passing helper.
    ///   - parent: the process that started a process, for telling an agent's helpers apart.
    public init(statuses: [AgentStatus], processes: [AgentProcess], established: Set<Int32>, now: Date = Date(),
                parent: (Int32) -> Int32? = ProcessInspector.parentPID(of:)) {
        var available = processes.sorted { $0.startedAt < $1.startedAt }
        var claims: [String: [Int32]] = [:]
        var live: [AgentStatus] = []

        // Claude Code's records say exactly which process runs which session.
        for status in statuses where status.agent == .claudeCode {
            let mine = available.filter { $0.claudeSession?.sessionID == status.sessionID && status.sessionID != nil }
            if !mine.isEmpty {
                claims[status.key] = mine.map(\.pid)
                available.removeAll { process in mine.contains { $0.pid == process.pid } }
            }
        }
        for status in statuses.sorted(by: Self.morePressing) {
            // Any other session takes one process of its kind, the longest running.
            let candidate = claims[status.key] == nil
                ? available.firstIndex { $0.kind.id == status.agent.id && $0.claudeSession == nil } : nil
            let hasProcess = claims[status.key] != nil || candidate != nil
            let isLive: Bool
            if status.activity == .idle {
                isLive = false
            } else if status.fromSessionFile {
                isLive = hasProcess
            } else {
                isLive = hasProcess || now.timeIntervalSince(status.lastEventAt) < Self.liveWindow
            }
            guard isLive else { continue }
            live.append(status)
            if let candidate {
                claims[status.key] = [available[candidate].pid]
                available.remove(at: candidate)
            }
        }

        // A process another agent here started is that agent's helper (or a `claude -p` it runs).
        let pids = Set(processes.map(\.pid))
        let unclaimed = available.filter { process in
            guard established.contains(process.pid) else { return false }
            let ancestor = parent(process.pid).flatMap { start in
                ProcessInspector.nearest(from: start, parent: parent) { pids.contains($0) ? $0 : nil }
            }
            return ancestor == nil
        }

        self.live = live
        self.claims = claims.filter { key, _ in live.contains { $0.key == key } }
        self.unclaimed = unclaimed
        self.collisions = Self.collisions(among: live, now: now)
    }

    /// The tool call responsible for a change to `path` (absolute) around `date`, among a
    /// worktree's sessions. A call naming the file wins; when two sessions could have made the
    /// change, it is credited to both ("Claude Code or Codex") rather than guessed.
    public static func attribution(among sessions: [AgentStatus], path: String, at date: Date) -> ChangeAttribution? {
        guard !sessions.isEmpty else { return nil }
        let windows = sessions.map { status in
            (status, status.recentToolCalls.filter { call in
                call.startedAt <= date.addingTimeInterval(1) && (call.finishedAt ?? .distantFuture) >= date.addingTimeInterval(-5)
            })
        }
        func credit(_ status: AgentStatus, _ call: AgentToolCall) -> ChangeAttribution {
            ChangeAttribution(agent: status.agent.displayName, tool: call.toolName, detail: call.summary, at: call.startedAt)
        }
        func shared(_ statuses: [AgentStatus]) -> ChangeAttribution {
            ChangeAttribution(agent: describe(statuses.map(\.agent)).replacingOccurrences(of: " and ", with: " or "),
                              tool: "working", detail: nil, at: date)
        }
        let naming = windows.compactMap { status, calls in calls.last { $0.filePath == path }.map { (status, $0) } }
        if let latest = naming.max(by: { $0.1.startedAt < $1.1.startedAt }) { return credit(latest.0, latest.1) }
        // Then a call that changes files, then any call, then simply being at work.
        for pick in [{ (calls: [AgentToolCall]) in calls.last { $0.isMutating } }, { (calls: [AgentToolCall]) in calls.last }] {
            let found = windows.compactMap { status, calls in pick(calls).map { (status, $0) } }
            if found.count == 1 { return credit(found[0].0, found[0].1) }
            if found.count > 1 { return shared(found.map(\.0)) }
        }
        let working = sessions.filter { if case .working = $0.activity { true } else { false } }
        if working.count == 1 { return ChangeAttribution(agent: working[0].agent.displayName, tool: "working", detail: nil, at: date) }
        return working.count > 1 ? shared(working) : nil
    }

    /// "Claude Code and Codex", "Claude Code, Codex and Gemini CLI", "Two Claude Code sessions".
    public static func describe(_ agents: [AgentKind]) -> String {
        guard let first = agents.first else { return "Agents" }
        if agents.allSatisfy({ $0.id == first.id }), agents.count > 1 {
            let count = agents.count == 2 ? "Two" : agents.count == 3 ? "Three" : "\(agents.count)"
            return "\(count) \(first.displayName) sessions"
        }
        var names: [String] = []
        for agent in agents where !names.contains(agent.displayName) { names.append(agent.displayName) }
        guard names.count > 1 else { return names[0] }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// Waiting on you first, then working, then ready; the latest to report first among equals.
    public static func morePressing(_ a: AgentStatus, _ b: AgentStatus) -> Bool {
        if a.activity.urgency != b.activity.urgency { return a.activity.urgency < b.activity.urgency }
        return a.lastEventAt > b.lastEventAt
    }

    static func collisions(among sessions: [AgentStatus], now: Date) -> [Collision] {
        guard sessions.count > 1 else { return [] }
        // path → session key → its last edit of the file
        var edits: [String: [String: Date]] = [:]
        var agents: [String: AgentKind] = [:]
        for session in sessions {
            agents[session.key] = session.agent
            for call in session.recentToolCalls where call.isMutating && now.timeIntervalSince(call.startedAt) < editWindow {
                guard let path = call.filePath, path.hasPrefix("/") else { continue }
                edits[path, default: [:]][session.key] = max(edits[path]?[session.key] ?? .distantPast, call.startedAt)
            }
        }
        return edits.compactMap { path, bySession -> Collision? in
            guard bySession.count > 1, let last = bySession.values.max(),
                  now.timeIntervalSince(last) < recentEditWindow else { return nil }
            let ordered = bySession.sorted { $0.value < $1.value }.map(\.key)
            return Collision(path: path, sessions: ordered, agents: ordered.compactMap { agents[$0] }, lastEditAt: last)
        }
        .sorted { $0.lastEditAt > $1.lastEditAt }
    }
}
