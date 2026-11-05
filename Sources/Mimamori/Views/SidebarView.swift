import SwiftUI
import MimamoriCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { model.selectedWorktreeID }, set: { model.select(worktree: $0) })) {
            if !model.repositoryOffers.isEmpty {
                Section("Not Watched Yet") {
                    ForEach(model.repositoryOffers) { RepositoryOfferRow(offer: $0) }
                }
            }
            ForEach(model.repositories) { repo in
                // With the agents filter on, a repository with no agent at work drops out entirely.
                if !model.sidebarAgentsOnly || !model.listedWorktrees(for: repo).isEmpty {
                    RepositorySection(repo: repo)
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { model.requestRemovalOfSelectedRepository() }
        .overlay {
            if model.sidebarAgentsOnly, !model.repositories.isEmpty,
               model.repositories.allSatisfy({ model.listedWorktrees(for: $0).isEmpty }) {
                ContentUnavailableView {
                    Label("No Agents Running", systemImage: "sparkles")
                } description: {
                    Text("Worktrees appear here while an agent works in them.")
                } actions: {
                    Button("Show All Worktrees") { model.sidebarAgentsOnly = false }
                        .help("Turn off the agents-only filter")
                }
            } else if model.repositories.isEmpty {
                ContentUnavailableView {
                    Label("No Repositories", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add one or drop a folder here.")
                } actions: {
                    Button("Add Repository…") { model.promptForRepository() }
                        .help("Choose a repository or worktree folder to watch (⌘O)")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    model.promptForRepository()
                } label: {
                    Label("Add Repository", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Watch another repository or worktree (⌘O)")
                Spacer()
                Toggle(isOn: Binding(get: { model.sidebarAgentsOnly }, set: { model.sidebarAgentsOnly = $0 })) {
                    Image(systemName: model.sidebarAgentsOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help(model.sidebarAgentsOnly
                      ? "Showing only worktrees with an agent. Click to show them all."
                      : "Show only worktrees with an agent at work")
                .accessibilityLabel("Only worktrees with agents")
                AttentionNeededButton()
                AttentionBadgeButton(sessions: model.orderedSessions, arrowEdge: .bottom, debugID: "sidebar")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addRepositories(at: urls)
            return true
        }
        .confirmationDialog("Stop watching \(model.repositoryPendingRemoval?.displayName ?? "")?",
                            isPresented: Binding(get: { model.repositoryPendingRemoval != nil },
                                                 set: { if !$0 { model.repositoryPendingRemoval = nil } }),
                            presenting: model.repositoryPendingRemoval) { repo in
            Button("Stop Watching", role: .destructive) { model.removeRepository(repo.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Mimamori stops watching the repository and all of its worktrees. Nothing in the repository is changed; snapshot refs under refs/monitor stay until you delete them.")
        }
        .navigationTitle("Mimamori")
    }
}

/// A repository's section header: its badge and name, and folded, what changed in it.
struct RepositoryHeader: View {
    @Environment(AppModel.self) private var model
    let repo: RepositoryEntry
    /// How many of its worktrees are hidden.
    let hidden: Int
    let collapsed: Bool
    let sessions: [WorktreeSession]

    var body: some View {
        HStack(spacing: 6) {
            RepositoryBadge(look: model.look(for: repo), size: 16)
            Text(repo.displayName)
                .lineLimit(1)
            Spacer(minLength: 4)
            if hidden > 0 {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(hidden == 1 ? "1 hidden worktree" : "\(hidden) hidden worktrees")
            }
            if collapsed {
                let flagged = sessions.reduce(0) { $0 + $1.flaggedCount }
                let changed = sessions.reduce(0) { $0 + $1.changes.count }
                if flagged > 0 { CountBadge(count: flagged, tint: .orange) }
                if changed > 0 { CountBadge(count: changed) }
            }
        }
    }
}

/// One collapsible repository with its visible worktrees.
private struct RepositorySection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let repo: RepositoryEntry

    var body: some View {
        let visible = model.listedWorktrees(for: repo)
        let hidden = model.hiddenWorktrees(for: repo)
        let sessions = model.visibleSessions(for: repo)
        let collapsed = model.isCollapsed(repo)

        Section(isExpanded: Binding(get: { !model.isCollapsed(repo) }, set: { model.setCollapsed(!$0, for: repo.id) })) {
            ForEach(visible) { worktree in
                WorktreeRow(info: worktree, session: model.sessions[worktree.path], now: model.now,
                            recencyWindow: model.settings.recencyWindowSeconds,
                            presence: model.agentHub.presence(for: worktree.path))
                    .equatable()
                    .tag(worktree.path)
                    .contextMenu {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([worktree.url]) }
                        Button("Open in Terminal") { Workspace.openTerminal(at: worktree.path) }
                        Button("Copy Path") { Workspace.copy(worktree.path) }
                        Divider()
                        Button("Refresh") { model.sessions[worktree.path]?.requestRefresh(force: true) }
                        Button("Session Summary…") { openWindow.summary(for: worktree.path) }
                            .disabled(model.sessions[worktree.path] == nil)
                        Divider()
                        Button("Hide Worktree") { model.hideWorktree(worktree.path) }
                        Button("Stop Watching \(repo.displayName)…", role: .destructive) { model.requestRemoval(of: repo) }
                    }
            }
            if visible.isEmpty {
                Text(hidden.isEmpty ? "No worktrees" : "All worktrees hidden")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let error = repo.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            RepositoryHeader(repo: repo, hidden: hidden.count, collapsed: collapsed, sessions: sessions)
            .contentShape(Rectangle())
            .help(Format.abbreviate(path: repo.rootPath))
            .contextMenu {
                Button(collapsed ? "Expand" : "Collapse") { model.setCollapsed(!collapsed, for: repo.id) }
                Divider()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.rootPath)])
                }
                Button("Rediscover Worktrees") {
                    Task {
                        await model.rediscoverWorktrees(for: repo.id)
                        await model.findIcon(for: repo.id)
                    }
                }
                if !hidden.isEmpty {
                    Menu("Show Hidden Worktree") {
                        ForEach(hidden) { worktree in
                            Button(worktree.branch ?? worktree.name) { model.showWorktree(worktree.path) }
                        }
                        Divider()
                        Button("Show All (\(hidden.count))") { model.showAllWorktrees(for: repo.id) }
                    }
                }
                Divider()
                RepositoryLookMenu(repo: repo)
                Divider()
                Button("Stop Watching…", role: .destructive) { model.requestRemoval(of: repo) }
            }
        }
    }
}

/// Every row is rebuilt whenever any agent changes; one whose own inputs are unchanged need not
/// draw again (what it reads from its session, it observes itself).
extension WorktreeRow: @preconcurrency Equatable {
    static func == (a: WorktreeRow, b: WorktreeRow) -> Bool {
        a.info == b.info && a.session === b.session && a.now == b.now
            && a.recencyWindow == b.recencyWindow && a.presence == b.presence
    }
}

struct WorktreeRow: View {
    let info: WorktreeInfo
    let session: WorktreeSession?
    let now: Date
    let recencyWindow: Double
    var presence: AgentPresence? = nil

    private var isRecentlyActive: Bool {
        guard let date = session?.lastActivityDate else { return false }
        return now.timeIntervalSince(date) < recencyWindow
    }

    var body: some View {
        HStack(spacing: 8) {
            // The agent at work here, else what kind of worktree it is.
            Group {
                if let presence {
                    AgentBadge(presence: presence, size: 22)
                } else {
                    Image(systemName: info.isMain ? "shippingbox" : "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(session?.displayName ?? info.branch ?? info.name)
                    .lineLimit(1)
                if let presence {
                    AgentPresenceBadge(presence: presence)
                } else {
                    Text(info.isMain ? "main worktree" : info.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let session {
                switch session.phase {
                case .starting, .indexing, .refreshing:
                    ProgressView().controlSize(.mini)
                case .failed, .missing:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .help(session.lastError ?? "Unavailable")
                case .idle:
                    if isRecentlyActive {
                        Circle().fill(.green).frame(width: 6, height: 6)
                            .help("Changed recently")
                    }
                }
                if let state = session.state, let operation = state.operation {
                    OperationChip(operation: operation, currentBranch: state.branch.branch)
                }
                if session.flaggedCount > 0 {
                    CountChip(symbol: "exclamationmark.triangle.fill", count: session.flaggedCount, tint: .orange)
                        .help(session.flaggedCount == 1 ? "1 file needs a look" : "\(session.flaggedCount) files need a look")
                }
                let notes = session.notes.unsent.count
                if notes > 0 {
                    CountChip(symbol: "text.bubble", count: notes, tint: .accentColor)
                        .help(notes == 1 ? "1 note for the agent, not sent yet" : "\(notes) notes for the agent, not sent yet")
                }
                ReviewCountBadge(session: session)
            }
        }
        .padding(.vertical, 1)
        .help(Format.abbreviate(path: info.path))
    }
}

/// Changed-file count for a worktree (±). Once you start reviewing it counts what is left
/// to review instead (an eye), and turns into a checkmark when nothing is.
struct ReviewCountBadge: View {
    let session: WorktreeSession

    var body: some View {
        let total = session.changes.count
        let left = session.unreviewedCount
        if total == 0 {
            EmptyView()
        } else if left == total {
            CountChip(symbol: "plusminus", count: total)
                .help(total == 1 ? "1 changed file" : "\(total) changed files")
        } else if left == 0 {
            CountChip(symbol: "checkmark", count: total)
                .help(total == 1 ? "1 changed file, reviewed" : "All \(total) changed files reviewed")
        } else {
            CountChip(symbol: "eye", count: left, tint: .accentColor)
                .help("\(left) of \(total) changed files left to review")
        }
    }
}

/// A repository an agent works in that Mimamori does not watch: watch it, or not.
struct RepositoryOfferRow: View {
    @Environment(AppModel.self) private var model
    let offer: RepositoryOffer

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: offer.agent.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(offer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The section's heading says the rest: "Not Watched Yet".
                Text(offer.agent.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Watch") { model.answerOffer(for: offer.root, .watch) }
                .controlSize(.small)
                .help("Watch \((offer.root as NSString).abbreviatingWithTildeInPath)")
            Menu {
                Button("Not Now") { model.answerOffer(for: offer.root, .notNow) }
                Button("Don't Ask Again") { model.answerOffer(for: offer.root, .never) }
            } label: {
                Image(systemName: "xmark")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Not now, or don't ask again for this repository")
            .accessibilityLabel("Dismiss")
        }
        .help((offer.root as NSString).abbreviatingWithTildeInPath)
    }
}
