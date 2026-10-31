import AppKit
import Foundation
import Observation
import VigilCore

struct RepositoryEntry: Identifiable, Hashable {
    let id: UUID
    var rootPath: String
    var worktrees: [WorktreeInfo] = []
    var error: String?

    var displayName: String { (rootPath as NSString).lastPathComponent }
}

/// Application-wide state: repositories, their sessions, settings and the activity feed.
@MainActor
@Observable
final class AppModel {
    private(set) var repositories: [RepositoryEntry] = []
    private(set) var sessions: [String: WorktreeSession] = [:]
    private(set) var settings: AppSettings
    private(set) var activity: [ActivityEntry] = []
    private(set) var git: GitClient?
    private(set) var gitError: String?
    private(set) var gitVersion: String?
    private(set) var now = Date()
    private(set) var collapsedRepositories: Set<UUID>
    private(set) var hiddenWorktrees: Set<String>
    let agentHub = AgentHub()

    var selectedWorktreeID: String?
    /// The worktree whose session summary sheet is open.
    /// A worktree whose summary window code outside the views wants open; the main window opens it.
    var summaryWindowRequest: String?
    /// The pane the Settings window shows; set it before opening Settings to land on that pane.
    var settingsTab: SettingsTab = .general
    let launchedAt = Date()
    /// Where the activity record begins: the oldest entry kept on disk, or this launch.
    private(set) var activityHistoryStart = Date()
    /// The feed on disk, so it outlives restarts.
    private let activityLog: ActivityLog
    /// Repository awaiting the user's confirmation in the sidebar's dialog.
    var repositoryPendingRemoval: RepositoryEntry?
    var showActivity: Bool
    var flaggedOnly: Bool
    var hideReviewed: Bool
    /// The sidebar lists only worktrees with an agent in them.
    var sidebarAgentsOnly: Bool
    var activityAgentFilter: ActivityAgentFilter
    /// The middle column lists the worktree's commits instead of its changed files.
    var showCommits: Bool
    var sortOrder: ChangeSortOrder
    var activityScopeAll: Bool
    var filterText = ""
    var filterFocusToken = 0
    /// Developer switches from VIGIL_DEBUG_FLAGS (comma separated), e.g. "popover:sidebar".
    let debugFlags: Set<String> = Set((ProcessInfo.processInfo.environment["VIGIL_DEBUG_FLAGS"] ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })

    private var persisted: PersistedState
    private var saveTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var repositoryWatchers: [UUID: FSEventsWatcher] = [:]
    private var rediscoverTasks: [UUID: Task<Void, Never>] = [:]
    private let notifier = Notifier()

    init() {
        let persisted = Persistence.load()
        self.persisted = persisted
        self.settings = persisted.settings
        self.showActivity = persisted.ui.showActivity
        self.showCommits = persisted.ui.showCommits
        self.flaggedOnly = persisted.ui.flaggedOnly
        self.hideReviewed = persisted.ui.hideReviewed
        self.sidebarAgentsOnly = persisted.ui.sidebarAgentsOnly
        self.activityAgentFilter = persisted.ui.activityAgentFilter
        self.sortOrder = persisted.ui.sortOrder
        self.activityScopeAll = persisted.ui.activityScopeAll
        self.selectedWorktreeID = persisted.ui.selectedWorktree
        self.collapsedRepositories = persisted.collapsedRepositories
        self.hiddenWorktrees = persisted.hiddenWorktrees
        self.activityLog = ActivityLog(url: Persistence.activityURL,
                                       retention: Double(persisted.settings.activityRetentionDays) * 86_400)
        startTicker()
        agentHub.resolveWorktree = { [weak self] cwd in self?.worktree(containing: cwd) }
        agentHub.onNotes = { [weak self] worktree, agent, notes in self?.record(agentNotes: notes, agent: agent, worktree: worktree) }
        DebugHooks.start(model: self)
        // Review marks and other edits are saved after a short delay; do not lose them on quit.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persistNow()
                self?.activityLog.flush()
            }
        }
        Task { await bootstrap() }
    }

    // MARK: Derived

    var selectedSession: WorktreeSession? {
        guard let selectedWorktreeID else { return nil }
        return sessions[selectedWorktreeID]
    }

    var orderedSessions: [WorktreeSession] {
        repositories.flatMap { repo in visibleWorktrees(for: repo).compactMap { sessions[$0.path] } }
    }

    func visibleWorktrees(for repo: RepositoryEntry) -> [WorktreeInfo] {
        repo.worktrees.filter { !hiddenWorktrees.contains($0.path) }
    }

    /// The worktrees the sidebar lists: the visible ones, narrowed to those with an agent when
    /// that filter is on.
    func listedWorktrees(for repo: RepositoryEntry) -> [WorktreeInfo] {
        let visible = visibleWorktrees(for: repo)
        guard sidebarAgentsOnly else { return visible }
        return visible.filter { agentHub.presence(for: $0.path) != nil }
    }

    func hiddenWorktrees(for repo: RepositoryEntry) -> [WorktreeInfo] {
        repo.worktrees.filter { hiddenWorktrees.contains($0.path) }
    }

    func visibleSessions(for repo: RepositoryEntry) -> [WorktreeSession] {
        visibleWorktrees(for: repo).compactMap { sessions[$0.path] }
    }

    func isCollapsed(_ repo: RepositoryEntry) -> Bool { collapsedRepositories.contains(repo.id) }

    func setCollapsed(_ collapsed: Bool, for repoID: UUID) {
        if collapsed { collapsedRepositories.insert(repoID) } else { collapsedRepositories.remove(repoID) }
        persisted.collapsedRepositories = collapsedRepositories
        persistSoon()
    }

    /// Stops watching a worktree and removes it from the lists until shown again.
    func hideWorktree(_ path: String) {
        hiddenWorktrees.insert(path)
        persisted.hiddenWorktrees = hiddenWorktrees
        sessions[path]?.stop()
        sessions.removeValue(forKey: path)
        if selectedWorktreeID == path { selectedWorktreeID = orderedSessions.first?.id }
        agentHub.setWatchedWorktrees(Array(sessions.keys))
        persistSoon()
    }

    func showWorktree(_ path: String) {
        hiddenWorktrees.remove(path)
        persisted.hiddenWorktrees = hiddenWorktrees
        persistSoon()
        if let repo = repositories.first(where: { $0.worktrees.contains { $0.path == path } }) {
            Task { await rediscoverWorktrees(for: repo.id) }
        }
    }

    func showAllWorktrees(for repoID: UUID) {
        guard let repo = repositories.first(where: { $0.id == repoID }) else { return }
        for worktree in repo.worktrees { hiddenWorktrees.remove(worktree.path) }
        persisted.hiddenWorktrees = hiddenWorktrees
        persistSoon()
        Task { await rediscoverWorktrees(for: repoID) }
    }

    var totalChangedFiles: Int { sessions.values.reduce(0) { $0 + $1.changes.count } }
    var totalFlagged: Int { sessions.values.reduce(0) { $0 + $1.flaggedCount } }
    var isNotifierAvailable: Bool { notifier.isAvailable }

    func repository(for session: WorktreeSession) -> RepositoryEntry? {
        repositories.first { $0.id == session.repositoryID }
    }

    // MARK: Bootstrap

    private func bootstrap() async {
        await loadActivityHistory()
        await locateGit()
        agentHub.start(settings: settings)
        for repo in persisted.repositories {
            await loadRepository(id: repo.id, rootPath: repo.path)
        }
        if selectedWorktreeID == nil || sessions[selectedWorktreeID!] == nil {
            selectedWorktreeID = orderedSessions.first?.id
        }
    }

    private func locateGit() async {
        git = await GitClient.locate(preferred: settings.gitPathOverride)
        if let git {
            gitVersion = try? await git.version()
            gitError = nil
        } else {
            gitError = "No usable git binary was found. Install Xcode Command Line Tools or Homebrew git, or set a path in Settings."
        }
    }

    private func startTicker() {
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.now = Date()
            }
        }
    }

    // MARK: Repositories

    func promptForRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose a git repository or worktree to watch"
        panel.prompt = "Watch"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls { await addRepository(at: url) }
        }
    }

    func addRepositories(at urls: [URL]) {
        Task {
            for url in urls { await addRepository(at: url) }
        }
    }

    func addRepository(at url: URL) async {
        guard let git else {
            await locateGit()
            if self.git == nil { return }
            await addRepository(at: url)
            return
        }
        do {
            let list = try await git.worktrees(in: url)
            guard let root = list.first?.path else { return }
            if let existing = repositories.first(where: { $0.rootPath == root }) {
                await rediscoverWorktrees(for: existing.id)
                selectedWorktreeID = (try? await git.layout(of: url).topLevel.path) ?? selectedWorktreeID
                return
            }
            let id = UUID()
            persisted.repositories.append(PersistedRepository(id: id, path: root, addedAt: Date()))
            persistSoon()
            await loadRepository(id: id, rootPath: root)
            if let top = try? await git.layout(of: url).topLevel.path, sessions[top] != nil {
                selectedWorktreeID = top
            } else {
                selectedWorktreeID = repositories.first { $0.id == id }?.worktrees.first?.path
            }
        } catch {
            NSSound.beep()
            let alert = NSAlert()
            alert.messageText = "Not a git repository"
            alert.informativeText = "\(url.path)\n\n\(error.localizedDescription)"
            alert.runModal()
        }
    }

    private func loadRepository(id: UUID, rootPath: String) async {
        if !repositories.contains(where: { $0.id == id }) {
            repositories.append(RepositoryEntry(id: id, rootPath: rootPath))
        }
        await rediscoverWorktrees(for: id)
        startRepositoryWatcher(id: id, rootPath: rootPath)
    }

    func requestRemoval(of repo: RepositoryEntry) {
        repositoryPendingRemoval = repo
    }

    /// Asks to stop watching the repository that owns the selected worktree.
    func requestRemovalOfSelectedRepository() {
        guard let session = selectedSession, let repo = repository(for: session) else { return }
        repositoryPendingRemoval = repo
    }

    func removeRepository(_ id: UUID) {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return }
        let repo = repositories.remove(at: index)
        for worktree in repo.worktrees {
            sessions[worktree.path]?.stop()
            sessions.removeValue(forKey: worktree.path)
            persisted.worktreeSettings.removeValue(forKey: worktree.path)
        }
        repositoryWatchers[id]?.stop()
        repositoryWatchers.removeValue(forKey: id)
        // Its history goes too, on disk as well as in the feed.
        let removedPaths = Set(repo.worktrees.map(\.path))
        if activity.contains(where: { removedPaths.contains($0.worktreePath) }) {
            activity.removeAll { removedPaths.contains($0.worktreePath) }
            activityLog.replaceAll(with: activity.reversed())
        }
        persisted.repositories.removeAll { $0.id == id }
        collapsedRepositories.remove(id)
        for worktree in repo.worktrees { hiddenWorktrees.remove(worktree.path) }
        persisted.collapsedRepositories = collapsedRepositories
        persisted.hiddenWorktrees = hiddenWorktrees
        if let selected = selectedWorktreeID, sessions[selected] == nil {
            selectedWorktreeID = orderedSessions.first?.id
        }
        agentHub.setWatchedWorktrees(Array(sessions.keys))
        persistSoon()
    }

    func rediscoverWorktrees(for id: UUID) async {
        guard let git, let index = repositories.firstIndex(where: { $0.id == id }) else { return }
        let rootPath = repositories[index].rootPath
        do {
            let list = try await git.worktrees(in: URL(fileURLWithPath: rootPath, isDirectory: true))
                .filter { !$0.isBare && !$0.isPrunable && FileManager.default.fileExists(atPath: $0.path) }
            repositories[index].worktrees = list
            repositories[index].error = nil
            let known = Set(list.map(\.path)).subtracting(hiddenWorktrees)
            // Stop sessions whose worktrees vanished or were hidden.
            for (path, session) in sessions where session.repositoryID == id && !known.contains(path) {
                session.stop()
                sessions.removeValue(forKey: path)
            }
            for info in list where !hiddenWorktrees.contains(info.path) {
                if let session = sessions[info.path] {
                    session.updateInfo(info)
                } else {
                    let session = WorktreeSession(
                        info: info, repositoryID: id, settings: settings,
                        persisted: persisted.worktreeSettings[info.path] ?? PersistedWorktreeSettings(),
                        onActivity: { [weak self] entries in self?.record(entries) },
                        onSettingsChanged: { [weak self] session in
                            self?.persisted.worktreeSettings[session.id] = session.persistedSettings
                            self?.persistSoon()
                        })
                    let worktreePath = info.path
                    session.attributionProvider = { [weak self] path, date in
                        self?.agentHub.attribution(for: worktreePath, path: path, at: date)
                    }
                    sessions[info.path] = session
                    Task { await session.start(git: git) }
                }
            }
            agentHub.setWatchedWorktrees(Array(sessions.keys))
        } catch {
            repositories[index].error = error.localizedDescription
        }
    }

    /// The watched worktree that contains `cwd`, longest match first.
    func worktree(containing cwd: String) -> String? {
        let candidates = [cwd, URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path]
        var best: String? = nil
        for key in sessions.keys {
            let resolvedKey = URL(fileURLWithPath: key).resolvingSymlinksInPath().path
            for candidate in candidates {
                for root in [key, resolvedKey] where candidate == root || candidate.hasPrefix(root + "/") {
                    if best == nil || key.count > best!.count { best = key }
                }
            }
        }
        return best
    }

    func rediscoverAll() {
        Task {
            for repo in repositories { await rediscoverWorktrees(for: repo.id) }
        }
    }

    private func startRepositoryWatcher(id: UUID, rootPath: String) {
        guard let git else { return }
        Task {
            guard let layout = try? await git.layout(of: URL(fileURLWithPath: rootPath, isDirectory: true)) else { return }
            let common = layout.commonDir.standardizedFileURL.path
            let watcher = FSEventsWatcher(paths: [common], exclusions: [common + "/objects", common + "/refs/monitor"], latency: 0.5) { [weak self] events in
                let relevant = events.contains { event in
                    event.path.hasPrefix(common + "/worktrees") || event.rootChanged
                }
                guard relevant else { return }
                Task { @MainActor [weak self] in self?.scheduleRediscovery(for: id) }
            }
            if (try? watcher.start()) != nil {
                repositoryWatchers[id]?.stop()
                repositoryWatchers[id] = watcher
            }
        }
    }

    private func scheduleRediscovery(for id: UUID) {
        rediscoverTasks[id]?.cancel()
        rediscoverTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.rediscoverWorktrees(for: id)
        }
    }

    // MARK: Actions

    func refreshAll() {
        for session in sessions.values { session.requestRefresh(force: true) }
        rediscoverAll()
    }

    /// Shows a commit in the Commits list: `revision` is any name git accepts, such as a short id.
    func showCommit(_ revision: String, in worktree: String) {
        select(worktree: worktree)
        showCommits = true
        guard let session = sessions[worktree] else { return }
        Task { await session.openCommit(revision: revision) }
    }

    func select(worktree id: String?, path: String? = nil) {
        selectedWorktreeID = id
        if let id, let path, let session = sessions[id] {
            session.selectedPath = path
        }
        persistUISoon()
    }

    /// Diagnostics: how often something asked to update settings, and how often it mattered.
    private(set) var settingsUpdateRequests = 0
    private(set) var settingsUpdatesApplied = 0

    func updateSettings(_ newValue: AppSettings) {
        settingsUpdateRequests += 1
        // SwiftUI bindings (the menu bar item's isInserted, for one) can write back unchanged
        // values on every scene update; those must not touch sessions or disk.
        guard newValue != settings else { return }
        settingsUpdatesApplied += 1
        let old = settings
        settings = newValue
        persisted.settings = newValue
        persistSoon()
        for session in sessions.values { session.updateSettings(newValue) }
        agentHub.updateSettings(newValue)
        if old.activityRetentionDays != newValue.activityRetentionDays {
            applyActivityRetention()
        }
        if old.gitPathOverride != newValue.gitPathOverride {
            Task { await locateGit() }
        }
        if newValue.notificationsEnabled && !old.notificationsEnabled {
            Task { _ = await notifier.requestAuthorization() }
        }
    }

    func settingsBinding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> (get: () -> T, set: (T) -> Void) {
        (get: { self.settings[keyPath: keyPath] },
         set: { value in
            var copy = self.settings
            copy[keyPath: keyPath] = value
            self.updateSettings(copy)
         })
    }

    func clearActivity() {
        activity.removeAll()
        activityLog.replaceAll(with: [])
        activityHistoryStart = Date()
    }

    /// Reads the feed kept from earlier runs. Entries recorded meanwhile are newer and stay on top.
    private func loadActivityHistory() async {
        let log = activityLog
        let loaded = await Task.detached(priority: .utility) { log.load() }.value
        activity += loaded.reversed()
        activityHistoryStart = min(loaded.first?.date ?? launchedAt, launchedAt)
    }

    private func applyActivityRetention() {
        let days = settings.activityRetentionDays
        activityLog.retention = Double(days) * 86_400
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        guard activity.contains(where: { $0.date < cutoff }) else { return }
        activity.removeAll { $0.date < cutoff }
        activityLog.replaceAll(with: activity.reversed())
        activityHistoryStart = max(activityHistoryStart, cutoff)
    }

    // MARK: Session summary

    /// Gathers what a summary reports about a worktree's session. Fetching every file's diff
    /// can take a moment, so it happens only when asked for.
    func sessionSummary(for session: WorktreeSession, includeDiffs: Bool) async -> SessionSummary {
        let state = session.state
        let files = session.changes.map {
            SessionSummary.File(change: $0, review: session.reviewStatus(of: $0), attribution: session.attributions[$0.path])
        }
        let commits = await session.commitsSinceBaseline()

        // The session starts at the start marker or snapshot it is compared with; otherwise the
        // record only goes back as far as Vigil does.
        let cutoff: Date? = switch session.baseline {
        case .start: session.startSnapshot?.date
        case .snapshot(let ref): session.snapshots.first { $0.id == ref }?.date
        case .head, .branchPoint: nil
        }
        let entries = activity.filter { $0.worktreePath == session.id && $0.date >= (cutoff ?? .distantPast) }.reversed()
        let since = max(cutoff ?? activityHistoryStart, activityHistoryStart)

        var names: [String] = []
        if let presence = agentHub.presence(for: session.id) { names.append(presence.kind.displayName) }
        for kind in AgentKind.known where !names.contains(kind.displayName)
            && entries.contains(where: { $0.kind.isAgentEvent && $0.title.hasPrefix(kind.displayName) }) {
            names.append(kind.displayName)
        }
        let presence = agentHub.presence(for: session.id)
        let toolCallNoun: String? = switch settings.agentToolCallsInFeed {
        case .none: nil
        case .mutating: "edits and commands"
        case .all: "tool calls"
        }
        let agent = names.isEmpty ? nil : SessionSummary.Agent(
            names: names,
            state: presence.flatMap { $0.source == .hooks ? $0.statusText : nil },
            toolCallNoun: toolCallNoun)

        var diffs: [String: String] = [:]
        if includeDiffs {
            for change in session.changes.prefix(80) where !change.isBinary && !change.isSubmodule {
                if let diff = try? await session.diff(for: change), !diff.hunks.isEmpty {
                    diffs[change.path] = diff.unifiedText
                }
            }
        }

        return SessionSummary(
            title: state?.branch.displayName ?? session.displayName,
            repository: repository(for: session)?.displayName ?? "",
            worktreePath: session.id,
            baselineLabel: state?.baseline.label ?? session.baseline.title,
            files: files, commits: commits, activity: Array(entries), activitySince: since,
            agent: agent, diffs: diffs, excludedLargeFiles: state?.excludedLargeFiles ?? [])
    }

    /// Marks the selected file reviewed and moves on to the next listed file still to review;
    /// on a file already reviewed, clears the mark instead.
    func toggleReviewForSelection() {
        guard let session = selectedSession, let path = session.selectedPath, let change = session.change(for: path) else { return }
        if session.reviewStatus(of: change).isReviewed {
            session.setReviewed(false, paths: [path])
            return
        }
        // Read the order first: hiding reviewed files would drop this one from the list.
        let listed = listedChanges(in: session).map(\.change.path)
        session.setReviewed(true, paths: [path])
        if let next = nextUnreviewed(after: path, in: listed, session: session) {
            session.selectedPath = next
        }
    }

    private func nextUnreviewed(after path: String, in listed: [String], session: WorktreeSession) -> String? {
        let start = listed.firstIndex(of: path).map { $0 + 1 } ?? 0
        let ordered = listed[start...] + listed[..<min(start, listed.count)]
        return ordered.first { candidate in
            candidate != path && session.change(for: candidate).map { !session.reviewStatus(of: $0).isReviewed } == true
        }
    }

    var selectedChangeIsReviewed: Bool {
        guard let session = selectedSession, let path = session.selectedPath, let change = session.change(for: path) else { return false }
        return session.reviewStatus(of: change).isReviewed
    }

    var worktreesNeedingAttention: [String] { agentHub.worktreesNeedingAttention }

    private func record(agentNotes notes: [AgentNote], agent: AgentKind, worktree: String) {
        var entries: [ActivityEntry] = []
        for note in notes {
            let kind: ActivityKind
            var severity: Severity? = nil
            switch note.kind {
            case .sessionStarted, .sessionEnded, .notification, .sharedWorktree: kind = .agentSession
            case .collision: kind = .agentAttention; severity = .warning
            case .turnStarted, .turnFinished: kind = .agentTurn
            case .toolCall:
                switch settings.agentToolCallsInFeed {
                case .none: continue
                case .mutating where !note.isMutatingTool: continue
                default: kind = .agentTool
                }
            case .needsPermission: kind = .agentAttention; severity = .warning
            case .waiting: kind = .agentAttention
            }
            var relativePath: String? = nil
            if let file = note.filePath, file.hasPrefix(worktree + "/") {
                relativePath = String(file.dropFirst(worktree.count + 1))
            }
            entries.append(ActivityEntry(worktreePath: worktree, kind: kind, path: relativePath,
                                         title: note.title, detail: note.detail, severity: severity,
                                         agent: agent.displayName))
        }
        record(entries)
        let name = sessions[worktree]?.displayName ?? (worktree as NSString).lastPathComponent
        for note in notes {
            if note.kind == .needsPermission || note.kind == .waiting, settings.notifyOnAgentPermission {
                notifier.notify(title: note.title, body: [note.detail, name].compactMap { $0 }.joined(separator: " · "), key: "permission:" + worktree)
            }
            if note.kind == .collision, settings.notifyOnAgentCollision {
                notifier.notify(title: note.title, body: [note.detail, name].compactMap { $0 }.joined(separator: " · "), key: "collision:" + worktree)
            }
            if note.kind == .turnFinished, settings.notifyOnAgentTurnFinished {
                notifier.notify(title: note.title, body: [note.detail, name].compactMap { $0 }.joined(separator: " · "), key: "turn:" + worktree)
            }
        }
    }

    private func record(_ entries: [ActivityEntry]) {
        guard !entries.isEmpty else { return }
        activity.insert(contentsOf: entries.reversed(), at: 0)
        if activity.count > activityLog.maxEntries { activity.removeLast(activity.count - activityLog.maxEntries) }
        activityLog.append(entries)
        if settings.notificationsEnabled, let first = entries.first, let session = sessions[first.worktreePath] {
            notifier.notify(entries: entries, worktreeName: session.displayName, minimumSeverity: settings.notifyMinimumSeverity)
        }
    }

    // MARK: Persistence

    func persistUISoon() {
        persisted.ui = PersistedUIState(showActivity: showActivity, flaggedOnly: flaggedOnly, sortOrder: sortOrder,
                                        selectedWorktree: selectedWorktreeID, activityScopeAll: activityScopeAll,
                                        hideReviewed: hideReviewed, sidebarAgentsOnly: sidebarAgentsOnly,
                                        activityAgentFilter: activityAgentFilter, showCommits: showCommits)
        persistSoon()
    }

    private func persistSoon() {
        saveTask?.cancel()
        let snapshot = persisted
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            Persistence.save(snapshot)
        }
    }

    func persistNow() {
        persisted.ui = PersistedUIState(showActivity: showActivity, flaggedOnly: flaggedOnly, sortOrder: sortOrder,
                                        selectedWorktree: selectedWorktreeID, activityScopeAll: activityScopeAll,
                                        hideReviewed: hideReviewed, sidebarAgentsOnly: sidebarAgentsOnly,
                                        activityAgentFilter: activityAgentFilter, showCommits: showCommits)
        saveTask?.cancel()
        Persistence.save(persisted)
    }
}
