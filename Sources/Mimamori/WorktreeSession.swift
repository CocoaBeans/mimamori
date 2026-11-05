import Foundation
import Observation
import MimamoriCore

/// What the Commits list has selected: a commit, or one of its files.
enum CommitSelection: Hashable {
    case commit(String)
    case file(commit: String, path: String)

    var commitOID: String {
        switch self {
        case .commit(let oid), .file(let oid, _): oid
        }
    }
}

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
    /// For the debug dump only; no view shows it, so it does not redraw any.
    @ObservationIgnored private(set) var lastRefreshDuration: TimeInterval?
    private(set) var lastActivityDate: Date?
    private(set) var watcherActive = false
    private(set) var attributions: [String: ChangeAttribution] = [:]
    private(set) var reviews: ReviewLedger
    private(set) var notes: ReviewNotes
    var selectedPath: String?
    /// Hunks and files thrown away here, newest first, each with what it takes to put it back. Kept in
    /// memory only; the snapshot taken before each one stays across restarts.
    private(set) var discards: [DiscardedChange] = []
    /// Why putting the latest one back failed.
    private(set) var restoreError: String?
    /// A discard or an Undo you asked for is under way; until it is done, another is turned down.
    private(set) var isWriting = false
    /// The discard waiting for your word, from the diff or the file list.
    var discardRequest: DiscardRequest?

    /// The branch's commits, read when the Commits list first shows and kept current after.
    private(set) var history: CommitHistory?
    private(set) var historyError: String?
    private(set) var loadingHistory = false
    private(set) var commitSelection: CommitSelection?
    /// The commit expanded in the Commits list, with its files and full message.
    private(set) var openCommit: CommitRecord?
    /// Its files, those needing attention first.
    private(set) var openCommitChanges: [FileChange] = []
    private(set) var openCommitMessage: String?
    private(set) var openCommitError: String?
    /// How many of the open commit's files are shown. A commit can touch thousands of files;
    /// showing them a page at a time keeps the list and the overview responsive.
    private(set) var openCommitFileLimit = WorktreeSession.commitFilePage
    static let commitFilePage = 100
    /// Asked for every file event; answers with the agent tool call that caused it, when known.
    var attributionProvider: (@MainActor (String, Date) -> ChangeAttribution?)?

    var settings: AppSettings
    /// The agents in this worktree now, for the `WriteGate`.
    let agents: @MainActor @Sendable () -> [WriteGate.Agent]
    let onActivity: @MainActor ([ActivityEntry]) -> Void
    let onSettingsChanged: @MainActor (WorktreeSession) -> Void

    private var watcher: FSEventsWatcher?
    private var pendingPaths: Set<String> = []
    /// Folders git ignores, as the inspector learned them: changes inside need no refresh.
    private var ignoredFolders: Set<String> = []
    private var pendingGitChange = false
    private var pendingForced = false
    private var pendingQuiet = false
    private var needsRefresh = false
    private var isRefreshing = false
    private var firstPendingAt: Date?
    private var startTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastSnapshotAt: Date?
    private var stopped = false
    /// Files Mimamori itself just wrote, by when: the file event that follows already has an entry.
    @ObservationIgnored private var ownWrites: [String: Date] = [:]
    /// A file put back by Undo, to select once it is listed again, as it was before its discard.
    @ObservationIgnored private var reselectPath: String?
    private static let discardLimit = 20

    init(info: WorktreeInfo, repositoryID: UUID, settings: AppSettings, persisted: PersistedWorktreeSettings,
         agents: @escaping @MainActor @Sendable () -> [WriteGate.Agent],
         onActivity: @escaping @MainActor ([ActivityEntry]) -> Void,
         onSettingsChanged: @escaping @MainActor (WorktreeSession) -> Void) {
        self.id = info.path
        self.info = info
        self.repositoryID = repositoryID
        self.settings = settings
        self.baseline = persisted.baseline
        self.scopePrefixes = persisted.scopePrefixes
        self.reviews = persisted.reviews
        self.notes = persisted.notes
        self.agents = agents
        self.onActivity = onActivity
        self.onSettingsChanged = onSettingsChanged
    }

    /// The branch; mid-rebase, when HEAD is detached, the branch being rebased.
    var displayName: String { info.branch ?? state?.operation?.branch ?? (info.isDetached ? "detached" : info.name) }
    var startSnapshot: SnapshotRecord? { snapshots.first { $0.isStart } }
    var flaggedCount: Int { changes.flaggedCount }
    var isBusy: Bool { phase == .refreshing || phase == .indexing || phase == .starting }
    var persistedSettings: PersistedWorktreeSettings {
        PersistedWorktreeSettings(baseline: baseline, scopePrefixes: scopePrefixes, reviews: reviews, notes: notes)
    }

    func change(for path: String) -> FileChange? { changesByPath[path] }

    // MARK: Review

    /// Marks older than this are forgotten once their file no longer differs from the baseline.
    private static let reviewRetention: TimeInterval = 30 * 86400

    var reviewedCount: Int { changes.reviewedCount(in: reviews) }
    var unreviewedCount: Int { changes.count - reviewedCount }

    func reviewStatus(of change: FileChange) -> ReviewStatus { reviews.status(of: change) }

    func setReviewed(_ reviewed: Bool, paths: [String]) {
        let now = Date()
        for path in paths {
            if reviewed {
                if let change = changesByPath[path] { reviews.markReviewed(change, at: now) }
            } else {
                reviews.clear(path)
            }
        }
        onSettingsChanged(self)
    }

    func markAllReviewed() {
        setReviewed(true, paths: changes.map(\.path))
    }

    func clearAllReviews() {
        guard !reviews.isEmpty else { return }
        reviews.clearAll()
        onSettingsChanged(self)
    }

    // MARK: Notes

    /// Resolved notes are forgotten after this long.
    private static let resolvedNoteRetention: TimeInterval = 7 * 86400

    /// Leaves a note on `lines` of `path` (nil: the whole file), quoting them as they read now.
    func addNote(path: String, side: ReviewNote.Side, lines: ClosedRange<Int>?, quote: [String], text: String) {
        notes.add(ReviewNote(path: path, side: side, lines: lines, quote: quote, text: text,
                             blob: changesByPath[path]?.newOID))
        onSettingsChanged(self)
    }

    func editNote(_ id: UUID, text: String) {
        notes.edit(id, text: text)
        onSettingsChanged(self)
    }

    func deleteNote(_ id: UUID) {
        notes.delete(id)
        onSettingsChanged(self)
    }

    func setNoteResolved(_ id: UUID, _ resolved: Bool) {
        if resolved { notes.resolve(id) } else { notes.reopen(id) }
        onSettingsChanged(self)
    }

    /// Records that `ids` were handed over, to `agent` or (nil) copied.
    func markNotesSent(_ ids: [UUID], to agent: String?) {
        let blobs = changesByPath.compactMapValues(\.newOID)
        notes.markSent(ids, to: agent, blobs: blobs)
        onSettingsChanged(self)
    }

    /// Moves the notes on a file to where their lines are in its diff now; only a working-tree
    /// diff against the baseline will do, since notes on removed lines count lines there.
    func reanchorNotes(in diff: FileDiff, for change: FileChange) {
        guard notes.reanchor(path: change.path, in: diff, blob: change.newOID) else { return }
        onSettingsChanged(self)
    }

    // MARK: Lifecycle

    /// Starts watching, and returns once started. A `stop()` before or during it wins: a stopped
    /// session never starts, since it is never used again.
    func start(git: GitClient) async {
        guard !stopped, startTask == nil else { return }
        let task = Task { await self.load(git: git) }
        startTask = task
        await task.value
    }

    private func load(git: GitClient) async {
        phase = .starting
        guard FileManager.default.fileExists(atPath: id) else {
            phase = .missing
            lastError = "The worktree folder no longer exists."
            return
        }
        let agents = agents
        do {
            let inspector = try await WorktreeInspector(
                git: git, worktree: URL(fileURLWithPath: id, isDirectory: true),
                shadowIndexDirectory: Persistence.shadowIndexDirectory,
                configuration: inspectorConfiguration,
                agents: { await agents() })
            guard !stopped else { return }
            self.inspector = inspector
            let snapshots = await inspector.snapshots()
            guard !stopped else { return }
            self.snapshots = snapshots
            startWatching(layout: inspector.layout)
            startSafetyPolling()
            requestRefresh(force: true)
        } catch {
            guard !stopped else { return }
            phase = .failed
            lastError = error.localizedDescription
        }
    }

    func stop() {
        stopped = true
        startTask?.cancel()
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
        if previous.backstopPollSeconds != settings.backstopPollSeconds {
            startSafetyPolling()
        }
        // Off means Mimamori writes nothing, Undo included.
        if previous.allowsDiscardingChanges, !settings.allowsDiscardingChanges { forgetDiscards() }
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
        guard !stopped else { return }
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
        var rulesChanged = false

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
                if relative == "info/exclude" { rulesChanged = true }
                if Self.interestingGitFiles.contains(relative)
                    || relative.hasPrefix("refs/heads/") || relative.hasPrefix("refs/remotes/")
                    || relative.hasPrefix("refs/tags/") || relative == "refs/stash" || relative.hasPrefix("rebase-") {
                    touchedGit = true
                }
                continue
            }
            if let relative = relativePath(path, under: topLevel) {
                if relative == ".git" || relative.hasPrefix(".git/") { continue }
                // A build in an ignored folder sends thousands of these; none needs git. Nor does a
                // .gitignore in there (node_modules is full of them): git never reads it.
                if WorktreeInspector.isInside(relative, ignoredFolders) { continue }
                if relative == ".gitignore" || relative.hasSuffix("/.gitignore") { rulesChanged = true }
                if pendingPaths.count < 2000 { pendingPaths.insert(relative) } else { forced = true }
                touchedWorktree = true
            }
        }

        if rulesChanged, !ignoredFolders.isEmpty {
            ignoredFolders = []
            Task { await inspector?.forgetIgnoredFolders() }
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
        let interval = watcherActive ? settings.backstopPollSeconds : 3
        guard !stopped, interval > 0 else { return }
        // Stagger sessions so a safety sweep never lights up every row at once.
        let initialDelay = Double.random(in: 0...interval)
        pollTask = Task { [weak self] in
            var delay = initialDelay
            while true {
                try? await Task.sleep(for: .seconds(delay))
                // Bound after the sleep, so a sleeping poll doesn't keep the session alive.
                guard !Task.isCancelled, let self else { return }
                // With a live watcher the poll is only a backstop: refresh without the spinner.
                self.requestRefresh(force: !self.watcherActive, quiet: self.watcherActive)
                delay = interval
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
        // One loop at a time: it picks up whatever is asked for while it runs.
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

            if !forced, !gitChanged, !paths.isEmpty, let inspector {
                let skip = await inspector.allIgnored(Array(paths))
                ignoredFolders = await inspector.ignoredFolders
                if skip { continue }
            }
            await performRefresh(quiet: quiet)
        }
    }

    private func performRefresh(quiet: Bool = false) async {
        guard let inspector else { return }
        let started = Date()
        // A spinner redraws the screen for as long as it shows, and most refreshes are done
        // before it would tell you anything: show it only for one that is taking a while.
        var showBusy: Task<Void, Never>? = nil
        if state == nil {
            phase = .indexing
        } else if !quiet {
            showBusy = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                self?.phase = .refreshing
            }
        }
        do {
            let previous = state
            let fresh: WorktreeState
            do {
                fresh = try await inspector.refresh(baseline: baseline)
                showBusy?.cancel()
            } catch {
                showBusy?.cancel()
                throw error
            }
            // Stopped meanwhile: nothing more is recorded or snapshotted for this worktree.
            guard !stopped else { return }
            var commits: [CommitSummary] = []
            if let previous, previous.branch.headOID != fresh.branch.headOID {
                commits = await inspector.commits(from: previous.branch.headOID, to: fresh.branch.headOID)
            }
            let events = StateDiffer.events(previous: previous, current: fresh, worktreePath: id, commits: commits)
            apply(fresh, events: events)
            if phase != .idle { phase = .idle }
            if lastError != nil { lastError = nil }
            if history != nil, history?.head != fresh.branch.headOID { await reloadHistory() }
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

    private func apply(_ fresh: WorktreeState, events incoming: [ActivityEntry]) {
        // Setting an observed property redraws every view showing it, even to the value it had,
        // and most refreshes (a backstop poll, an agent touching a file back) find nothing new.
        if state.map({ !$0.sameContent(as: fresh) }) ?? true { state = fresh }
        var byPath: [String: FileChange] = [:]
        for change in fresh.changes { byPath[change.path] = change }
        if changes != fresh.changes {
            changes = fresh.changes
            changesByPath = byPath
        }

        let now = Date()
        var events = incoming
        if !ownWrites.isEmpty { ownWrites = ownWrites.filter { now.timeIntervalSince($0.value) < 10 } }
        var ownEvents = Set<Int>()
        for index in events.indices {
            guard let path = events[index].path else { continue }
            // A discard in Mimamori has its own entry, and no agent made it.
            if events[index].kind.isFileChange, ownWrites.removeValue(forKey: path) != nil {
                lastChanged[path] = now
                ownEvents.insert(index)
                continue
            }
            switch events[index].kind {
            case .created, .modified, .deleted, .renamed:
                lastChanged[path] = now
                if let attribution = attributionProvider?(path, now) {
                    attributions[path] = attribution
                    events[index].agent = attribution.agent
                    let suffix = "by \(attribution.label)"
                    events[index].detail = events[index].detail.map { "\($0) · \(suffix)" } ?? suffix
                }
                if let change = byPath[path], case .changedSinceReview = reviews.status(of: change) {
                    let suffix = "changed since your review"
                    events[index].detail = events[index].detail.map { "\($0) · \(suffix)" } ?? suffix
                }
            default: break
            }
        }
        if !ownEvents.isEmpty { events = events.indices.filter { !ownEvents.contains($0) }.map { events[$0] } }
        let kept = attributions.filter { byPath[$0.key] != nil }
        if kept.count != attributions.count { attributions = kept }
        // An unavailable baseline lists nothing, which says nothing about what is still changed.
        if fresh.baseline.isAvailable, !reviews.isEmpty,
           reviews.prune(keepingPaths: Set(byPath.keys), olderThan: now.addingTimeInterval(-Self.reviewRetention)) {
            onSettingsChanged(self)
        }
        if !notes.isEmpty, notes.prune(resolvedBefore: now.addingTimeInterval(-Self.resolvedNoteRetention)) {
            onSettingsChanged(self)
        }
        if lastChanged.count > 5000 {
            let cutoff = now.addingTimeInterval(-settings.recencyWindowSeconds * 4)
            lastChanged = lastChanged.filter { $0.value > cutoff }
        }
        if let selectedPath, byPath[selectedPath] == nil {
            self.selectedPath = nil
        }
        if let reselectPath, byPath[reselectPath] != nil {
            if selectedPath == nil { selectedPath = reselectPath }
            self.reselectPath = nil
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

    /// Disk space only this worktree's snapshots use; nil when git cannot say.
    func snapshotDiskUsage() async -> Int64? {
        if snapshots.isEmpty { return 0 }
        return await inspector?.snapshotDiskUsage()
    }

    func deleteAllSnapshots() async {
        guard let inspector else { return }
        await inspector.deleteAllSnapshots()
        snapshots = []
        if case .snapshot = baseline { setBaseline(.head) }
        if baseline == .start { setBaseline(.head) }
    }

    // MARK: Discarding changes

    /// Whether this worktree offers Discard for hunks and files: when it is on in Settings, for
    /// uncommitted work compared with HEAD, and not in the middle of a merge, rebase or the like.
    var offersDiscarding: Bool {
        guard settings.allowsDiscardingChanges, baseline == .head, let state else { return false }
        return state.baseline.baseline == .head && state.baseline.isAvailable && state.operation == nil
    }

    /// Whether the agents here let Mimamori write now, for the views to show. The inspector asks
    /// again before each write, and refuses one while an agent is mid-turn.
    var writeGate: WriteGate { WriteGate(agents()) }

    /// Throws away one hunk of `change`, the version of the file its diff was made from, after a
    /// snapshot.
    func discard(_ hunk: DiffHunk, of change: FileChange) async throws {
        let inspector = try discardingInspector()
        defer { requestRefresh(force: true) }
        let discarded = try await writing { try await inspector.discard(hunk, of: change) }
        // Where the hunk's first changed line was, not its context.
        let first = hunk.lines.first { $0.kind == .addition || $0.kind == .deletion }
        let line = first?.newNumber ?? first?.oldNumber ?? hunk.newStart
        recordDiscard(discarded, detail: "hunk at line \(line) discarded · snapshot taken first")
    }

    /// Puts all of `change` back as HEAD has it, after a snapshot: a new file goes to the Trash,
    /// a deleted one comes back.
    func discardFile(_ change: FileChange) async throws {
        let inspector = try discardingInspector()
        defer { requestRefresh(force: true) }
        let discarded = try await writing { try await inspector.discardFile(change) }
        let detail = switch change.kind {
        case .added: "new file moved to the Trash · snapshot taken first"
        case .deleted: "deleted file brought back · snapshot taken first"
        default: "all changes discarded · snapshot taken first"
        }
        recordDiscard(discarded, detail: detail)
    }

    /// Puts the latest discard back, after a snapshot.
    func restoreLatestDiscard() async {
        guard let latest = discards.first, let inspector, !isWriting else { return }
        defer { requestRefresh(force: true) }
        do {
            let restored = try await writing { try await inspector.restore(latest) }
            recordWrite(of: latest.path, snapshot: restored.snapshot)
            discards.removeAll { $0.id == latest.id }
            reselectPath = latest.path
            restoreError = nil
            let what = if case .hunk = latest.scope { "discarded hunk" } else { "discarded file" }
            onActivity([ActivityEntry(worktreePath: id, kind: .discarded, path: latest.path, title: latest.path,
                                      detail: restored.exact ? "\(what) put back" : "\(what) put back where its lines still fit")])
        } catch HunkDiscardError.refused {
            // Not a failure: Undo waits for the turn to end, and the bar says so meanwhile.
        } catch {
            restoreError = error.localizedDescription
        }
    }

    private func discardingInspector() throws -> WorktreeInspector {
        guard offersDiscarding, let inspector else {
            throw HunkDiscardError.unsupported("Changes can be discarded only from Uncommitted, with discarding on in Settings.")
        }
        guard !isWriting else { throw HunkDiscardError.unsupported("Another discard or Undo is under way. Try again in a moment.") }
        return inspector
    }

    private func recordDiscard(_ discarded: DiscardedChange, detail: String) {
        recordWrite(of: discarded.path, snapshot: discarded.snapshot)
        discards.insert(discarded, at: 0)
        if discards.count > Self.discardLimit { discards.removeLast(discards.count - Self.discardLimit) }
        restoreError = nil
        onActivity([ActivityEntry(worktreePath: id, kind: .discarded, path: discarded.path, title: discarded.path,
                                  detail: detail)])
    }

    /// Forgets the discards, so there is nothing to undo; their snapshots stay.
    func forgetDiscards() {
        discards = []
        restoreError = nil
    }

    /// Runs a discard or an Undo, shown as under way until it is done. The inspector queues it
    /// behind any refresh or snapshot already running.
    private func writing<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        isWriting = true
        defer { isWriting = false }
        return try await operation()
    }

    private func recordWrite(of path: String, snapshot: SnapshotRecord) {
        ownWrites[path] = Date()
        snapshots.insert(snapshot, at: 0)
        lastSnapshotAt = snapshot.date
    }

    // MARK: Diffs

    func diff(for change: FileChange) async throws -> FileDiff? {
        guard let inspector, let base = state?.baseline.treeish else { return nil }
        return try await inspector.diff(for: change, base: base)
    }

    // MARK: Commits

    /// Reads the history when the Commits list shows and has none, or HEAD has moved since.
    func loadHistoryIfNeeded() {
        guard let state, !loadingHistory, history == nil || history?.head != state.branch.headOID else { return }
        Task { await reloadHistory() }
    }

    func reloadHistory() async {
        guard let inspector, let branch = state?.branch, !loadingHistory else { return }
        loadingHistory = true
        defer { loadingHistory = false }
        do {
            history = try await inspector.history(branch: branch)
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
    }

    func loadMoreHistory() async {
        guard let inspector, let history, history.hasMore, !loadingHistory else { return }
        loadingHistory = true
        defer { loadingHistory = false }
        if let more = try? await inspector.loadingMore(of: history), self.history?.head == history.head {
            self.history = more
        }
    }

    /// Selects a commit or one of its files, opening the commit when it is not open yet.
    func select(_ selection: CommitSelection?) {
        commitSelection = selection
        guard let oid = selection?.commitOID, openCommit?.oid != oid else { return }
        Task {
            if let commit = history?.commit(oid) {
                await open(commit)
            } else {
                await openCommit(revision: oid)
            }
        }
    }

    /// Opens and selects a commit named any way git accepts, such as the short id in the activity
    /// feed. It need not be in the loaded history.
    func openCommit(revision: String) async {
        var commit = history?.all.first { $0.oid.hasPrefix(revision) }
        if commit == nil { commit = await inspector?.commit(revision) }
        guard let commit else { return }
        commitSelection = .commit(commit.oid)
        if openCommit?.oid != commit.oid { await open(commit) }
    }

    private func open(_ commit: CommitRecord) async {
        guard let inspector else { return }
        openCommit = commit
        openCommitChanges = []
        openCommitMessage = nil
        openCommitError = nil
        openCommitFileLimit = Self.commitFilePage
        async let message = inspector.message(of: commit)
        do {
            let changes = try await inspector.changes(in: commit)
            guard openCommit?.oid == commit.oid else { return }
            openCommitChanges = changes.filter(\.isFlagged) + changes.filter { !$0.isFlagged }
        } catch {
            guard openCommit?.oid == commit.oid else { return }
            openCommitError = error.localizedDescription
        }
        let text = await message
        guard openCommit?.oid == commit.oid else { return }
        openCommitMessage = text
    }

    /// The open commit's files as the list and overview show them.
    var shownCommitChanges: ArraySlice<FileChange> { openCommitChanges.prefix(openCommitFileLimit) }
    var hiddenCommitChangeCount: Int { max(0, openCommitChanges.count - openCommitFileLimit) }

    /// Shows twice as many of the open commit's files, so even a huge commit takes few clicks.
    func showMoreCommitFiles() {
        openCommitFileLimit *= 2
    }

    func diff(for change: FileChange, in commit: CommitRecord) async throws -> FileDiff? {
        guard let inspector else { return nil }
        return try await inspector.diff(for: change, in: commit)
    }

    func commitsSinceBaseline() async -> [CommitSummary] {
        guard let inspector, let state else { return [] }
        return await inspector.commits(since: state)
    }

    func diffSinceReview(for change: FileChange, reviewedBlob: String) async throws -> FileDiff? {
        guard let inspector else { return nil }
        return try await inspector.diffSinceReview(for: change, reviewedBlob: reviewedBlob)
    }
}

extension AgentPresence {
    /// This agent and the others in its worktree, as the `WriteGate` takes them.
    var writeGateAgents: [WriteGate.Agent] {
        ([self] + others).map { agent in
            WriteGate.Agent(name: agent.kind.displayName, source: agent.source == .hooks ? .hooks : .process,
                            activity: agent.activity)
        }
    }
}
