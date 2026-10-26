import Foundation
import Observation
import VigilCore

/// What the UI needs to know about agents in one worktree, from hooks and from processes.
struct AgentPresence: Hashable {
    enum Source: Hashable { case hooks, process }
    var kind: AgentKind
    var source: Source
    var activity: AgentActivity
    var since: Date
    var processCount: Int
    var isBusy: Bool
    var lastToolCall: AgentToolCall?
    var toolCallsThisTurn: Int
    /// The prompt behind the current turn, or the last one once it ended.
    var task: String? = nil
    /// That turn's tool calls, oldest first.
    var turnSteps: [AgentToolCall] = []
    var turnStartedAt: Date? = nil
    /// Agent processes running in the worktree, for finding the app they run in.
    var processIDs: [Int32] = []
    /// The step waiting on your permission, when it is known.
    var awaitingCallID: String? = nil

    var needsAttention: Bool { source == .hooks && activity.needsAttention }

    var statusText: String {
        switch (source, activity) {
        case (.hooks, .working(let tool, let detail)):
            if let tool { return detail.map { "working · \(tool) \($0)" } ?? "working · \(tool)" }
            return "working"
        case (.hooks, .needsPermission(let tool, let detail)):
            return detail.map { "needs permission · \(tool) \($0)" } ?? "needs permission · \(tool)"
        case (.hooks, .askedQuestion(let detail)):
            return detail.map { "asks: \($0)" } ?? "has a question for you"
        case (.hooks, .ready):
            return "ready for your next prompt"
        case (.hooks, .idle):
            return "session ended"
        case (.process, _):
            return isBusy ? "running" : "running, idle"
        }
    }
}

/// Collects agent signals for every watched worktree: hook events over the Unix socket,
/// and agent processes found by scanning.
@MainActor
@Observable
final class AgentHub {
    private(set) var statuses: [String: AgentStatus] = [:]
    private(set) var processes: [String: [AgentProcess]] = [:]
    private(set) var isListening = false
    private(set) var socketError: String?
    private(set) var eventsReceived = 0
    private(set) var eventsUnmatched = 0
    private(set) var lastEventAt: Date?

    let socketPath: String = Persistence.supportDirectory.appendingPathComponent("vigil.sock").path

    var resolveWorktree: @MainActor (String) -> String? = { _ in nil }
    var onNotes: @MainActor (_ worktree: String, _ agent: AgentKind, _ notes: [AgentNote]) -> Void = { _, _, _ in }

    // Bookkeeping that views never read, kept out of observation.
    @ObservationIgnored private var machines: [String: AgentStatusMachine] = [:]
    /// Which worktree each agent session works in, for events that carry no usable directory.
    @ObservationIgnored private var placement = SessionPlacement()
    @ObservationIgnored private var server: HookSocketServer?
    @ObservationIgnored private let scanner = AgentScanner()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var watchedWorktrees: [String] = []
    @ObservationIgnored private var settings = AppSettings()
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    /// Events from sessions not placed yet, replayed once a later event places them. A gateway
    /// agent's prompt arrives before any tool call says where it is working.
    @ObservationIgnored private var heldBySession: [String: [HookEvent]] = [:]
    @ObservationIgnored private var lastPublishedAt = Date.distantPast
    /// Runs only while a Claude Code shell command waits on your permission.
    @ObservationIgnored private var approvalWatch: Task<Void, Never>?

    /// A busy agent sends several hook events a second, and every change to `statuses` repaints
    /// each window that shows an agent. A change of state (to waiting on you, ready, ended)
    /// shows at once; a stream of "working · <tool>" updates is shown at most this often.
    private static let publishInterval: TimeInterval = 1.0

    // MARK: Lifecycle

    func start(settings: AppSettings) {
        self.settings = settings
        startServer()
        restartScanning()
        do {
            if let backup = try HookInstaller.updateIfOutdated(socketPath: socketPath) {
                NSLog("Vigil: added newer Claude Code hook events; previous settings saved to \(backup.path)")
            }
        } catch {
            NSLog("Vigil: could not update Claude Code hooks: \(error)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isListening = false
        scanTask?.cancel()
        approvalWatch?.cancel()
        approvalWatch = nil
    }

    func updateSettings(_ settings: AppSettings) {
        let previous = self.settings
        self.settings = settings
        if previous.customAgentNames != settings.customAgentNames {
            Task { await scanner.setClassifier(AgentClassifier(customNames: settings.customAgentNames)) }
        }
        if previous.agentScanEnabled != settings.agentScanEnabled || previous.agentScanIntervalSeconds != settings.agentScanIntervalSeconds {
            restartScanning()
        }
    }

    func setWatchedWorktrees(_ paths: [String]) {
        watchedWorktrees = paths
        for path in statuses.keys where !paths.contains(path) {
            statuses.removeValue(forKey: path)
            machines.removeValue(forKey: path)
        }
    }

    private func startServer() {
        let server = HookSocketServer(path: socketPath) { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
        do {
            try server.start()
            self.server = server
            socketError = nil
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.isListening = server.isListening
            }
        } catch {
            socketError = error.localizedDescription
            isListening = false
        }
    }

    private func restartScanning() {
        scanTask?.cancel()
        guard settings.agentScanEnabled else {
            processes = [:]
            return
        }
        let interval = max(1, settings.agentScanIntervalSeconds)
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let roots = self.watchedWorktrees
                let found = await self.scanner.scan(worktrees: roots)
                guard !Task.isCancelled else { return }
                self.apply(processes: found)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    // MARK: Events

    private func handle(_ event: HookEvent) {
        eventsReceived += 1
        lastEventAt = event.receivedAt
        let listening = server?.isListening ?? false
        if listening != isListening { isListening = listening }
        // Gateway and desktop agents run with a working directory of their own (Hermes's gateway
        // sits in ~/.hermes), so the paths a tool touches stand in; see SessionPlacement for how
        // a read weighs against an edit.
        var pathMatch: String? = nil
        if let file = event.filePath, file.hasPrefix("/") { pathMatch = resolveWorktree(file) }
        if pathMatch == nil {
            for hint in event.absolutePathHints {
                if let match = resolveWorktree(hint) { pathMatch = match; break }
            }
        }
        let decision = placement.place(session: event.sessionID, cwdMatch: event.cwd.flatMap(resolveWorktree),
                                       pathMatch: pathMatch, changesFiles: event.isMutatingTool)
        guard let worktree = decision.worktree else {
            eventsUnmatched += 1
            hold(event)
            return
        }
        // The session moved on: do not leave its old status behind.
        if let old = decision.movedFrom, let session = event.sessionID, machines[old]?.status?.sessionID == session {
            statuses.removeValue(forKey: old)
            machines.removeValue(forKey: old)
        }
        var machine = machines[worktree] ?? AgentStatusMachine()
        let before = machine.status?.activity
        var notes: [AgentNote] = []
        if let session = event.sessionID, let held = heldBySession.removeValue(forKey: session) {
            for earlier in held { notes += machine.apply(Self.anchored(earlier, in: worktree)) }
        }
        notes += machine.apply(Self.anchored(event, in: worktree))
        machines[worktree] = machine
        schedulePublish(urgent: !Self.sameState(before, machine.status?.activity))
        if !notes.isEmpty { onNotes(worktree, event.agent, notes) }
        watchForApprovals()
    }

    // MARK: Approvals

    private var commandsAwaitingPermission: [(worktree: String, command: String, since: Date)] {
        machines.compactMap { worktree, machine in
            machine.status?.commandAwaitingPermission.map { (worktree, $0.command, $0.since) }
        }
    }

    /// Claude Code sends nothing between your approval of a command and the command finishing,
    /// so a long build would keep asking for permission it already has. While a command waits,
    /// look for it running; once it is, show it working.
    private func watchForApprovals() {
        guard approvalWatch == nil, !commandsAwaitingPermission.isEmpty else { return }
        approvalWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let waitingSince = self?.commandsAwaitingPermission.map(\.since).min() else { break }
                // Quick at first, when an approval is likely; a dialog left open is checked less often.
                try? await Task.sleep(for: .milliseconds(Date().timeIntervalSince(waitingSince) < 120 ? 1500 : 5000))
                guard let self, !Task.isCancelled else { return }
                let waiting = self.commandsAwaitingPermission
                guard !waiting.isEmpty else { break }
                let commands = Dictionary(waiting.map { ($0.command, $0.since) }, uniquingKeysWith: min)
                let running = await Task.detached(priority: .utility) { ClaudeCommandProbe.running(commands) }.value
                for item in waiting where running.contains(item.command) {
                    self.noteApproved(in: item.worktree)
                }
            }
            self?.approvalWatch = nil
        }
    }

    private func noteApproved(in worktree: String) {
        guard var machine = machines[worktree], machine.noteApproved() else { return }
        machines[worktree] = machine
        schedulePublish(urgent: true)
    }

    private func hold(_ event: HookEvent) {
        guard let session = event.sessionID else { return }
        var held = heldBySession[session, default: []]
        held.append(event)
        if held.count > 20 { held.removeFirst(held.count - 20) }
        heldBySession[session] = held
        // Sessions that never get placed (an agent in an unwatched folder) must not pile up.
        if heldBySession.count > 50, let oldest = heldBySession.min(by: {
            ($0.value.last?.receivedAt ?? .distantPast) < ($1.value.last?.receivedAt ?? .distantPast)
        })?.key {
            heldBySession.removeValue(forKey: oldest)
        }
    }

    /// Relative tool paths are relative to the worktree the event was placed in.
    private static func anchored(_ event: HookEvent, in worktree: String) -> HookEvent {
        var event = event
        if let file = event.filePath, !file.hasPrefix("/") {
            event.filePath = (worktree as NSString).appendingPathComponent(file)
        }
        return event
    }

    /// Working on one tool or another is the same state; anything else is a change worth showing now.
    private static func sameState(_ a: AgentActivity?, _ b: AgentActivity?) -> Bool {
        switch (a, b) {
        case (.working?, .working?): true
        default: a == b
        }
    }

    private func schedulePublish(urgent: Bool) {
        let wait = Self.publishInterval - Date().timeIntervalSince(lastPublishedAt)
        if urgent || wait <= 0 {
            publishTask?.cancel()
            publishTask = nil
            publishStatuses()
            return
        }
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.publishTask = nil
            self.publishStatuses()
        }
    }

    private func publishStatuses() {
        lastPublishedAt = Date()
        let fresh = machines.compactMapValues(\.status)
        if fresh != statuses { statuses = fresh }
    }

    /// What views show of agent processes. CPU readings differ on every scan; only a change
    /// in which processes run, or whether they are busy, is worth a repaint.
    private static func visibleSummary(_ found: [String: [AgentProcess]]) -> [String: [String]] {
        found.filter { !$0.value.isEmpty }.mapValues { list in
            list.map { "\($0.pid)|\($0.kind.id)|\($0.isBusy)" }.sorted()
        }
    }

    private func apply(processes found: [String: [AgentProcess]]) {
        let previous = processes
        if Self.visibleSummary(found) != Self.visibleSummary(previous) { processes = found }
        // Announce arrivals and departures only where hooks are not already reporting.
        for (worktree, list) in found where machines[worktree]?.status == nil {
            let before = Set(previous[worktree]?.map(\.pid) ?? [])
            for process in list where !before.contains(process.pid) {
                onNotes(worktree, process.kind, [AgentNote(kind: .sessionStarted, title: "\(process.kind.displayName) is running here")])
            }
        }
        for (worktree, list) in previous where machines[worktree]?.status == nil {
            let now = Set(found[worktree]?.map(\.pid) ?? [])
            for process in list where !now.contains(process.pid) {
                onNotes(worktree, process.kind, [AgentNote(kind: .sessionEnded, title: "\(process.kind.displayName) exited")])
            }
        }
        // Hook statuses outlive their process briefly; drop them once the agent is gone for a while.
        let cutoff = Date().addingTimeInterval(-10 * 60)
        for (worktree, status) in statuses where status.lastEventAt < cutoff && (found[worktree] ?? []).isEmpty {
            statuses.removeValue(forKey: worktree)
            machines.removeValue(forKey: worktree)
        }
    }

    // MARK: Queries

    func presence(for worktree: String) -> AgentPresence? {
        let running = processes[worktree] ?? []
        if let status = statuses[worktree], status.activity != .idle || !running.isEmpty {
            return AgentPresence(kind: status.agent, source: .hooks, activity: status.activity, since: status.since,
                                 processCount: running.count, isBusy: running.contains(where: \.isBusy),
                                 lastToolCall: status.recentToolCalls.last, toolCallsThisTurn: status.toolCallsThisTurn,
                                 task: status.task, turnSteps: status.turnToolCalls,
                                 turnStartedAt: status.turnStartedAt ?? status.lastTurnStartedAt,
                                 processIDs: running.map(\.pid),
                                 awaitingCallID: status.pendingPermission?.callID)
        }
        guard let first = running.first else { return nil }
        let earliest = running.map(\.startedAt).min() ?? first.startedAt
        return AgentPresence(kind: first.kind, source: .process, activity: .idle, since: earliest,
                             processCount: running.count, isBusy: running.contains(where: \.isBusy),
                             lastToolCall: nil, toolCallsThisTurn: 0, processIDs: running.map(\.pid))
    }

    var worktreesNeedingAttention: [String] {
        statuses.filter { $0.value.activity.needsAttention }.keys.sorted()
    }

    var activeWorktreeCount: Int {
        Set(processes.filter { !$0.value.isEmpty }.keys).union(statuses.filter { $0.value.activity != .idle }.keys).count
    }

    /// The tool call responsible for a change to `path` in `worktree` around `date`, if hooks know.
    func attribution(for worktree: String, path: String, at date: Date) -> ChangeAttribution? {
        // Straight from the machine: published statuses may lag by a moment.
        guard let status = machines[worktree]?.status else { return nil }
        let absolute = (worktree as NSString).appendingPathComponent(path)
        let window = status.recentToolCalls.filter { call in
            call.startedAt <= date.addingTimeInterval(1) && (call.finishedAt ?? .distantFuture) >= date.addingTimeInterval(-5)
        }
        let call = window.last { $0.filePath == absolute } ?? window.last { $0.isMutating } ?? window.last
        if let call {
            return ChangeAttribution(agent: status.agent.displayName, tool: call.toolName, detail: call.summary, at: call.startedAt)
        }
        if case .working = status.activity {
            return ChangeAttribution(agent: status.agent.displayName, tool: "working", detail: nil, at: date)
        }
        return nil
    }
}
