import Foundation
import Observation
import VigilCore

/// Live state for one watched worktree: owns the inspector, the file-system
/// watcher, the debounce logic and the most recent refresh result.
@MainActor
@Observable
final class WorktreeSession: Identifiable {
    enum Phase: Equatable {
        case starting, indexing, idle, refreshing, failed, missing
    }

    nonisolated let id: String
    let repositoryID: UUID
    private(set) var info: WorktreeInfo
    private(set) var inspector: WorktreeInspector?

    private(set) var baseline: Baseline
    private(set) var scopePrefixes: [String]
    private(set) var state: WorktreeState?
    private(set) var changes: [FileChange] = []
    private(set) var changesByPath: [String: FileChange] = [:]
    private(set) var lastChanged: [String: Date] = [:]
    private(set) var phase: Phase = .starting
    private(set) var lastError: String?
    private(set) var snapshots: [SnapshotRecord] = []
    private(set) var lastRefreshDuration: TimeInterval?
    private(set) var lastActivityDate: Date?
    private(set) var watcherActive = false
    var selectedPath: String?

    var settings: AppSettings
    let onActivity: @MainActor ([ActivityEntry]) -> Void
    let onSettingsChanged: @MainActor (WorktreeSession) -> Void

    private var watcher: FSEventsWatcher?
    private var pendingPaths: Set<String> = []
    private var pendingGitChange = false
    private var pendingForced = false
    private var pendingQuiet = false
    private var needsRefresh = false
    private var isRefreshing = false
    private var firstPendingAt: Date?
    private var debounceTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastSnapshotAt: Date?
    private var stopped = false

    init(info: WorktreeInfo, repositoryID: UUID, settings: AppSettings, persisted: PersistedWorktreeSettings,
         onActivity: @escaping @MainActor ([ActivityEntry]) -> Void,
         onSettingsChanged: @escaping @MainActor (WorktreeSession) -> Void) {
        self.id = info.path
        self.info = info
        self.repositoryID = repositoryID
        self.settings = settings
        self.baseline = persisted.baseline
        self.scopePrefixes = persisted.scopePrefixes
        self.onActivity = onActivity
        self.onSettingsChanged = onSettingsChanged
    }

    var displayName: String { info.branch ?? (info.isDetached ? "detached" : info.name) }
    var startSnapshot: SnapshotRecord? { snapshots.first { $0.isStart } }
    var flaggedCount: Int { changes.flaggedCount }
    var isBusy: Bool { phase == .refreshing || phase == .indexing || phase == .starting }
    var persistedSettings: PersistedWorktreeSettings {
        PersistedWorktreeSettings(baseline: baseline, scopePrefixes: scopePrefixes)
    }

    func change(for path: String) -> FileChange? { changesByPath[path] }

    // MARK: Lifecycle

    func start(git: GitClient) async {
        stopped = false
        phase = .starting
        guard FileManager.default.fileExists(atPath: id) else {
            phase = .missing
            lastError = "The worktree folder no longer exists."
            return
        }
        do {
            let inspector = try await WorktreeInspector(
                git: git, worktree: URL(fileURLWithPath: id, isDirectory: true),
                shadowIndexDirectory: Persistence.shadowIndexDirectory,
                configuration: inspectorConfiguration)
            self.inspector = inspector
            snapshots = await inspector.snapshots()
            startWatching(layout: inspector.layout)
            startSafetyPolling()
            requestRefresh(force: true)
        } catch {
            phase = .failed
            lastError = error.localizedDescription
        }
    }

    func stop() {
        stopped = true
        watcher?.stop()
        watcher = nil
        watcherActive = false
        debounceTask?.cancel()
        pollTask?.cancel()
    }

    func updateInfo(_ info: WorktreeInfo) {
        self.info = info
    }

    func updateSettings(_ settings: AppSettings) {
        let previous = self.settings
        self.settings = settings
        if previous.inspector != settings.inspector {
            Task { await inspector?.setConfiguration(inspectorConfiguration) }
            requestRefresh(force: true)
        }
        if previous.safetyPollSeconds != settings.safetyPollSeconds {
            startSafetyPolling()
        }
    }

    func setBaseline(_ baseline: Baseline) {
        guard baseline != self.baseline else { return }
        self.baseline = baseline
        onSettingsChanged(self)
        requestRefresh(force: true)
    }

    func setScopePrefixes(_ prefixes: [String]) {
        scopePrefixes = prefixes
        onSettingsChanged(self)
        Task { await inspector?.setConfiguration(inspectorConfiguration) }
        requestRefresh(force: true)
    }

    private var inspectorConfiguration: InspectorConfiguration {
        var configuration = settings.inspector
        configuration.rules.scopePrefixes = scopePrefixes
        return configuration
    }

    // MARK: Watching

    private func startWatching(layout: RepoLayout) {
        watcher?.stop()
        var paths = [layout.topLevel.path]
        let gitDir = layout.gitDir.standardizedFileURL.path
        let commonDir = layout.commonDir.standardizedFileURL.path
        if !gitDir.hasPrefix(layout.topLevel.path + "/") { paths.append(gitDir) }
        if commonDir != gitDir, !commonDir.hasPrefix(layout.topLevel.path + "/") { paths.append(commonDir) }
        let exclusions = [
            commonDir + "/objects",
            commonDir + "/refs/monitor",
            commonDir + "/logs",
            commonDir + "/lfs",
        ]
        let watcher = FSEventsWatcher(paths: paths, exclusions: exclusions, latency: 0.2) { [weak self] events in
            Task { @MainActor [weak self] in
                self?.handle(events: events, topLevel: layout.topLevel.path, gitDir: gitDir, commonDir: commonDir)
            }
        }
        do {
            try watcher.start()
            self.watcher = watcher
            watcherActive = true
        } catch {
            watcherActive = false
            lastError = "File watching unavailable (\(error.localizedDescription)); polling instead."
        }
    }

    private static let interestingGitFiles: Set<String> = [
        "HEAD", "ORIG_HEAD", "MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD", "FETCH_HEAD", "index", "packed-refs",
    ]

    private func handle(events: [FSEvent], topLevel: String, gitDir: String, commonDir: String) {
        guard !stopped else { return }
        var touchedWorktree = false
        var touchedGit = false
        var forced = false

        for event in events {
            if event.rootChanged {
                if !FileManager.default.fileExists(atPath: id) {
                    phase = .missing
                    lastError = "The worktree folder was removed."
                    return
                }
                forced = true
                continue
            }
            if event.mustScanSubDirs { forced = true }
            let path = event.path
            if path.hasSuffix(".lock") { continue }

            if let relative = relativePath(path, under: gitDir) ?? relativePath(path, under: commonDir) {
                if Self.interestingGitFiles.contains(relative)
                    || relative.hasPrefix("refs/heads/") || relative.hasPrefix("refs/remotes/")
                    || relative.hasPrefix("refs/tags/") || relative == "refs/stash" || relative.hasPrefix("rebase-") {
                    touchedGit = true
                }
                continue
            }
            if let relative = relativePath(path, under: topLevel) {
                if relative == ".git" || relative.hasPrefix(".git/") { continue }
                if pendingPaths.count < 2000 { pendingPaths.insert(relative) } else { forced = true }
                touchedWorktree = true
            }
        }

        guard touchedWorktree || touchedGit || forced else { return }
        if touchedGit { pendingGitChange = true }
        if forced { pendingForced = true }
        pendingQuiet = false
        scheduleRefresh()
    }

    private func relativePath(_ path: String, under directory: String) -> String? {
        if path == directory { return "" }
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private func startSafetyPolling() {
        pollTask?.cancel()
        let interval = watcherActive ? settings.safetyPollSeconds : 3
        guard interval > 0 else { return }
        // Stagger sessions so a safety sweep never lights up every row at once.
        let initialDelay = Double.random(in: 0...interval)
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(initialDelay))
            while !Task.isCancelled {
                guard let self else { return }
                // With a live watcher the poll is only a backstop: refresh without the spinner.
                self.requestRefresh(force: !self.watcherActive, quiet: self.watcherActive)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    // MARK: Refresh scheduling

    /// `quiet` refreshes update the data without showing the busy indicator.
    func requestRefresh(force: Bool = false, quiet: Bool = false) {
        guard !stopped, inspector != nil else { return }
        if force { pendingForced = true }
        pendingQuiet = pendingQuiet && quiet || (quiet && !needsRefresh)
        scheduleRefresh(immediate: force)
    }

    private func scheduleRefresh(immediate: Bool = false) {
        needsRefresh = true
        if firstPendingAt == nil { firstPendingAt = Date() }
        debounceTask?.cancel()
        let debounce = immediate ? 0 : Double(settings.refreshDebounceMilliseconds) / 1000
        let deadline = (firstPendingAt ?? Date()).addingTimeInterval(settings.maxRefreshLatencySeconds)
        let wait = max(0, min(debounce, deadline.timeIntervalSinceNow))
        debounceTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self else { return }
            await self.runRefreshLoop()
        }
    }

    private func runRefreshLoop() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        while needsRefresh, !stopped {
            needsRefresh = false
            firstPendingAt = nil
            let paths = pendingPaths
            let gitChanged = pendingGitChange
            let forced = pendingForced
            let quiet = pendingQuiet
            pendingPaths = []
            pendingGitChange = false
            pendingForced = false
            pendingQuiet = false

            if !forced, !gitChanged, !paths.isEmpty, let inspector, await inspector.allIgnored(Array(paths)) {
                continue
            }
            await performRefresh(quiet: quiet)
        }
    }

    private func performRefresh(quiet: Bool = false) async {
        guard let inspector else { return }
        let started = Date()
        if state == nil {
            phase = .indexing
        } else if !quiet {
            phase = .refreshing
        }
        do {
            let previous = state
            let fresh = try await inspector.refresh(baseline: baseline)
            var commits: [CommitSummary] = []
            if let previous, previous.branch.headOID != fresh.branch.headOID {
                commits = await inspector.commits(from: previous.branch.headOID, to: fresh.branch.headOID)
            }
            let events = StateDiffer.events(previous: previous, current: fresh, worktreePath: id, commits: commits)
            apply(fresh, events: events)
            phase = .idle
            lastError = nil
            await snapshotIfNeeded(fresh)
        } catch {
            if FileManager.default.fileExists(atPath: id) {
                phase = .failed
                lastError = error.localizedDescription
            } else {
                phase = .missing
                lastError = "The worktree folder no longer exists."
            }
        }
        lastRefreshDuration = Date().timeIntervalSince(started)
    }

    private func apply(_ fresh: WorktreeState, events: [ActivityEntry]) {
        state = fresh
        changes = fresh.changes
        var byPath: [String: FileChange] = [:]
        for change in fresh.changes { byPath[change.path] = change }
        changesByPath = byPath

        let now = Date()
        for event in events {
            guard let path = event.path else { continue }
            switch event.kind {
            case .created, .modified, .deleted, .renamed: lastChanged[path] = now
            default: break
            }
        }
        if lastChanged.count > 5000 {
            let cutoff = now.addingTimeInterval(-settings.recencyWindowSeconds * 4)
            lastChanged = lastChanged.filter { $0.value > cutoff }
        }
        if let selectedPath, byPath[selectedPath] == nil {
            self.selectedPath = nil
        }
        if !events.isEmpty {
            lastActivityDate = now
            onActivity(events)
        }
    }

    // MARK: Snapshots

    private func snapshotIfNeeded(_ fresh: WorktreeState) async {
        guard settings.snapshotsEnabled, let inspector, let tree = fresh.shadowTreeOID else { return }
        if let latest = snapshots.first, latest.treeOID == tree { return }
        if let lastSnapshotAt, Date().timeIntervalSince(lastSnapshotAt) < settings.snapshotMinimumIntervalSeconds { return }
        do {
            if let record = try await inspector.takeSnapshot() {
                snapshots.insert(record, at: 0)
                lastSnapshotAt = record.date
                if snapshots.count > settings.maxSnapshotsPerWorktree {
                    await inspector.pruneSnapshots(keep: settings.maxSnapshotsPerWorktree)
                    snapshots = await inspector.snapshots()
                }
            }
        } catch {
            lastError = "Snapshot failed: \(error.localizedDescription)"
        }
    }

    func markStart() async {
        guard let inspector else { return }
        do {
            let record = try await inspector.takeSnapshot(markStart: true)
            snapshots = await inspector.snapshots()
            lastSnapshotAt = record?.date
            onActivity([ActivityEntry(worktreePath: id, kind: .started, title: "Start marker set",
                                      detail: info.branch)])
            if baseline != .start { setBaseline(.start) } else { requestRefresh(force: true) }
        } catch {
            lastError = "Could not set the start marker: \(error.localizedDescription)"
        }
    }

    func clearStart() async {
        guard let inspector else { return }
        try? await inspector.clearStartMarker()
        snapshots = await inspector.snapshots()
        if baseline == .start { setBaseline(.head) } else { requestRefresh(force: true) }
    }

    func takeSnapshotNow() async {
        guard let inspector else { return }
        do {
            if let record = try await inspector.takeSnapshot(force: true) {
                snapshots.insert(record, at: 0)
                lastSnapshotAt = record.date
                onActivity([ActivityEntry(worktreePath: id, kind: .snapshot, title: "Snapshot taken")])
            }
        } catch {
            lastError = "Snapshot failed: \(error.localizedDescription)"
        }
    }

    func deleteAllSnapshots() async {
        guard let inspector else { return }
        await inspector.deleteAllSnapshots()
        snapshots = []
        if case .snapshot = baseline { setBaseline(.head) }
        if baseline == .start { setBaseline(.head) }
    }

    // MARK: Diffs

    func diff(for change: FileChange) async throws -> FileDiff? {
        guard let inspector, let base = state?.baseline.treeish else { return nil }
        return try await inspector.diff(for: change, base: base)
    }
}
