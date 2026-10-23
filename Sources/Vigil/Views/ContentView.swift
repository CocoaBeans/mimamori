import SwiftUI
import VigilCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } content: {
            if let session = model.selectedSession {
                ChangeListView(session: session)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 640)
            } else {
                WelcomeView()
                    .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 640)
            }
        } detail: {
            detailColumn
        }
        .inspector(isPresented: $model.showActivity) {
            ActivityFeedView()
                .inspectorColumnWidth(min: 250, ideal: 320, max: 500)
        }
        .toolbar { toolbarItems }
        .onChange(of: model.showActivity) { model.persistUISoon() }
        .onChange(of: model.flaggedOnly) { model.persistUISoon() }
        .onChange(of: model.sortOrder) { model.persistUISoon() }
        .onChange(of: model.selectedWorktreeID) { model.persistUISoon() }
        .frame(minWidth: 960, minHeight: 560)
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let session = model.selectedSession, let path = session.selectedPath, let change = session.change(for: path) {
            DiffView(session: session, change: change)
        } else if model.selectedSession != nil {
            ContentUnavailableView("Select a File", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Pick a changed file to read its diff."))
        } else {
            Color.clear
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        let session = model.selectedSession
        ToolbarItem(placement: .navigation) {
            Button {
                model.promptForRepository()
            } label: {
                Label("Add Repository", systemImage: "plus")
            }
            .help("Watch another repository or worktree (⌘O)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let session {
                BaselinePicker(session: session)
                Button {
                    Task { await session.markStart() }
                } label: {
                    Label("Mark Start", systemImage: session.startSnapshot == nil ? "flag" : "flag.fill")
                }
                .help("Snapshot the working tree now and compare against it (⇧⌘S)")

                Button {
                    session.requestRefresh(force: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh now (⌘R)")

                Toggle(isOn: Binding(get: { model.flaggedOnly }, set: { model.flaggedOnly = $0 })) {
                    Label("Flagged Only", systemImage: "exclamationmark.triangle")
                }
                .help("Show only files that need attention (⇧⌘F)")

                Menu {
                    Picker("Sort By", selection: Binding(get: { model.sortOrder }, set: { model.sortOrder = $0 })) {
                        ForEach(ChangeSortOrder.allCases, id: \.self) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort order")
            }
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
        }
        .help("What the working tree is compared against")
    }

    private var currentTitle: String {
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
