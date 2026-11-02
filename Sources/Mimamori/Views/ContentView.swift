import SwiftUI
import MimamoriCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 170, ideal: 220, max: 340)
        } content: {
            if let session = model.selectedSession {
                ChangeListView(session: session)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 340, max: 600)
            } else {
                WelcomeView()
                    .navigationSplitViewColumnWidth(min: 260, ideal: 340, max: 600)
            }
        } detail: {
            detailColumn
                .navigationSplitViewColumnWidth(min: 240, ideal: 420)
                .diffColumnToolbar(activityOpen: model.showActivity)
        }
        .inspector(isPresented: $model.showActivity) {
            ActivityFeedView()
                .inspectorColumnWidth(min: 220, ideal: 260, max: 460)
        }
        .toolbar { toolbarItems }
        .background(ToolbarTooltips(tips: Self.toolbarTips))
        .onChange(of: model.showActivity) { model.persistUISoon() }
        .onChange(of: model.showCommits) { model.persistUISoon() }
        .onChange(of: model.flaggedOnly) { model.persistUISoon() }
        .onChange(of: model.hideReviewed) { model.persistUISoon() }
        .onChange(of: model.sidebarAgentsOnly) { model.persistUISoon() }
        .onChange(of: model.activityAgentFilter) { model.persistUISoon() }
        .onChange(of: model.sortOrder) { model.persistUISoon() }
        .onChange(of: model.selectedWorktreeID) { model.persistUISoon() }
        .frame(minHeight: 480)
        .onAppear {
            if model.debugFlags.contains("agents-window") { openWindow(id: "agents") }
            // "settings:<pane>": open Settings on that pane, as the attention popover's button does.
            if let tab = SettingsTab.allCases.first(where: { model.debugFlags.contains("settings:" + $0.rawValue) }) {
                model.settingsTab = tab
                openSettings()
            }
        }
        // A desktop widget's agent opens its worktree; mimamori://open just brings Mimamori forward.
        .onOpenURL { url in
            if let worktree = AgentWidgetSnapshot.worktree(in: url), model.sessions[worktree] != nil {
                model.select(worktree: worktree)
            }
            NSApplication.shared.activate()
        }
        // Code that is not a view (the debug hooks) asks for a summary through the model.
        .onChange(of: model.summaryWindowRequest) { _, worktree in
            guard let worktree else { return }
            model.summaryWindowRequest = nil
            openWindow.summary(for: worktree)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let session = model.selectedSession {
            VStack(spacing: 0) {
                AgentBannerSlot(worktree: session.id)
                if model.showCommits {
                    commitDetail(session)
                } else if let path = session.selectedPath, let change = session.change(for: path) {
                    DiffView(session: session, change: change)
                } else {
                    ContentUnavailableView("Select a File", systemImage: "doc.text.magnifyingglass",
                                           description: Text("Pick a changed file to read its diff."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func commitDetail(_ session: WorktreeSession) -> some View {
        if let commit = session.openCommit, let selection = session.commitSelection, selection.commitOID == commit.oid {
            if case .file(_, let path) = selection, let change = session.openCommitChanges.first(where: { $0.path == path }) {
                DiffView(session: session, change: change, commit: commit)
            } else {
                CommitOverviewView(session: session, commit: commit)
            }
        } else if session.commitSelection != nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Select a Commit", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                   description: Text("Pick a commit to see what it changed."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Tooltips for the toolbar buttons, by their labels. Kept with `.help` on each button,
    /// which SwiftUI drops for toolbar buttons; `ToolbarTooltips` applies these instead.
    static let toolbarTips: [String: String] = [
        "Add Repository": "Watch another repository or worktree (⌘O)",
        "Agents": "Show every agent at a glance (⇧⌘A)",
        "Activity": "Show the activity feed (⌃⌘I)",
    ]

    /// Window-level items only. The monitor controls live in the change list header,
    /// so the inspector's width never affects their spacing. On macOS 26 the status pill and the
    /// Agents and Activity buttons belong to the diff column and the activity pane instead.
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.promptForRepository()
            } label: {
                Label("Add Repository", systemImage: "plus")
            }
            .help(Self.toolbarTips["Add Repository"]!)
        }
        if !ActivityToolbar.isAvailable {
            AgentStatusPillItem()
            ToolbarItem(placement: .primaryAction) { AgentsToolbarButton() }
            ToolbarItem(placement: .primaryAction) { ActivityToolbarToggle() }
        }
    }
}

#if compiler(>=6.2)
/// The diff column's part of the toolbar on macOS 26, where the columns run up under the toolbar:
/// the status pill towards the trailing end, so it never sits across the line between two
/// columns, then the Agents and Activity buttons while the activity pane is closed (open, the
/// pane holds them, beside its title).
@available(macOS 26, *)
struct DiffColumnToolbar: ToolbarContent {
    let activityOpen: Bool

    var body: some ToolbarContent {
        ToolbarSpacer(.flexible)
        // The pill draws its own tinted capsule, so it leaves off the glass one beneath it.
        ToolbarItem { AgentStatusPill() }
            .sharedBackgroundVisibility(.hidden)
        if !activityOpen {
            ToolbarItem { AgentsToolbarButton() }
            ToolbarItem { ActivityToolbarToggle() }
        }
    }
}
#endif

extension View {
    @ViewBuilder
    fileprivate func diffColumnToolbar(activityOpen: Bool) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            toolbar { DiffColumnToolbar(activityOpen: activityOpen) }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// Opens the Agents window.
struct AgentsToolbarButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "agents")
        } label: {
            Label("Agents", systemImage: "sparkles.rectangle.stack")
        }
        .help(ContentView.toolbarTips["Agents"]!)
    }
}

/// Shows and hides the activity pane.
struct ActivityToolbarToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Toggle(isOn: Binding(get: { model.showActivity }, set: { model.showActivity = $0 })) {
            Label("Activity", systemImage: "list.bullet.rectangle")
        }
        .help(ContentView.toolbarTips["Activity"]!)
    }
}

struct BaselinePicker: View {
    let session: WorktreeSession

    var body: some View {
        Menu {
            Picker("Compare", selection: Binding(get: { session.baseline }, set: { session.setBaseline($0) })) {
                Label("Uncommitted", systemImage: "pencil").tag(Baseline.head)
                Label("Since Branch Point", systemImage: "arrow.triangle.branch").tag(Baseline.branchPoint)
                Label("Since Start", systemImage: "flag").tag(Baseline.start)
                if case .snapshot = session.baseline {
                    Label(currentTitle, systemImage: "camera").tag(session.baseline)
                }
            }
            .pickerStyle(.inline)
            if !session.snapshots.isEmpty {
                Menu("Since Snapshot") {
                    ForEach(session.snapshots.prefix(25)) { snapshot in
                        Button {
                            session.setBaseline(.snapshot(snapshot.id))
                        } label: {
                            Text(snapshotTitle(snapshot))
                        }
                    }
                }
                Divider()
                Button("Take Snapshot Now") { Task { await session.takeSnapshotNow() } }
            }
            if session.startSnapshot != nil {
                Button("Clear Start Marker") { Task { await session.clearStart() } }
            }
        } label: {
            Label(currentTitle, systemImage: "arrow.left.arrow.right")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("What the working tree is compared against")
    }

    var currentTitle: String {
        switch session.baseline {
        case .head: "Uncommitted"
        case .branchPoint: "Since Branch Point"
        case .start: "Since Start"
        case .snapshot(let ref):
            if let snapshot = session.snapshots.first(where: { $0.id == ref }) {
                "Since \(Format.time.string(from: snapshot.date))"
            } else {
                "Since Snapshot"
            }
        }
    }

    private func snapshotTitle(_ snapshot: SnapshotRecord) -> String {
        var title = Format.dateTime.string(from: snapshot.date)
        if snapshot.isStart { title += "  (start)" }
        return title
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "eye")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Mimamori")
                .font(.title2.weight(.semibold))
            Text("Keep watch over repositories while an agent works in them. Add a repository or drop a folder onto the sidebar.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340)
            Button("Add Repository…") { model.promptForRepository() }
                .keyboardShortcut("o")
                .help("Choose a repository or worktree folder to watch (⌘O)")
            if let error = model.gitError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 380)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            model.addRepositories(at: urls)
            return true
        }
    }
}

/// The agent banner for a worktree. Reading the agent hub here, not in the window's body,
/// keeps a busy agent's updates from re-evaluating the whole main window.
private struct AgentBannerSlot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let worktree: String

    var body: some View {
        if let presence = model.agentHub.presence(for: worktree) {
            let session = model.sessions[worktree]
            AgentStatusBanner(presence: presence, now: model.agentNow, details: AgentBannerDetails(
                worktree: worktree,
                files: session.map { model.filesTouched(in: $0, by: presence) } ?? [],
                expanded: model.settings.agentBannerExpanded,
                canGoToAgent: AgentApps.canGo(to: presence),
                onToggle: {
                    var copy = model.settings
                    copy.agentBannerExpanded.toggle()
                    model.updateSettings(copy)
                },
                onOpenFile: { path in session?.selectedPath = path },
                onGoToAgent: { AgentApps.bringForward(presence) },
                onSummary: { openWindow.summary(for: worktree) },
                onDismissCollision: { model.agentHub.dismissCollision(in: worktree) }))
        }
    }
}

/// SwiftUI turns a toolbar `Button` into a native toolbar item and drops its `.help`, leaving
/// it with no tooltip and no accessibility help. This sets the tooltips on those items, by label,
/// once the view is in a window.
private struct ToolbarTooltips: NSViewRepresentable {
    let tips: [String: String]

    final class Applier: NSView {
        var tips: [String: String] = [:]

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSToolbar.willAddItemNotification, object: nil)
            if window != nil {
                // Items come and go as panes open and close (the activity pane takes the Agents
                // and Activity buttons with it), and each new one needs its tip.
                NotificationCenter.default.addObserver(self, selector: #selector(itemWillBeAdded(_:)),
                                                       name: NSToolbar.willAddItemNotification, object: nil)
            }
            apply()
        }

        @objc private func itemWillBeAdded(_ notification: Notification) {
            guard (notification.object as? NSToolbar) === window?.toolbar else { return }
            apply()
        }

        func apply() {
            // The toolbar is built after the window's content; wait a turn for its items.
            DispatchQueue.main.async { [weak self] in
                guard let self, let items = self.window?.toolbar?.items else { return }
                for item in items {
                    if let tip = self.tips[item.label], item.toolTip != tip { item.toolTip = tip }
                }
            }
        }
    }

    func makeNSView(context: Context) -> Applier {
        let view = Applier()
        view.tips = tips
        return view
    }

    func updateNSView(_ view: Applier, context: Context) {
        view.tips = tips
        view.apply()
    }
}
