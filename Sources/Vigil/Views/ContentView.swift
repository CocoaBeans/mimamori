import SwiftUI
import VigilCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

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
        }
        .inspector(isPresented: $model.showActivity) {
            ActivityFeedView()
                .inspectorColumnWidth(min: 220, ideal: 260, max: 460)
        }
        .toolbar { toolbarItems }
        .onChange(of: model.showActivity) { model.persistUISoon() }
        .onChange(of: model.flaggedOnly) { model.persistUISoon() }
        .onChange(of: model.hideReviewed) { model.persistUISoon() }
        .onChange(of: model.sortOrder) { model.persistUISoon() }
        .onChange(of: model.selectedWorktreeID) { model.persistUISoon() }
        .frame(minHeight: 480)
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let session = model.selectedSession {
            VStack(spacing: 0) {
                if let presence = model.agentHub.presence(for: session.id) {
                    AgentStatusBanner(presence: presence, now: model.now)
                }
                if let path = session.selectedPath, let change = session.change(for: path) {
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

    /// Window-level items only. The monitor controls live in the change list header,
    /// so the inspector's width never affects their spacing.
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.promptForRepository()
            } label: {
                Label("Add Repository", systemImage: "plus")
            }
            .help("Watch another repository or worktree (⌘O)")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { model.showActivity }, set: { model.showActivity = $0 })) {
                Label("Activity", systemImage: "list.bullet.rectangle")
            }
            .help("Show the activity feed (⌃⌘I)")
        }
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
            Text("Vigil")
                .font(.title2.weight(.semibold))
            Text("Keep watch over repositories while an agent works in them. Add a repository or drop a folder onto the sidebar.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340)
            Button("Add Repository…") { model.promptForRepository() }
                .keyboardShortcut("o")
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
