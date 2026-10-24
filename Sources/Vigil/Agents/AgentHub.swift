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

    private var machines: [String: AgentStatusMachine] = [:]
    /// Which worktree each agent session works in, for events that carry no usable directory.
    private var placement = SessionPlacement()
    private var server: HookSocketServer?
    private let scanner = AgentScanner()
    private var scanTask: Task<Void, Never>?
    private var watchedWorktrees: [String] = []
    private var settings = AppSettings()

    // MARK: Lifecycle

    func start(settings: AppSettings) {
        self.settings = settings
        startServer()
        restartScanning()
    }

    func stop() {
        server?.stop()
        server = nil
        isListening = false
        scanTask?.cancel()
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
        isListening = server?.isListening ?? false
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
            return
        }
        // The session moved on: do not leave its old status behind.
        if let old = decision.movedFrom, let session = event.sessionID, statuses[old]?.sessionID == session {
            statuses.removeValue(forKey: old)
            machines.removeValue(forKey: old)
        }
        var event = event
        if let file = event.filePath, !file.hasPrefix("/") {
            event.filePath = (worktree as NSString).appendingPathComponent(file)
        }
        var machine = machines[worktree] ?? AgentStatusMachine()
        let notes = machine.apply(event)
        machines[worktree] = machine
        if let status = machine.status { statuses[worktree] = status }
        if !notes.isEmpty { onNotes(worktree, event.agent, notes) }
    }

    private func apply(processes found: [String: [AgentProcess]]) {
        let previous = processes
        processes = found
        // Announce arrivals and departures only where hooks are not already reporting.
        for (worktree, list) in found where statuses[worktree] == nil {
            let before = Set(previous[worktree]?.map(\.pid) ?? [])
            for process in list where !before.contains(process.pid) {
                onNotes(worktree, process.kind, [AgentNote(kind: .sessionStarted, title: "\(process.kind.displayName) is running here")])
            }
        }
        for (worktree, list) in previous where statuses[worktree] == nil {
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
                                 lastToolCall: status.recentToolCalls.last, toolCallsThisTurn: status.toolCallsThisTurn)
        }
        guard let first = running.first else { return nil }
        let earliest = running.map(\.startedAt).min() ?? first.startedAt
        return AgentPresence(kind: first.kind, source: .process, activity: .idle, since: earliest,
                             processCount: running.count, isBusy: running.contains(where: \.isBusy),
                             lastToolCall: nil, toolCallsThisTurn: 0)
    }

    var worktreesNeedingAttention: [String] {
        statuses.filter { $0.value.activity.needsAttention }.keys.sorted()
    }

    var activeWorktreeCount: Int {
        Set(processes.filter { !$0.value.isEmpty }.keys).union(statuses.filter { $0.value.activity != .idle }.keys).count
    }

    /// The tool call responsible for a change to `path` in `worktree` around `date`, if hooks know.
    func attribution(for worktree: String, path: String, at date: Date) -> ChangeAttribution? {
        guard let status = statuses[worktree] else { return nil }
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
