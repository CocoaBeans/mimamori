import SwiftUI
import VigilCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { model.selectedWorktreeID }, set: { model.select(worktree: $0) })) {
            ForEach(model.repositories) { repo in
                RepositorySection(repo: repo)
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { model.requestRemovalOfSelectedRepository() }
        .overlay {
            if model.repositories.isEmpty {
                ContentUnavailableView {
                    Label("No Repositories", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add one or drop a folder here.")
                } actions: {
                    Button("Add Repository…") { model.promptForRepository() }
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
                Spacer()
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
            Text("Vigil stops watching the repository and all of its worktrees. Nothing in the repository is changed; snapshot refs under refs/monitor stay until you delete them.")
        }
        .navigationTitle("Vigil")
    }
}

/// One collapsible repository with its visible worktrees.
private struct RepositorySection: View {
    @Environment(AppModel.self) private var model
    let repo: RepositoryEntry

    var body: some View {
        let visible = model.visibleWorktrees(for: repo)
        let hidden = model.hiddenWorktrees(for: repo)
        let sessions = model.visibleSessions(for: repo)
        let collapsed = model.isCollapsed(repo)

        Section(isExpanded: Binding(get: { !model.isCollapsed(repo) }, set: { model.setCollapsed(!$0, for: repo.id) })) {
            ForEach(visible) { worktree in
                WorktreeRow(info: worktree, session: model.sessions[worktree.path], now: model.now,
                            recencyWindow: model.settings.recencyWindowSeconds,
                            presence: model.agentHub.presence(for: worktree.path))
                    .tag(worktree.path)
                    .contextMenu {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([worktree.url]) }
                        Button("Open in Terminal") { Workspace.openTerminal(at: worktree.path) }
                        Button("Copy Path") { Workspace.copy(worktree.path) }
                        Divider()
                        Button("Refresh") { model.sessions[worktree.path]?.requestRefresh(force: true) }
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
            HStack(spacing: 6) {
                Text(repo.displayName)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !hidden.isEmpty {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help(hidden.count == 1 ? "1 hidden worktree" : "\(hidden.count) hidden worktrees")
                }
                if collapsed {
                    let flagged = sessions.reduce(0) { $0 + $1.flaggedCount }
                    let changed = sessions.reduce(0) { $0 + $1.changes.count }
                    if flagged > 0 { CountBadge(count: flagged, tint: .orange) }
                    if changed > 0 { CountBadge(count: changed) }
                }
            }
            .contentShape(Rectangle())
            .help(Format.abbreviate(path: repo.rootPath))
            .contextMenu {
                Button(collapsed ? "Expand" : "Collapse") { model.setCollapsed(!collapsed, for: repo.id) }
                Divider()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.rootPath)])
                }
                Button("Rediscover Worktrees") { Task { await model.rediscoverWorktrees(for: repo.id) } }
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
                Button("Stop Watching…", role: .destructive) { model.requestRemoval(of: repo) }
            }
        }
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
            Image(systemName: info.isMain ? "shippingbox" : "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .frame(width: 16)
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
                if session.flaggedCount > 0 {
                    CountBadge(count: session.flaggedCount, tint: .orange)
                }
                ReviewCountBadge(session: session)
            }
        }
        .padding(.vertical, 1)
        .help(Format.abbreviate(path: info.path))
    }
}

/// Changed-file count for a worktree. Once you start reviewing it counts what is left
/// to review instead, and turns into a checkmark when nothing is.
struct ReviewCountBadge: View {
    let session: WorktreeSession

    var body: some View {
        let total = session.changes.count
        let left = session.unreviewedCount
        if total == 0 {
            EmptyView()
        } else if left == total {
            CountBadge(count: total)
                .help(total == 1 ? "1 changed file" : "\(total) changed files")
        } else if left == 0 {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(total == 1 ? "1 changed file, reviewed" : "All \(total) changed files reviewed")
        } else {
            CountBadge(count: left, tint: .accentColor)
                .help("\(left) of \(total) changed files left to review")
        }
    }
}
