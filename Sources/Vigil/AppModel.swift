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

    var selectedWorktreeID: String?
    var showActivity: Bool
    var flaggedOnly: Bool
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
        self.flaggedOnly = persisted.ui.flaggedOnly
        self.sortOrder = persisted.ui.sortOrder
        self.activityScopeAll = persisted.ui.activityScopeAll
        self.selectedWorktreeID = persisted.ui.selectedWorktree
        self.collapsedRepositories = persisted.collapsedRepositories
        self.hiddenWorktrees = persisted.hiddenWorktrees
        startTicker()
        DebugHooks.start(model: self)
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
        await locateGit()
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
        persisted.repositories.removeAll { $0.id == id }
        collapsedRepositories.remove(id)
        for worktree in repo.worktrees { hiddenWorktrees.remove(worktree.path) }
        persisted.collapsedRepositories = collapsedRepositories
        persisted.hiddenWorktrees = hiddenWorktrees
        if let selected = selectedWorktreeID, sessions[selected] == nil {
            selectedWorktreeID = orderedSessions.first?.id
        }
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
                    sessions[info.path] = session
                    Task { await session.start(git: git) }
                }
            }
        } catch {
            repositories[index].error = error.localizedDescription
        }
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

    func select(worktree id: String?, path: String? = nil) {
        selectedWorktreeID = id
        if let id, let path, let session = sessions[id] {
            session.selectedPath = path
        }
        persistUISoon()
    }

    func updateSettings(_ newValue: AppSettings) {
        let old = settings
        settings = newValue
        persisted.settings = newValue
        persistSoon()
        for session in sessions.values { session.updateSettings(newValue) }
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

    func clearActivity() { activity.removeAll() }

    private func record(_ entries: [ActivityEntry]) {
        guard !entries.isEmpty else { return }
        activity.insert(contentsOf: entries.reversed(), at: 0)
        if activity.count > 3000 { activity.removeLast(activity.count - 3000) }
        if settings.notificationsEnabled, let first = entries.first, let session = sessions[first.worktreePath] {
            notifier.notify(entries: entries, worktreeName: session.displayName, minimumSeverity: settings.notifyMinimumSeverity)
        }
    }

    // MARK: Persistence

    func persistUISoon() {
        persisted.ui = PersistedUIState(showActivity: showActivity, flaggedOnly: flaggedOnly, sortOrder: sortOrder,
                                        selectedWorktree: selectedWorktreeID, activityScopeAll: activityScopeAll)
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
                                        selectedWorktree: selectedWorktreeID, activityScopeAll: activityScopeAll)
        saveTask?.cancel()
        Persistence.save(persisted)
    }
}
