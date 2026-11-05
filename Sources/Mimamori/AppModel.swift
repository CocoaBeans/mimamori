import AppKit
import Foundation
import Observation
import MimamoriCore

struct RepositoryEntry: Identifiable, Hashable {
    let id: UUID
    var rootPath: String
    var worktrees: [WorktreeInfo] = []
    var error: String?
    /// The color picked for it by hand, and whether its own icon is set aside (saved).
    var color: RepositoryColor?
    var hidesIcon = false

    var displayName: String { (rootPath as NSString).lastPathComponent }
}

/// Application-wide state: repositories, their sessions, settings and the activity feed.
@MainActor
@Observable
final class AppModel {
    private(set) var repositories: [RepositoryEntry] = []
    /// Icons found in repositories' files, with the color each suggests.
    private(set) var repositoryIcons: [UUID: FoundRepositoryIcon] = [:]
    private(set) var sessions: [String: WorktreeSession] = [:]
    private(set) var settings: AppSettings
    private(set) var activity: [ActivityEntry] = []
    private(set) var git: GitClient?
    private(set) var gitError: String?
    private(set) var gitVersion: String?
    /// The clock behind relative times in lists ("3m ago"): they read in minutes, so it ticks
    /// every 30 s.
    private(set) var now = Date()
    /// The clock behind agents' timers ("working for 42s"), which count seconds in their first
    /// minute: every 2 s while one does, otherwise with `now`.
    private(set) var agentNow = Date()
    private(set) var collapsedRepositories: Set<UUID>
    private(set) var hiddenWorktrees: Set<String>
    let agentHub = AgentHub()

    var selectedWorktreeID: String?
    /// The worktree whose session summary sheet is open.
    /// A worktree whose summary window code outside the views wants open; the main window opens it.
    var summaryWindowRequest: String?
    /// The pane the Settings window shows; set it before opening Settings to land on that pane.
    var settingsTab: SettingsTab = .general
    /// The topic the Help window shows; set it before opening Help to land on that topic.
    var helpTopic: HelpTopic.ID = .gettingStarted
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
    /// Developer switches from MIMAMORI_DEBUG_FLAGS (comma separated), e.g. "popover:sidebar".
    /// Debug builds only: a release build has none, so the switches cannot be set there.
    #if DEBUG
    let debugFlags: Set<String> = Set((ProcessInfo.processInfo.environment["MIMAMORI_DEBUG_FLAGS"] ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    #else
    let debugFlags: Set<String> = []
    #endif

    private var persisted: PersistedState
    private var saveTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    @ObservationIgnored private var worktreeRoots: (keys: Set<String>, roots: [(key: String, paths: [String])]) = ([], [])
    @ObservationIgnored private var resolvedPaths: [String: String] = [:]
    /// Entries recorded but not yet in `activity`. Agents report several times a second and every
    /// change to the feed redraws it, so new entries join it at most twice a second.
    @ObservationIgnored private var pendingActivity: [ActivityEntry] = []
    @ObservationIgnored private var activityFlush: Task<Void, Never>?
    @ObservationIgnored private var tickingFast = true
    @ObservationIgnored private var visibilityObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Each repository's watch on its git folder, for worktrees coming and going.
    @ObservationIgnored private let repositoryWatchers = WatchRegistry<UUID, FSEventsWatcher> { $0.stop() }
    @ObservationIgnored private var worktreeListings = WorktreeListings()
    private var rediscoverTasks: [UUID: Task<Void, Never>] = [:]
    let notifier = Notifier()
    /// Whether the Agents window is open; saved, so it opens again at launch. Windows that close
    /// because Mimamori quits leave it as it was.
    @ObservationIgnored var agentsWindowOpen = false
    /// Whether the menu-bar panel is pinned in a window of its own; saved like `agentsWindowOpen`.
    @ObservationIgnored var overviewWindowOpen = false
    @ObservationIgnored var isQuitting = false
    /// Set by Uninstall Mimamori once its settings are gone: quitting must not write them back.
    @ObservationIgnored var isUninstalling = false
    /// Whether the welcome window has been seen. Someone already watching repositories has no
    /// need of it, however they got there.
    @ObservationIgnored private(set) var welcomeShown = false
    /// Why `state.json` couldn't all be read at launch, shown once over the main window.
    var stateNotice: StateNotice?
    /// Repositories agents work in that Mimamori could watch, waiting for your answer.
    var repositoryOffers: [RepositoryOffer] = []
    /// What git said about folders agents worked in, so each is asked about once.
    @ObservationIgnored var checkedAgentFolders: [String: CheckedFolder] = [:]
    /// Repositories offered since launch, so each is offered once.
    @ObservationIgnored var offeredRepositories: Set<String> = []
    @ObservationIgnored private let widgets = WidgetPublisher()
    @ObservationIgnored private var quitObserver: NSObjectProtocol?

    init() {
        let loaded = Persistence.state.load()
        let persisted = loaded.state
        self.persisted = persisted
        let notice = loaded.notice(stateFile: Persistence.stateURL)
        self.stateNotice = notice
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
        self.agentsWindowOpen = persisted.ui.agentsWindowOpen
        // A state file that couldn't be read means you've been here before; the notice says what happened.
        self.welcomeShown = persisted.ui.welcomeShown || !persisted.repositories.isEmpty || notice != nil
        self.overviewWindowOpen = persisted.ui.overviewWindowOpen
        self.collapsedRepositories = persisted.collapsedRepositories
        self.hiddenWorktrees = persisted.hiddenWorktrees
        self.activityLog = ActivityLog(url: Persistence.activityURL,
                                       retention: Double(persisted.settings.activityRetentionDays) * 86_400)
        startTicker()
        refreshAfterWaking()
        agentHub.resolveWorktree = { [weak self] cwd in self?.worktree(containing: cwd) }
        agentHub.onNotes = { [weak self] worktree, agent, notes in self?.record(agentNotes: notes, agent: agent, worktree: worktree) }
        agentHub.onStatusChange = { [weak self] in self?.agentStatusChanged() }
        agentHub.onAgentsChange = { [weak self] in self?.publishWidgets() }
        agentHub.onUnwatchedWork = { [weak self] folders, agent in self?.agentWorks(in: folders, agent: agent) }
        notifier.handleAnswers { [weak self] answer in
            switch answer {
            case .repository(let root, let choice): self?.answerOffer(for: root, choice)
            case .permission(let id, let allow): self?.agentHub.answerPermission(id, allow: allow)
            }
        }
        agentHub.onPermissionRequest = { [weak self] pending in self?.permissionRequested(pending) }
        agentHub.onPermissionSettled = { [weak self] id in self?.notifier.withdrawPermission(id: id) }
        agentHub.onPermissionAnswered = { [weak self] pending, allow, automatically in
            self?.permissionAnswered(pending, allow: allow, automatically: automatically)
        }
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.widgets.appQuitting() }
        }
        #if DEBUG
        DebugHooks.start(model: self)
        #endif
        // Review marks and other edits are saved after a short delay; do not lose them on quit.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isQuitting = true
                self?.stopWatchingRepositories()
                if self?.isUninstalling == true {
                    // Whatever was written since, gone again on the way out.
                    Uninstaller.removeData()
                    return
                }
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
        // Tell the widgets Mimamori is running, whether or not an agent is yet.
        publishWidgets()
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

    /// File events can go missing while the Mac sleeps, and the backstop poll is rare, so look
    /// at every worktree once after waking: quietly, spread over a few seconds rather than at once.
    private func refreshAfterWaking() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                for session in self?.sessions.values.map({ $0 }) ?? [] {
                    let delay = Double.random(in: 1...10)
                    Task { @MainActor [weak session] in
                        try? await Task.sleep(for: .seconds(delay))
                        session?.requestRefresh(quiet: true)
                    }
                }
            }
        }
    }

    /// Every change of a clock redraws (and re-measures) each window showing a time from it, so
    /// the clocks tick only as often as their labels change: lists every 30 s, agents' timers
    /// every 2 s while one counts seconds, and neither while no Mimamori window can be seen.
    private func startTicker() {
        tickerTask?.cancel()
        tickingFast = agentTimerCountsSeconds
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                let fast = self?.tickingFast ?? false
                try? await Task.sleep(for: .seconds(fast ? 2 : 30))
                guard let self, !Task.isCancelled else { return }
                if self.anyWindowVisible {
                    let date = Date()
                    self.agentNow = date
                    if date.timeIntervalSince(self.now) >= 29 { self.now = date }
                }
                self.tickingFast = self.agentTimerCountsSeconds
            }
        }
        guard visibilityObservers.isEmpty else { return }
        // Catch up the moment a window comes back into view.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSApplication.didUnhideNotification] {
            visibilityObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.anyWindowVisible else { return }
                    self.now = Date()
                    self.agentNow = self.now
                }
            })
        }
    }

    /// An agent's state changed: its timer starts again from 0s.
    private func agentStatusChanged() {
        if !tickingFast, agentTimerCountsSeconds { startTicker() }
    }

    /// Whether an agent's timer on screen is still in its first minute, counting seconds.
    private var agentTimerCountsSeconds: Bool {
        let cutoff = Date().addingTimeInterval(-65)
        return agentHub.statuses.values.contains { $0.contains { $0.activity != .idle && $0.since > cutoff } }
            || agentHub.processes.values.contains { $0.contains { $0.startedAt > cutoff } }
    }

    private var anyWindowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && $0.styleMask.contains(.titled) }
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

    /// Watches the repository holding `url`. `select` shows it once added. Added from outside
    /// (a script, an agent, a notification) while Mimamori is in the background, a folder that is
    /// no repository is reported in a notification rather than an alert waiting on screen.
    func addRepository(at url: URL, select: Bool = true, fromOutside: Bool = false) async {
        guard let git else {
            await locateGit()
            if self.git == nil { return }
            await addRepository(at: url, select: select, fromOutside: fromOutside)
            return
        }
        do {
            let list = try await git.worktrees(in: url)
            guard let root = list.first?.path else { return }
            if let existing = repositories.first(where: { $0.rootPath == root }) {
                await rediscoverWorktrees(for: existing.id)
                if select { selectedWorktreeID = (try? await git.layout(of: url).topLevel.path) ?? selectedWorktreeID }
                return
            }
            let id = UUID()
            persisted.repositories.append(PersistedRepository(id: id, path: root, addedAt: Date()))
            persistSoon()
            await loadRepository(id: id, rootPath: root)
            Log.state.notice("Watching \(root)")
            guard select else { return }
            if let top = try? await git.layout(of: url).topLevel.path, sessions[top] != nil {
                selectedWorktreeID = top
            } else {
                selectedWorktreeID = repositories.first { $0.id == id }?.worktrees.first?.path
            }
        } catch {
            Log.state.error("Could not watch \(url.path): \(error.localizedDescription, privacy: .public)")
            if fromOutside, !NSApp.isActive {
                notifier.notify(title: "Mimamori can't watch \(url.lastPathComponent)",
                                body: "It isn't in a git repository: \(url.path)", key: "add:" + url.path)
                return
            }
            NSSound.beep()
            let alert = NSAlert()
            alert.messageText = "Not a git repository"
            alert.informativeText = "\(url.path)\n\n\(error.localizedDescription)"
            alert.runModal()
        }
    }

    private func loadRepository(id: UUID, rootPath: String) async {
        if !repositories.contains(where: { $0.id == id }) {
            let saved = persisted.repositories.first { $0.id == id }
            repositories.append(RepositoryEntry(id: id, rootPath: rootPath, color: saved?.color, hidesIcon: saved?.hidesIcon ?? false))
        }
        Task { await findIcon(for: id) }
        await rediscoverWorktrees(for: id)
        startRepositoryWatcher(id: id, rootPath: rootPath)
    }

    // MARK: Repository looks

    /// How a repository is marked: its own icon if it has one, else its initials, on its color.
    func look(for repo: RepositoryEntry) -> RepositoryLook {
        let found = repositoryIcons[repo.id]
        return RepositoryLook(color: repo.color ?? found?.color ?? .automatic(for: repo.displayName),
                              icon: repo.hidesIcon ? nil : found?.image,
                              monogram: RepositoryMonogram.initials(for: repo.displayName))
    }

    /// Each worktree's repository icon, by worktree path, for the agents' rows.
    var repositoryIconsByWorktree: [String: NSImage] {
        var icons: [String: NSImage] = [:]
        for repo in repositories {
            guard let icon = look(for: repo).icon else { continue }
            for worktree in repo.worktrees { icons[worktree.path] = icon }
        }
        return icons
    }

    func hasIcon(_ repo: RepositoryEntry) -> Bool { repositoryIcons[repo.id] != nil }

    /// Looks for the repository's icon in its files, away from the main thread.
    func findIcon(for id: UUID) async {
        guard let rootPath = repositories.first(where: { $0.id == id })?.rootPath else { return }
        let (url, color) = await Task.detached(priority: .utility) {
            let url = RepositoryIconFinder.icon(in: URL(fileURLWithPath: rootPath))
            return (url, url.flatMap(RepositoryColor.dominant(in:)))
        }.value
        guard repositories.contains(where: { $0.id == id }) else { return }
        repositoryIcons[id] = url.flatMap(RepositoryIconImage.load).map { FoundRepositoryIcon(image: $0, color: color) }
        publishWidgets()
    }

    /// Picks a repository's color by hand; nil goes back to following its icon or name.
    func setColor(_ color: RepositoryColor?, for id: UUID) {
        updateRepository(id) { $0.color = color } saved: { $0.color = color }
    }

    func setHidesIcon(_ hides: Bool, for id: UUID) {
        updateRepository(id) { $0.hidesIcon = hides } saved: { $0.hidesIcon = hides ? true : nil }
    }

    private func updateRepository(_ id: UUID, _ change: (inout RepositoryEntry) -> Void, saved: (inout PersistedRepository) -> Void) {
        if let index = repositories.firstIndex(where: { $0.id == id }) { change(&repositories[index]) }
        if let index = persisted.repositories.firstIndex(where: { $0.id == id }) { saved(&persisted.repositories[index]) }
        persistSoon()
        publishWidgets()
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
        repositoryWatchers.stop(id)
        rediscoverTasks.removeValue(forKey: id)?.cancel()
        worktreeListings.remove(id)
        repositoryIcons[id] = nil
        // Its history goes too, on disk as well as in the feed.
        flushActivity()
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
        guard let git, let rootPath = repositories.first(where: { $0.id == id })?.rootPath else { return }
        let ticket = worktreeListings.begin()
        let list: [WorktreeInfo]
        do {
            list = try await git.worktrees(in: URL(fileURLWithPath: rootPath, isDirectory: true))
                .filter { !$0.isBare && !$0.isPrunable && FileManager.default.fileExists(atPath: $0.path) }
        } catch {
            guard worktreeListings.accepts(ticket, for: id),
                  let index = repositories.firstIndex(where: { $0.id == id }) else { return }
            repositories[index].error = error.localizedDescription
            return
        }
        // While git listed, the repository may have been removed or listed again: look it up anew.
        guard worktreeListings.accepts(ticket, for: id),
              let index = repositories.firstIndex(where: { $0.id == id }) else { return }
        repositories[index].worktrees = list
        repositories[index].error = nil
        let plan = WorktreeReconciliation(listed: list, hidden: hiddenWorktrees,
                                          sessions: sessions.mapValues { $0.repositoryID }, repository: id)
        for path in plan.stop {
            sessions[path]?.stop()
            sessions.removeValue(forKey: path)
        }
        for info in plan.update { sessions[info.path]?.updateInfo(info) }
        for info in plan.create { startSession(for: info, repositoryID: id, git: git) }
        agentHub.setWatchedWorktrees(Array(sessions.keys))
    }

    private func startSession(for info: WorktreeInfo, repositoryID: UUID, git: GitClient) {
        let worktreePath = info.path
        let session = WorktreeSession(
            info: info, repositoryID: repositoryID, settings: settings,
            persisted: persisted.worktreeSettings[info.path] ?? PersistedWorktreeSettings(),
            agents: { [weak self] in self?.agentHub.presence(for: worktreePath)?.writeGateAgents ?? [] },
            onActivity: { [weak self] entries in self?.record(entries) },
            onSettingsChanged: { [weak self] session in
                self?.persisted.worktreeSettings[session.id] = session.persistedSettings
                self?.persistSoon()
            })
        session.attributionProvider = { [weak self] path, date in
            self?.agentHub.attribution(for: worktreePath, path: path, at: date)
        }
        sessions[info.path] = session
        Task { await session.start(git: git) }
    }

    /// The watched worktree that contains `cwd`, longest match first.
    /// The watched worktree a path is in, the innermost when worktrees nest. Every hook event asks
    /// this for several paths, so worktrees' resolved paths are kept, and a path is resolved
    /// (symlinks are disk lookups) only when it does not match as given.
    func worktree(containing path: String) -> String? {
        let keys = Set(sessions.keys)
        if keys != worktreeRoots.keys {
            worktreeRoots = (keys, keys.sorted { $0.count > $1.count }.map { key in
                (key, Array(Set([key, URL(fileURLWithPath: key).resolvingSymlinksInPath().path])))
            })
            resolvedPaths = [:]
        }
        func match(_ candidate: String) -> String? {
            worktreeRoots.roots.first { root in
                root.paths.contains { candidate == $0 || candidate.hasPrefix($0 + "/") }
            }?.key
        }
        if let found = match(path) { return found }
        if resolvedPaths.count > 1000 { resolvedPaths = [:] }
        let resolved = resolvedPaths[path] ?? URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        resolvedPaths[path] = resolved
        return resolved == path ? nil : match(resolved)
    }

    func rediscoverAll() {
        Task {
            for repo in repositories { await rediscoverWorktrees(for: repo.id) }
        }
    }

    /// Watches the repository's common git folder for worktrees coming and going. Removing the
    /// repository stops the watch, or cancels it while it is still starting.
    private func startRepositoryWatcher(id: UUID, rootPath: String) {
        // Loading awaits rediscovery first, and the repository may have been removed meanwhile.
        guard let git, repositories.contains(where: { $0.id == id }) else { return }
        repositoryWatchers.start(id) { [weak self] in
            guard let layout = try? await git.layout(of: URL(fileURLWithPath: rootPath, isDirectory: true)) else { return nil }
            let common = layout.commonDir.standardizedFileURL.path
            let watcher = FSEventsWatcher(paths: [common], exclusions: [common + "/objects", common + "/refs/monitor"], latency: 0.5) { [weak self] events in
                let relevant = events.contains { event in
                    event.path.hasPrefix(common + "/worktrees") || event.rootChanged
                }
                guard relevant else { return }
                Task { @MainActor [weak self] in self?.scheduleRediscovery(for: id) }
            }
            return (try? watcher.start()) != nil ? watcher : nil
        }
    }

    /// Mimamori is quitting: no watch or pending rediscovery starts anything more.
    private func stopWatchingRepositories() {
        repositoryWatchers.stopAll()
        for task in rediscoverTasks.values { task.cancel() }
        rediscoverTasks = [:]
    }

    private func scheduleRediscovery(for id: UUID) {
        // An event from a watch just stopped can still arrive.
        guard !isQuitting, repositories.contains(where: { $0.id == id }) else { return }
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
        if old.showTasksInWidgets != newValue.showTasksInWidgets {
            publishWidgets()
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
        activityFlush?.cancel()
        activityFlush = nil
        pendingActivity = []
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
        // The log is rewritten from the feed: entries still on their way must be in it.
        flushActivity()
        guard activity.contains(where: { $0.date < cutoff }) else { return }
        activity.removeAll { $0.date < cutoff }
        activityLog.replaceAll(with: activity.reversed())
        activityHistoryStart = max(activityHistoryStart, cutoff)
    }

    // MARK: Desktop widgets

    /// Hands the widgets the agents as the Agents window lists them.
    func publishWidgets() {
        widgets.update(widgetAgents())
    }

    /// The agents as the widgets draw them. `details` adds each one's task and latest steps;
    /// the desktop widgets include them only when the settings allow.
    func widgetAgents(details: Bool? = nil) -> [AgentWidgetSnapshot.Agent] {
        let details = details ?? settings.showTasksInWidgets
        return agentRows.map { widgetAgent(for: $0, details: details) }
    }

    /// One of the Agents window's rows as the widgets draw it.
    func widgetAgent(for row: AgentRow, details: Bool) -> AgentWidgetSnapshot.Agent {
        let presence = row.presence
        let steps = details ? presence.turnSteps.suffix(3).reversed().map { step in
            AgentWidgetSnapshot.Step(tool: step.toolName, target: step.summary.map { AgentText.shortenPaths($0, in: row.session.id) },
                                     running: step.finishedAt == nil)
        } : []
        return AgentWidgetSnapshot.Agent(
            worktreePath: row.session.id, repository: row.repositoryName, repositoryColor: row.look?.color, worktree: row.session.displayName,
            agent: presence.kind.displayName, symbol: presence.kind.symbolName, state: presence.widgetState, status: AgentText.shortenPaths(presence.statusText, in: row.session.id),
            since: presence.since, task: details ? presence.task : nil, steps: steps, others: presence.others.count,
            collision: presence.collision?.title)
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
        // record only goes back as far as Mimamori does.
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
            // A request Mimamori can answer has a notification of its own, with Allow and Deny.
            let answerable = note.kind == .needsPermission && agentHub.pendingPermissions.values.contains { $0.worktree == worktree }
            if note.kind == .needsPermission || note.kind == .waiting, settings.notifyOnAgentPermission, !answerable {
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

    /// An agent asks permission and its hook waits for an answer from Mimamori too.
    private func permissionRequested(_ pending: PermissionRequest) {
        guard settings.notifyOnAgentPermission else { return }
        let name = sessions[pending.worktree]?.displayName ?? (pending.worktree as NSString).lastPathComponent
        var body = [pending.detail, name].compactMap { $0 }.joined(separator: " · ")
        if let plan = pending.autoAnswer {
            body += "\n\(plan.allow ? "Allowing" : "Denying") in \(Format.duration(plan.at.timeIntervalSince(pending.since))) unless you answer."
        }
        notifier.askPermission(id: pending.id, title: "\(pending.agent.displayName) asks to use \(pending.tool)", body: body)
    }

    /// Every answer given in Mimamori goes in the feed, so there is a record of what it allowed.
    private func permissionAnswered(_ pending: PermissionRequest, allow: Bool, automatically: Bool) {
        let how = automatically ? "by itself, after \(settings.autoAnswerSeconds) s" : "in Mimamori"
        record([ActivityEntry(worktreePath: pending.worktree, kind: .agentAttention, path: nil,
                              title: "\(allow ? "Allowed" : "Denied") \(how): \(pending.tool)", detail: pending.detail,
                              severity: allow && automatically ? .warning : nil, agent: pending.agent.displayName)])
    }

    private func record(_ entries: [ActivityEntry]) {
        guard !entries.isEmpty else { return }
        pendingActivity.append(contentsOf: entries)
        if activityFlush == nil {
            activityFlush = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.flushActivity()
            }
        }
        activityLog.append(entries)
        if settings.notificationsEnabled, let first = entries.first, let session = sessions[first.worktreePath] {
            notifier.notify(entries: entries, worktreeName: session.displayName, minimumSeverity: settings.notifyMinimumSeverity)
        }
    }

    /// Moves the entries recorded since the last flush into the feed, newest on top.
    private func flushActivity() {
        activityFlush?.cancel()
        activityFlush = nil
        guard !pendingActivity.isEmpty else { return }
        activity.insert(contentsOf: pendingActivity.reversed(), at: 0)
        pendingActivity = []
        if activity.count > activityLog.maxEntries { activity.removeLast(activity.count - activityLog.maxEntries) }
    }

    // MARK: Persistence

    /// The windows whose being open is remembered, so they open again at launch.
    enum RememberedWindow { case agents, overview }

    /// A remembered window opened or closed. Closing because Mimamori quits does not count, so a
    /// window open at quit opens again at launch.
    func windowChanged(_ window: RememberedWindow, open: Bool) {
        guard !isQuitting else { return }
        switch window {
        case .agents:
            guard agentsWindowOpen != open else { return }
            agentsWindowOpen = open
        case .overview:
            guard overviewWindowOpen != open else { return }
            overviewWindowOpen = open
        }
        persistUISoon()
    }

    func persistUISoon() {
        persisted.ui = PersistedUIState(showActivity: showActivity, flaggedOnly: flaggedOnly, sortOrder: sortOrder,
                                        selectedWorktree: selectedWorktreeID, activityScopeAll: activityScopeAll,
                                        hideReviewed: hideReviewed, sidebarAgentsOnly: sidebarAgentsOnly,
                                        activityAgentFilter: activityAgentFilter, showCommits: showCommits,
                                        agentsWindowOpen: agentsWindowOpen, overviewWindowOpen: overviewWindowOpen,
                                        welcomeShown: welcomeShown)
        persistSoon()
    }

    private func persistSoon() {
        saveTask?.cancel()
        guard !isUninstalling else { return }
        let snapshot = persisted
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            Persistence.state.save(snapshot)
        }
    }

    /// The roots of the repositories you watch, as saved: known before they have loaded.
    var repositoryRoots: [String] { persisted.repositories.map(\.path) }

    /// The welcome window was closed: it does not open by itself again.
    func finishWelcome() {
        guard !welcomeShown else { return }
        welcomeShown = true
        persistUISoon()
    }

    func persistNow() {
        guard !isUninstalling else { return }
        persisted.ui = PersistedUIState(showActivity: showActivity, flaggedOnly: flaggedOnly, sortOrder: sortOrder,
                                        selectedWorktree: selectedWorktreeID, activityScopeAll: activityScopeAll,
                                        hideReviewed: hideReviewed, sidebarAgentsOnly: sidebarAgentsOnly,
                                        activityAgentFilter: activityAgentFilter, showCommits: showCommits,
                                        agentsWindowOpen: agentsWindowOpen, overviewWindowOpen: overviewWindowOpen,
                                        welcomeShown: welcomeShown)
        saveTask?.cancel()
        Persistence.state.save(persisted)
    }
}
