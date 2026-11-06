import Foundation
import Observation
import MimamoriCore

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
    /// A permission request you can answer in Mimamori, with `AgentHub.answerPermission`.
    var permissionRequestID: String? = nil
    /// For a process-only presence: whether this agent's hooks are installed, or nil for an
    /// agent Mimamori has no hooks for.
    var hooksInstalled: Bool? = nil
    /// The other agents working in the same worktree, the most pressing first.
    var others: [AgentPresence] = []
    /// Files two of them edited, unless you dismissed it.
    var collision: AgentCollision? = nil
    /// The subagents it started, running or lately finished.
    var subagents: [Subagent] = []
    /// Commands it runs in the background, running or lately finished.
    var commands: [BackgroundCommand] = []
    var backgroundCommands: Int { commands.filter(\.isRunning).count }

    /// Its commands running, and those finished in the last minute, so their end shows.
    func shownCommands(at now: Date) -> [BackgroundCommand] {
        commands.filter { command in
            command.finishedAt.map { now.timeIntervalSince($0) < Subagent.listedAfterFinishing } ?? true
        }
    }

    /// Its subagents running, and those finished in the last minute, so their end shows.
    func shownSubagents(at now: Date) -> [Subagent] {
        subagents.filter { subagent in
            subagent.finishedAt.map { now.timeIntervalSince($0) < Subagent.listedAfterFinishing } ?? true
        }
    }

    var needsAttention: Bool { source == .hooks && activity.needsAttention || collision != nil }
    var agentCount: Int { 1 + others.count }

    var statusText: String {
        switch (source, activity) {
        case (.hooks, .working(let tool, let detail)):
            if let tool { return detail.map { "working · \(tool) \($0)" } ?? "working · \(tool)" }
            // "working · waiting on 2 subagents"
            return detail.map { "working · \($0)" } ?? "working"
        case (.hooks, .needsPermission(let tool, let detail)):
            if tool.isEmpty { return "needs permission" }
            return detail.map { "needs permission · \(tool) \($0)" } ?? "needs permission · \(tool)"
        case (.hooks, .askedQuestion(let detail)):
            return detail.map { "asks: \($0)" } ?? "has a question for you"
        case (.hooks, .ready):
            // The turn is yours, while what it started in the background goes on.
            if backgroundCommands > 0 { return "ready · " + BackgroundCommand.runningDetail(backgroundCommands) }
            return "ready for your next prompt"
        case (.hooks, .idle):
            return "session ended"
        case (.process, _):
            return isBusy ? "running" : "running, idle"
        }
    }
}

/// Two agents in one worktree edited the same files.
struct AgentCollision: Hashable {
    /// "Claude Code and Codex", "Two Claude Code sessions".
    var agents: String
    /// Absolute paths, the most recently edited first.
    var files: [String]
}

/// An agent that has reported to Mimamori, so you can see its hooks work.
struct AgentContact: Hashable, Identifiable {
    var agent: AgentKind
    var events: Int
    var lastEventAt: Date
    /// The event's name as the agent sent it.
    var lastEvent: String
    /// The watched worktree the last event was placed in; nil when it fit none (yet).
    var lastWorktree: String?

    var id: String { agent.id }
}

/// A permission request whose hook waits for an answer from Mimamori.
struct PermissionRequest: Hashable, Identifiable {
    var id: String
    /// The session asking (`AgentStatus.key`).
    var session: String
    var worktree: String
    var agent: AgentKind
    var tool: String
    var detail: String?
    /// A shell tool's whole command, where `detail` has its first line: what the iPhone shows.
    var command: String? = nil
    var since: Date
    /// The call that asked and the subagent it came from, as the session's status matched them:
    /// what tells which events settle the request.
    var call: PendingPermission
    /// When Mimamori answers by itself, and how; nil while it waits for you.
    var autoAnswer: AutoAnswer? = nil
    /// The Claude Code ask rule that keeps an auto-allow from applying to this call.
    var waitsForAskRule: String? = nil
    /// Its command was too long to check whole against the ask rules, so it's never allowed by itself.
    var waitsForLongCommand = false

    struct AutoAnswer: Hashable {
        var allow: Bool
        var at: Date
    }
}

/// Collects agent signals for every watched worktree: hook events over the Unix socket,
/// and agent processes found by scanning.
@MainActor
@Observable
final class AgentHub {
    /// Each worktree's sessions, the most pressing first.
    private(set) var statuses: [String: [AgentStatus]] = [:]
    /// Who works in each worktree and whether they collide, from `statuses` and `processes`.
    private(set) var agents: [String: WorktreeAgents] = [:]
    /// Shared files you dismissed, per worktree; forgotten once the worktree has one agent again.
    private(set) var dismissedCollisions: [String: Set<String>] = [:]
    private(set) var processes: [String: [AgentProcess]] = [:]
    private(set) var isListening = false
    private(set) var socketError: String?
    private(set) var eventsReceived = 0
    private(set) var eventsUnmatched = 0
    private(set) var lastEventAt: Date?
    /// Whether Claude Code's settings have Mimamori's hooks; re-read when the file changes.
    private(set) var claudeHooksInstalled = false
    /// Every agent heard from since launch, by agent id.
    private(set) var contacts: [String: AgentContact] = [:]
    /// The latest requests to the hook socket and what became of them, newest first.
    private(set) var hookLog: [HookLogEntry] = []
    /// Permission requests you can answer in Mimamori, by session (`AgentStatus.key`).
    private(set) var pendingPermissions: [String: PermissionRequest] = [:]
    static let hookLogCapacity = 200

    let socketPath: String = Persistence.supportDirectory.appendingPathComponent("mimamori.sock").path

    var resolveWorktree: @MainActor (String) -> String? = { _ in nil }
    var onNotes: @MainActor (_ worktree: String, _ agent: AgentKind, _ notes: [AgentNote]) -> Void = { _, _, _ in }
    /// Called when a published status changes, so the clock can count seconds again.
    var onStatusChange: @MainActor () -> Void = {}
    /// Called when who works where changes: statuses, processes, collisions.
    var onAgentsChange: @MainActor () -> Void = {}
    /// Called with the folders an event that fit no watched worktree came from: where the agent
    /// works, and the files and paths its tool named.
    var onUnwatchedWork: @MainActor (_ directories: [String], _ agent: AgentKind) -> Void = { _, _ in }
    /// A permission request waits for an answer from Mimamori, or no longer does (answered here,
    /// in the agent's own prompt, or let go).
    var onPermissionRequest: @MainActor (PermissionRequest) -> Void = { _ in }
    var onPermissionSettled: @MainActor (_ id: String) -> Void = { _ in }
    /// You, the countdown or a paired iPhone (named) answered a request in Mimamori, for the activity feed.
    var onPermissionAnswered: @MainActor (_ pending: PermissionRequest, _ allow: Bool, _ automatically: Bool,
                                          _ phone: String?) -> Void = { _, _, _, _ in }
    /// A request came, went or stopped its countdown, for the iPhone, which shows each one.
    var onPermissionsChange: @MainActor () -> Void = {}

    // Bookkeeping that views never read, kept out of observation.
    /// One machine per session (`AgentStatus.key`) in each worktree.
    @ObservationIgnored private var machines: [String: [String: AgentStatusMachine]] = [:]
    /// Processes the previous scan saw: a process counts as an agent of its own only once it stays.
    @ObservationIgnored private var establishedPIDs: Set<Int32> = []
    /// The agents and collisions already announced, per worktree, so each is announced once.
    @ObservationIgnored private var announcedAgents: [String: Set<String>] = [:]
    @ObservationIgnored private var announcedCollisions: [String: Set<String>] = [:]
    /// Which worktree each agent session works in, for events that carry no usable directory.
    @ObservationIgnored private var placement = SessionPlacement()
    @ObservationIgnored private var server: HookSocketServer?
    /// Where the hook socket writes every request's body as it came (debug builds' `hooks:raw`).
    @ObservationIgnored var rawHookLog: URL? {
        didSet { server?.rawLog = rawHookLog }
    }
    @ObservationIgnored private let scanner = AgentScanner()
    /// The last scan, before its processes are attributed to the worktrees their sessions work in.
    @ObservationIgnored private var lastScan = AgentScan()
    @ObservationIgnored private var claudeSettingsStamp: Date?
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
    /// Where Hermes says each of its sessions works, and when that was looked up.
    @ObservationIgnored private var hermesDirectories: [String: (directory: String?, at: Date)] = [:]
    /// The Hermes turns running at the last scan, by session, from Hermes's leases on them.
    @ObservationIgnored private var hermesTurns: [String: HermesTurn] = [:]
    /// The Hermes session of each turn's task, for the calls `execute_code` runs, which name no session.
    @ObservationIgnored private var hermesTaskSessions = HermesTaskSessions()
    /// Countdowns to answering a permission request by itself, by request id.
    @ObservationIgnored private var autoAnswerTasks: [String: Task<Void, Never>] = [:]
    /// Tests sent from Settings that have arrived, by token, until the test that sent them sees it.
    @ObservationIgnored private var arrivedTests: [String: Date] = [:]

    /// A busy agent sends several hook events a second, and every change to `statuses` repaints
    /// each window that shows an agent. A change of state (to waiting on you, ready, ended)
    /// shows at once; a stream of "working · <tool>" updates is shown at most this often.
    private static let publishInterval: TimeInterval = 1.0

    // MARK: Lifecycle

    func start(settings: AppSettings) {
        self.settings = settings
        startServer()
        do {
            if let backup = try HookInstaller.updateIfOutdated(socketPath: socketPath) {
                Log.hooks.notice("Added newer Claude Code hook events; previous settings saved to \(backup.path)")
            }
        } catch {
            Log.hooks.error("Could not update Claude Code's hooks: \(error.localizedDescription, privacy: .public)")
        }
        refreshHookState()
        restartScanning()
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
        server?.answersPermissions = settings.answerPermissionsInMimamori
        if !settings.answerPermissionsInMimamori {
            for key in Array(pendingPermissions.keys) { settlePermission(for: key) }
        } else if !settings.autoAnswerPermissions {
            for pending in pendingPermissions.values where pending.autoAnswer != nil { stopAutoAnswer(pending.id) }
        }
        if previous.customAgentNames != settings.customAgentNames {
            let classifier = AgentClassifier(customNames: settings.customAgentNames)
            server?.classifier = classifier
            Task { await scanner.setClassifier(classifier) }
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
        for path in agents.keys where !paths.contains(path) { agents.removeValue(forKey: path) }
    }

    private func startServer() {
        let server = HookSocketServer(path: socketPath) { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
        server.onNote = { [weak self] note in
            Task { @MainActor [weak self] in self?.handle(note) }
        }
        server.classifier = AgentClassifier(customNames: settings.customAgentNames)
        server.answersPermissions = settings.answerPermissionsInMimamori
        do {
            try server.start()
            self.server = server
        server.rawLog = rawHookLog
            if server.state == .deferring {
                socketError = Self.deferringMessage
                Log.hooks.notice("Another copy of Mimamori is listening for hook events at \(self.socketPath); this one takes over when it quits")
            } else {
                socketError = nil
                Log.hooks.notice("Listening for hook events at \(self.socketPath)")
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.isListening = server.isListening
            }
        } catch {
            socketError = error.localizedDescription
            isListening = false
            Log.hooks.error("Could not open the hook socket at \(self.socketPath): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func restartScanning() {
        scanTask?.cancel()
        guard settings.agentScanEnabled else {
            processes = [:]
            lastScan = AgentScan()
            return
        }
        let interval = max(1, settings.agentScanIntervalSeconds)
        // The scan looks at every process on the Mac; nothing waits on it.
        scanTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let roots = self.watchedWorktrees
                let found = await self.scanner.scan(worktrees: roots)
                guard !Task.isCancelled else { return }
                self.apply(scan: found)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    // MARK: Events

    private func handle(_ incoming: HookEvent) {
        var event = incoming
        hermesTaskSessions.resolve(&event)
        eventsReceived += 1
        settlePermission(movedOnBy: event)
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
        // A subagent works for its session wherever it runs. One in a worktree of its own
        // (`.claude/worktrees/agent-<id>`) reports from there, but belongs on its parent's card: placed
        // by its folder, it moved the whole session there and back with every step.
        let sessionKey = AgentStatus.key(session: event.sessionID, agent: event.agent)
        let parentWorktree = event.agentID == nil || event.sessionID == nil ? nil
            : machines.first(where: { $0.value[sessionKey] != nil })?.key
        if let parentWorktree, let own = event.cwd.flatMap(resolveWorktree), own != parentWorktree {
            event.subagentWorktree = own
        }
        let placed = parentWorktree ?? placement.place(session: event.sessionID, cwdMatch: event.cwd.flatMap(resolveWorktree),
                                                       pathMatch: pathMatch, changesFiles: event.isMutatingTool,
                                                       homeMatch: self.hermesDirectory(for: event).flatMap(self.resolveWorktree)).worktree
        contacts[event.agent.id] = AgentContact(agent: event.agent, events: (contacts[event.agent.id]?.events ?? 0) + 1,
                                                lastEventAt: event.receivedAt, lastEvent: event.rawName,
                                                lastWorktree: placed)
        guard let worktree = placed else {
            eventsUnmatched += 1
            record(HookLogEntry(event, outcome: .unplaced(directory: event.cwd, held: event.sessionID != nil)))
            Log.agents.info("\(event.agent.displayName, privacy: .public) \(event.rawName, privacy: .public) fits no watched worktree; it works in \(event.cwd ?? "an unknown folder")")
            // A request from outside the watched worktrees has nowhere to be answered here.
            if let id = event.permissionRequestID { server?.permissions.answer(id, nil) }
            hold(event)
            var directories = event.cwd.map { [$0] } ?? []
            if let file = event.filePath, file.hasPrefix("/") { directories.append((file as NSString).deletingLastPathComponent) }
            directories += event.absolutePathHints
            onUnwatchedWork(directories, event.agent)
            return
        }
        record(HookLogEntry(event, outcome: .placed(worktree: worktree)))
        // The session moved on: do not leave its old status behind. That includes a status taken
        // from Claude Code's record of the session where its process started.
        let key = AgentStatus.key(session: event.sessionID, agent: event.agent)
        var moved = false
        if event.sessionID != nil {
            for (other, sessions) in machines where other != worktree && sessions[key] != nil {
                remove(session: key, from: other)
                moved = true
            }
        }
        var machine = machines[worktree]?[key] ?? AgentStatusMachine()
        let before = machine.status?.activity
        var notes: [AgentNote] = []
        if let session = event.sessionID, let held = heldBySession.removeValue(forKey: session) {
            for earlier in held { notes += machine.apply(Self.anchored(earlier, in: worktree)) }
        }
        notes += machine.apply(Self.anchored(event, in: worktree))
        if let status = machine.status, let start = recordedTurnStart(for: status) { machine.backdateTurn(to: start) }
        machines[worktree, default: [:]][key] = machine
        if let id = event.permissionRequestID {
            // The status matched the request to the call that asked, which tells what settles it.
            let call = machine.status?.pendingPermission ?? PendingPermission(callID: event.toolUseID, agentID: event.agentID)
            var pending = PermissionRequest(id: id, session: key, worktree: worktree, agent: event.agent,
                                            tool: event.toolName ?? "", detail: event.summary, command: event.command,
                                            since: event.receivedAt, call: call)
            if settings.autoAnswerPermissions {
                let allow = settings.autoAnswer == .allow
                // A call you asked Claude Code to always ask about is never allowed by itself, nor one
                // whose command was too long to check against those rules in full.
                if allow, let rule = askRules(cwd: event.cwd, worktree: worktree).matchingAskRule(tool: pending.tool, command: event.command) {
                    pending.waitsForAskRule = rule
                } else if allow, event.commandTruncated {
                    pending.waitsForLongCommand = true
                } else {
                    pending.autoAnswer = .init(allow: allow, at: event.receivedAt.addingTimeInterval(TimeInterval(settings.autoAnswerSeconds)))
                }
            }
            pendingPermissions[key] = pending
            scheduleAutoAnswer(pending)
            Log.agents.notice("\(event.agent.displayName, privacy: .public) asks to use \(pending.tool, privacy: .public); waiting for an answer here or in its own prompt")
            onPermissionRequest(pending)
            onPermissionsChange()
        }
        if moved || before == nil { attributeProcesses() }
        schedulePublish(urgent: !Self.sameState(before, machine.status?.activity))
        if !notes.isEmpty { onNotes(worktree, event.agent, notes) }
        watchForApprovals()
    }

    private func handle(_ note: HookSocketServer.Note) {
        switch note {
        case .rejected(let rejection):
            record(HookLogEntry(at: rejection.at, agent: nil, event: "", outcome: .rejected(rejection)))
            Log.hooks.error("Turned down a request to \(rejection.target, privacy: .public): \(rejection.status) \(rejection.reason, privacy: .public); JSON keys: \((rejection.keys ?? []).joined(separator: ", "), privacy: .public)")
        case .test(let token):
            arrivedTests[token] = Date()
            record(HookLogEntry(at: Date(), agent: nil, event: "MimamoriTest", outcome: .test))
            Log.hooks.notice("A test event arrived through the hook command")
        case .hungUp(let id):
            permissionAnsweredElsewhere(id)
        case .state(let state):
            isListening = state == .listening
            socketError = state == .deferring ? Self.deferringMessage : nil
            if state == .deferring {
                Log.hooks.error("Another copy of Mimamori took the hook socket at \(self.socketPath); hook events go to it until it quits")
            } else if state == .listening {
                Log.hooks.notice("Listening for hook events at \(self.socketPath) again")
            }
        }
    }

    /// Why the socket is not listening while another copy of Mimamori has it.
    static let deferringMessage = "another copy of Mimamori has the socket; this one takes over when it quits"

    private func record(_ entry: HookLogEntry) {
        hookLog.insert(entry, at: 0)
        if hookLog.count > Self.hookLogCapacity { hookLog.removeLast(hookLog.count - Self.hookLogCapacity) }
    }

    // MARK: Permission requests

    /// You answered a permission request in Mimamori, on a paired iPhone (`phone`, its name), or
    /// its countdown did: the hook hands the agent the decision.
    func answerPermission(_ id: String, allow: Bool, automatically: Bool = false, phone: String? = nil) {
        guard let pending = pendingPermissions.values.first(where: { $0.id == id }) else { return }
        pendingPermissions.removeValue(forKey: pending.session)
        autoAnswerTasks.removeValue(forKey: id)?.cancel()
        server?.permissions.answer(id, allow ? .allow : .deny)
        onPermissionSettled(id)
        onPermissionAnswered(pending, allow, automatically, phone)
        onPermissionsChange()
        let how = phone.map { " on \($0)" } ?? (automatically ? " by itself, after waiting" : "")
        Log.agents.notice("\(allow ? "Allowed" : "Denied", privacy: .public) \(pending.agent.displayName, privacy: .public)'s \(pending.tool, privacy: .public) from Mimamori\(how, privacy: .public)")
        // Allowed, it gets on with the step: show it working rather than still waiting on you.
        if allow { noteApproved(in: pending.worktree, session: pending.session) }
    }

    /// Stops a request's countdown: it waits for you.
    func stopAutoAnswer(_ id: String) {
        guard let pending = pendingPermissions.values.first(where: { $0.id == id }) else { return }
        autoAnswerTasks.removeValue(forKey: id)?.cancel()
        pendingPermissions[pending.session]?.autoAnswer = nil
        onPermissionsChange()
    }

    private func scheduleAutoAnswer(_ pending: PermissionRequest) {
        autoAnswerTasks.removeValue(forKey: pending.id)?.cancel()
        guard let plan = pending.autoAnswer else { return }
        autoAnswerTasks[pending.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, plan.at.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, let current = self.pendingPermissions[pending.session],
                  current.id == pending.id, current.autoAnswer != nil else { return }
            self.answerPermission(pending.id, allow: plan.allow, automatically: true)
        }
    }

    /// The ask rules in Claude Code's user settings and in the project's own, where the session works.
    private func askRules(cwd: String?, worktree: String) -> ClaudePermissionRules {
        var files = [HookInstaller.settingsURL]
        for root in Set([cwd, worktree].compactMap { $0 }) {
            let folder = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
            files += [folder.appendingPathComponent("settings.json"), folder.appendingPathComponent("settings.local.json")]
        }
        return ClaudePermissionRules(ask: files.flatMap { file -> [String] in
            guard let data = try? Data(contentsOf: file),
                  let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return ClaudePermissionRules.askRules(in: settings)
        })
    }

    /// Lets a request go with no decision, leaving it to the agent's own prompt.
    private func settlePermission(for session: String) {
        guard let pending = pendingPermissions.removeValue(forKey: session) else { return }
        autoAnswerTasks.removeValue(forKey: pending.id)?.cancel()
        server?.permissions.answer(pending.id, nil)
        onPermissionSettled(pending.id)
        onPermissionsChange()
    }

    /// The agent's own prompt was answered, or the session moved on: the step that asked finished
    /// or was denied, the turn ended, or another request came. The status settles it by the same
    /// rule, `PendingPermission.isSettled(by:)`.
    private func settlePermission(movedOnBy event: HookEvent) {
        let session = AgentStatus.key(session: event.sessionID, agent: event.agent)
        guard let pending = pendingPermissions[session], event.permissionRequestID != pending.id,
              pending.call.isSettled(by: event) else { return }
        settlePermission(for: session)
    }

    enum HookTestResult: Equatable {
        case arrived(milliseconds: Int)
        case noAnswer(String)
    }

    /// Sends a test event the way an agent does: the hook command Mimamori installs, run by the
    /// shell with the event on its standard input. That command never fails, so as not to hold
    /// an agent up, so only the event's arrival tells whether it works.
    func sendTestEvent() async -> HookTestResult {
        guard isListening else {
            return .noAnswer("The socket is not listening" + (socketError.map { ": \($0)" } ?? "."))
        }
        let token = UUID().uuidString
        let command = ClaudeHooksConfig.command(socketPath: socketPath)
        let payload = Data(#"{"hook_event_name":"MimamoriTest","mimamori_test":"\#(token)"}"#.utf8)
        let sentAt = Date()
        Log.hooks.notice("Sending a test event through the hook command")
        let ran = await Task.detached(priority: .userInitiated) { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            input.fileHandleForWriting.write(payload)
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            return true
        }.value
        guard ran else { return .noAnswer("Could not run /bin/sh.") }
        for _ in 0..<40 {
            if let arrived = arrivedTests.removeValue(forKey: token) {
                return .arrived(milliseconds: max(1, Int(arrived.timeIntervalSince(sentAt) * 1000)))
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Log.hooks.error("The test event did not arrive within 2 seconds")
        return .noAnswer("Nothing arrived within 2 seconds. The hook command needs curl at /usr/bin/curl.")
    }

    // MARK: Approvals

    private var commandsAwaitingPermission: [(worktree: String, session: String, command: String, since: Date)] {
        machines.flatMap { worktree, sessions in
            sessions.compactMap { key, machine in
                machine.status?.commandAwaitingPermission.map { (worktree, key, $0.command, $0.since) }
            }
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
                // Quick at first, when an approval is likely, so it shows as you give it (a look
                // through every process takes about 10 ms); a dialog left open is checked less often.
                try? await Task.sleep(for: .milliseconds(Date().timeIntervalSince(waitingSince) < 120 ? 500 : 2000))
                guard let self, !Task.isCancelled else { return }
                let waiting = self.commandsAwaitingPermission
                guard !waiting.isEmpty else { break }
                let commands = Dictionary(waiting.map { ($0.command, $0.since) }, uniquingKeysWith: min)
                let running = await Task.detached(priority: .utility) { ClaudeCommandProbe.running(commands) }.value
                for item in waiting where running.contains(item.command) {
                    self.noteApproved(in: item.worktree, session: item.session)
                }
            }
            self?.approvalWatch = nil
        }
    }

    /// The agent ended the hook waiting on request `id`: it was answered in the agent's own
    /// prompt. Its Allow and Deny here go, as does the notification. Said yes, the command
    /// shows up running (or finishes) in a moment; said no, nothing more comes, and the agent
    /// waits for you to say what to do instead.
    private func permissionAnsweredElsewhere(_ id: String) {
        guard let pending = pendingPermissions.values.first(where: { $0.id == id }) else { return }
        Log.agents.notice("\(pending.agent.displayName, privacy: .public) stopped waiting on its \(pending.tool, privacy: .public) request: it was answered in its own prompt")
        settlePermission(for: pending.session)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            // Still waiting by its hooks' account, and on this request rather than a newer one.
            guard let self, let status = self.machines[pending.worktree]?[pending.session]?.status,
                  case .needsPermission = status.activity, status.since <= pending.since.addingTimeInterval(1) else { return }
            if let awaiting = status.commandAwaitingPermission {
                let running = await Task.detached(priority: .utility) {
                    ClaudeCommandProbe.running([awaiting.command: awaiting.since])
                }.value
                if running.contains(awaiting.command) { return self.noteApproved(in: pending.worktree, session: pending.session) }
            }
            guard var machine = self.machines[pending.worktree]?[pending.session], machine.noteDeclined() else { return }
            self.machines[pending.worktree]?[pending.session] = machine
            self.schedulePublish(urgent: true)
        }
    }

    private func noteApproved(in worktree: String, session key: String) {
        settlePermission(for: key)
        guard var machine = machines[worktree]?[key], machine.noteApproved() else { return }
        machines[worktree]?[key] = machine
        schedulePublish(urgent: true)
    }

    private func remove(session key: String, from worktree: String) {
        machines[worktree]?.removeValue(forKey: key)
        if machines[worktree]?.isEmpty == true { machines.removeValue(forKey: worktree) }
    }

    /// Forgets sessions put to sleep. Not every agent says goodbye as it quits, and a session
    /// still "ready" would keep showing for minutes after its process went.
    func forgetSessions(_ sessionIDs: Set<String>, in worktree: String) {
        guard let sessions = machines[worktree] else { return }
        for (key, machine) in sessions where machine.status?.sessionID.map(sessionIDs.contains) == true {
            remove(session: key, from: worktree)
        }
        publishStatuses()
    }

    /// The directory Hermes records for the event's session. A session's row is written when its
    /// first turn starts, so a miss is asked again a few seconds later.
    private func hermesDirectory(for event: HookEvent) -> String? {
        guard event.agent == .hermes, let session = event.sessionID, !session.isEmpty else { return nil }
        let now = Date()
        if let known = hermesDirectories[session], now.timeIntervalSince(known.at) < (known.directory == nil ? 5 : 60) {
            return known.directory
        }
        let directory = HermesSessions.directory(forSession: session, in: HermesHookInstaller.stateDatabaseURL)
        hermesDirectories[session] = (directory, now)
        if hermesDirectories.count > 200 {
            hermesDirectories = hermesDirectories.filter { now.timeIntervalSince($0.value.at) < 600 }
        }
        return directory
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
        let fresh = machines.compactMapValues { sessions -> [AgentStatus]? in
            let list = sessions.values.compactMap(\.status).sorted(by: WorktreeAgents.morePressing)
            return list.isEmpty ? nil : list
        }
        if fresh != statuses {
            statuses = fresh
            onStatusChange()
        }
        updateAgents()
    }

    // MARK: Several agents

    /// Works out who is in each worktree, and announces a second agent arriving and two agents
    /// editing the same file, each once.
    private func updateAgents() {
        let now = Date()
        var fresh: [String: WorktreeAgents] = [:]
        for worktree in Set(statuses.keys).union(processes.keys) {
            fresh[worktree] = WorktreeAgents(statuses: statuses[worktree] ?? [], processes: processes[worktree] ?? [],
                                             established: establishedPIDs, now: now)
        }
        if fresh != agents {
            agents = fresh
            onAgentsChange()
        }

        for (worktree, here) in fresh where here.isShared {
            let present = Set(here.live.map(\.key) + here.unclaimed.map { "pid:\($0.pid)" })
            if !present.isSubset(of: announcedAgents[worktree] ?? []) {
                let kinds = here.live.map(\.agent) + here.unclaimed.map(\.kind)
                onNotes(worktree, kinds[0], [AgentNote(kind: .sharedWorktree, title: "\(here.agentCount) agents are working here",
                                                      detail: WorktreeAgents.describe(kinds))])
            }
            announcedAgents[worktree] = present

            var announced = announcedCollisions[worktree] ?? []
            let new = here.collisions.filter { announced.insert($0.path + "|" + $0.sessions.sorted().joined(separator: ",")).inserted }
            announcedCollisions[worktree] = announced
            if let latest = new.first, let collision = Self.collision(new, in: worktree) {
                let files = new.map { Self.relative($0.path, in: worktree) }
                onNotes(worktree, latest.agents.last ?? .unnamed,
                        [AgentNote(kind: .collision, title: collision.title, detail: files.joined(separator: ", "), filePath: latest.path)])
            }
        }
        // Back to one agent: forget what was announced and dismissed there.
        for worktree in Set(announcedAgents.keys).union(announcedCollisions.keys).union(dismissedCollisions.keys)
        where fresh[worktree]?.isShared != true {
            announcedAgents.removeValue(forKey: worktree)
            announcedCollisions.removeValue(forKey: worktree)
            if dismissedCollisions[worktree] != nil { dismissedCollisions.removeValue(forKey: worktree) }
        }
    }

    /// Quiets the collision warning in `worktree` until the agents share another file.
    func dismissCollision(in worktree: String) {
        let paths = Set(agents[worktree]?.collisions.map(\.path) ?? [])
        dismissedCollisions[worktree, default: []].formUnion(paths)
    }

    /// The collisions in a worktree you have not dismissed.
    private func openCollisions(in worktree: String) -> [WorktreeAgents.Collision] {
        let dismissed = dismissedCollisions[worktree] ?? []
        return (agents[worktree]?.collisions ?? []).filter { !dismissed.contains($0.path) }
    }

    private static func relative(_ path: String, in worktree: String) -> String {
        path.hasPrefix(worktree + "/") ? String(path.dropFirst(worktree.count + 1)) : path
    }

    /// What views show of agent processes. CPU readings differ on every scan; only a change
    /// in which processes run, or whether they are busy, is worth a repaint.
    private static func visibleSummary(_ found: [String: [AgentProcess]]) -> [String: [String]] {
        found.filter { !$0.value.isEmpty }.mapValues { list in
            list.map { "\($0.pid)|\($0.kind.id)|\($0.isBusy)" }.sorted()
        }
    }

    /// The worktree each session's status is in.
    private var sessionHomes: [String: String] {
        var homes: [String: String] = [:]
        for (worktree, sessions) in machines {
            for machine in sessions.values {
                if let session = machine.status?.sessionID { homes[session] = worktree }
            }
        }
        return homes
    }

    /// Re-files the last scan's processes after a session's status moved to another worktree.
    private func attributeProcesses() {
        let found = lastScan.attributed(homes: sessionHomes)
        if Self.visibleSummary(found) != Self.visibleSummary(processes) { processes = found }
    }

    private func apply(scan: AgentScan) {
        establishedPIDs = Set(lastScan.byWorktree.values.flatMap { $0.map(\.pid) } + lastScan.elsewhere.map(\.pid))
        lastScan = scan
        refreshHookState()
        var changed = adoptSessionRecords()
        if adoptHermesTurns() { changed = true }
        if backdateUnheardTurns() { changed = true }
        let previous = processes
        let found = scan.attributed(homes: sessionHomes)
        if Self.visibleSummary(found) != Self.visibleSummary(previous) { processes = found }
        // Announce arrivals and departures only where hooks are not already reporting. A process
        // counted in another worktree than before neither arrived nor left.
        let before = Set(previous.values.flatMap { $0.map(\.pid) })
        let running = Set(scan.byWorktree.values.flatMap { $0.map(\.pid) } + scan.elsewhere.map(\.pid))
        for (worktree, list) in found where machines[worktree]?.isEmpty ?? true {
            for process in list where !before.contains(process.pid) {
                onNotes(worktree, process.kind, [AgentNote(kind: .sessionStarted, title: "\(process.kind.displayName) is running here")])
            }
        }
        for (worktree, list) in previous where machines[worktree]?.isEmpty ?? true {
            for process in list where !running.contains(process.pid) {
                onNotes(worktree, process.kind, [AgentNote(kind: .sessionEnded, title: "\(process.kind.displayName) exited")])
            }
        }
        // Hook statuses outlive their process briefly; drop them once the agent is gone for a while,
        // and an ended session soon after it ends. A status taken from Claude Code's record goes
        // with the process; one from Hermes's lease goes with the lease (see adoptHermesTurns).
        let now = Date()
        for (worktree, sessions) in machines {
            let running = found[worktree] ?? []
            for (key, machine) in sessions {
                guard let status = machine.status else { continue }
                let ownProcess = running.contains { process in
                    process.claudeSession.map { $0.sessionID == status.sessionID } ?? (process.kind.id == status.agent.id)
                }
                let silence = now.timeIntervalSince(status.lastEventAt)
                let gone = status.fromSessionRecord ? status.agent == .claudeCode && !ownProcess
                    : status.activity == .idle ? silence > 2 * 60
                    : !ownProcess && silence > WorktreeAgents.liveWindow
                if gone {
                    remove(session: key, from: worktree)
                    changed = true
                    continue
                }
                // A subagent silent for long is taken to have finished, its stop unheard; a turn
                // left waiting only on such subagents ends.
                var expiring = machine
                let notes = expiring.expireSubagents(now: now)
                if expiring.status != status {
                    machines[worktree]?[key] = expiring
                    changed = true
                }
                if !notes.isEmpty { onNotes(worktree, status.agent, notes) }
            }
        }
        if changed { schedulePublish(urgent: true) } else { updateAgents() }
    }

    /// Gives a worktree whose Claude Code sessions have not reported through hooks the status
    /// Claude Code records for them: after Mimamori starts, a session sitting idle sends nothing
    /// until you next use it. Hook statuses win, except one for a session that ended.
    /// Returns whether a status changed.
    private func adoptSessionRecords() -> Bool {
        let homes = sessionHomes
        var changed = false
        for (worktree, list) in lastScan.attributed(homes: homes) {
            let records = list.compactMap(\.claudeSession).filter { record in
                record.activity != nil && (homes[record.sessionID] ?? worktree) == worktree
            }
            // A status taken from a record that is gone goes with it.
            for (key, machine) in machines[worktree] ?? [:]
            where machine.status?.fromSessionRecord == true && machine.status?.agent == .claudeCode
                && !records.contains(where: { $0.sessionID == key }) {
                remove(session: key, from: worktree)
                changed = true
            }
            // Each session its own status; one its hooks report on keeps theirs, unless it ended.
            for record in records {
                var machine = machines[worktree]?[record.sessionID] ?? AgentStatusMachine()
                if let current = machine.status, !current.fromSessionRecord, current.activity != .idle { continue }
                if machine.adopt(record) {
                    machines[worktree, default: [:]][record.sessionID] = machine
                    changed = true
                }
            }
        }
        return changed
    }

    /// Gives a Hermes session whose hooks have not reported, with a turn under way in a watched
    /// worktree, the status Hermes's lease on that turn implies: working since the turn began.
    /// The session's first hook event takes over. Returns whether a status changed.
    private func adoptHermesTurns() -> Bool {
        let turns = watchedWorktrees.isEmpty ? [] : HermesTurns.running(in: HermesHookInstaller.stateDatabaseURL)
        hermesTurns = Dictionary(turns.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        // A status taken from a lease that is gone goes with it: the turn ended, or its process did.
        for (worktree, sessions) in machines {
            for (key, machine) in sessions
            where machine.status?.fromSessionRecord == true && machine.status?.agent == .hermes && hermesTurns[key] == nil {
                remove(session: key, from: worktree)
                changed = true
            }
        }
        let homes = sessionHomes
        for turn in turns {
            let key = turn.sessionID
            let home = homes[key]
            // One its hooks report on keeps theirs, unless it ended.
            if let current = home.flatMap({ machines[$0]?[key]?.status }), !current.fromSessionRecord, current.activity != .idle {
                continue
            }
            // Where Hermes says the session works, or else where its process does.
            guard let worktree = turn.directory.flatMap(resolveWorktree)
                    ?? turn.pid.flatMap({ pid in lastScan.byWorktree.first { $0.value.contains { $0.pid == pid } }?.key })
            else { continue }
            var machine = home.flatMap { machines[$0]?[key] } ?? AgentStatusMachine()
            guard machine.adopt(turn) else { continue }
            if let home, home != worktree { remove(session: key, from: home) }
            machines[worktree, default: [:]][key] = machine
            changed = true
        }
        return changed
    }

    /// Moves the start of each turn Mimamori joined midway back to when the agent's own record
    /// says it began. Returns whether one moved.
    private func backdateUnheardTurns() -> Bool {
        var changed = false
        for (worktree, sessions) in machines {
            for (key, var machine) in sessions {
                guard let status = machine.status, let start = recordedTurnStart(for: status), machine.backdateTurn(to: start) else { continue }
                machines[worktree]?[key] = machine
                changed = true
            }
        }
        return changed
    }

    /// When the agent's own record says the current turn began, for a turn whose start Mimamori
    /// did not hear: Hermes's lease on it, or Claude Code's session file while it says busy.
    private func recordedTurnStart(for status: AgentStatus) -> Date? {
        guard status.turnStartUnheard, let session = status.sessionID else { return nil }
        if status.agent == .hermes { return hermesTurns[session]?.startedAt }
        guard status.agent == .claudeCode,
              let record = (lastScan.byWorktree.values.joined() + lastScan.elsewhere).lazy.compactMap(\.claudeSession)
                .first(where: { $0.sessionID == session }),
              record.status == "busy" else { return nil }
        return record.statusUpdatedAt
    }

    private func refreshHookState() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: HookInstaller.settingsURL.path))?[.modificationDate] as? Date
        guard stamp != claudeSettingsStamp else { return }
        claudeSettingsStamp = stamp
        let installed = HookInstaller.isInstalled()
        if installed != claudeHooksInstalled { claudeHooksInstalled = installed }
    }

    // MARK: Queries

    func presence(for worktree: String) -> AgentPresence? {
        let running = processes[worktree] ?? []
        let here = agents[worktree]
        let claims = here?.claims ?? [:]
        let unclaimed = here?.unclaimed ?? []
        let collision = Self.collision(openCollisions(in: worktree), in: worktree)

        // The most pressing session leads; an ended one only while its process still runs.
        if let status = statuses[worktree]?.first, status.activity != .idle || !running.isEmpty {
            let others = (here?.live ?? []).filter { $0.key != status.key }
            // Processes another session claims (an ended one keeps its own) or that are agents of their own.
            let elsewhere = Set(claims.filter { $0.key != status.key }.values.joined()).union(unclaimed.map(\.pid))
            var presence = sessionPresence(status, processIDs: claims[status.key] ?? running.map(\.pid).filter { !elsewhere.contains($0) },
                                           running: running)
            presence.others = others.map { sessionPresence($0, processIDs: claims[$0.key] ?? [], running: running) }
                + unclaimed.map { processPresence([$0]) }
            presence.collision = collision
            return presence
        }
        guard !running.isEmpty else { return nil }
        // No session has reported: agents seen only as processes.
        if unclaimed.count > 1 {
            var presence = processPresence([unclaimed[0]])
            presence.others = unclaimed.dropFirst().map { processPresence([$0]) }
            return presence
        }
        return processPresence(running)
    }

    /// Every agent in `worktree` with the processes sleep would stop: each live session with the
    /// processes it accounts for, and each process that is an agent of its own. Straight from the
    /// machines, since published statuses may lag by a moment.
    func sleepCandidates(in worktree: String) -> [SleepCandidate] {
        let running = processes[worktree] ?? []
        let statuses = (machines[worktree] ?? [:]).values.compactMap(\.status)
        let here = WorktreeAgents(statuses: statuses, processes: running, established: establishedPIDs)
        var candidates = here.live.map { status in
            let pids = here.claims[status.key] ?? []
            return SleepCandidate(agent: status.agent, sessionID: status.sessionID, activity: status.activity,
                                  processes: running.filter { pids.contains($0.pid) }, task: status.task)
        }
        candidates += here.unclaimed.map { process in
            SleepCandidate(agent: process.kind, sessionID: process.claudeSession?.sessionID,
                           activity: process.claudeSession?.activity, processes: [process])
        }
        return candidates
    }

    /// Agent processes running in `worktree`, as the last scan found them.
    func runningProcesses(in worktree: String) -> [AgentProcess] { processes[worktree] ?? [] }

    private func sessionPresence(_ status: AgentStatus, processIDs: [Int32], running: [AgentProcess]) -> AgentPresence {
        let own = running.filter { processIDs.contains($0.pid) }
        return AgentPresence(kind: status.agent, source: .hooks, activity: status.activity, since: status.since,
                             processCount: own.count, isBusy: own.contains(where: \.isBusy),
                             lastToolCall: status.recentToolCalls.last, toolCallsThisTurn: status.toolCallsThisTurn,
                             task: status.task, turnSteps: status.turnToolCalls,
                             turnStartedAt: status.turnStartedAt ?? status.lastTurnStartedAt,
                             processIDs: processIDs,
                             awaitingCallID: status.pendingPermission?.callID,
                             permissionRequestID: pendingPermissions[status.key]?.id,
                             subagents: status.subagents, commands: status.commands)
    }

    private func processPresence(_ running: [AgentProcess]) -> AgentPresence {
        let first = running[0]
        let earliest = running.map(\.startedAt).min() ?? first.startedAt
        return AgentPresence(kind: first.kind, source: .process, activity: .idle, since: earliest,
                             processCount: running.count, isBusy: running.contains(where: \.isBusy),
                             lastToolCall: nil, toolCallsThisTurn: 0, processIDs: running.map(\.pid),
                             hooksInstalled: first.kind == .claudeCode ? claudeHooksInstalled
                                : contacts[first.kind.id] != nil ? true : nil)
    }

    private static func collision(_ collisions: [WorktreeAgents.Collision], in worktree: String) -> AgentCollision? {
        guard !collisions.isEmpty else { return nil }
        var kinds: [AgentKind] = []
        var seen = Set<String>()
        for collision in collisions {
            for (session, kind) in zip(collision.sessions, collision.agents) where seen.insert(session).inserted { kinds.append(kind) }
        }
        return AgentCollision(agents: WorktreeAgents.describe(kinds), files: collisions.map(\.path))
    }

    var worktreesNeedingAttention: [String] {
        let waiting = statuses.filter { $0.value.contains { $0.activity.needsAttention } }.keys
        let colliding = agents.keys.filter { !openCollisions(in: $0).isEmpty }
        return Set(waiting).union(colliding).sorted()
    }

    var activeWorktreeCount: Int {
        Set(processes.filter { !$0.value.isEmpty }.keys)
            .union(statuses.filter { $0.value.contains { $0.activity != .idle } }.keys).count
    }

    /// The tool call responsible for a change to `path` in `worktree` around `date`, if hooks know.
    /// With several sessions there, a call naming the file wins; when two could have made it, the
    /// change is credited to both rather than guessed.
    func attribution(for worktree: String, path: String, at date: Date) -> ChangeAttribution? {
        // Straight from the machines: published statuses may lag by a moment.
        WorktreeAgents.attribution(among: (machines[worktree] ?? [:]).values.compactMap(\.status),
                                   path: (worktree as NSString).appendingPathComponent(path), at: date)
    }
}
