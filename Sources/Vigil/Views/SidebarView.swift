import SwiftUI
import VigilCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var repositoryToRemove: RepositoryEntry?

    var body: some View {
        List(selection: Binding(get: { model.selectedWorktreeID }, set: { model.select(worktree: $0) })) {
            ForEach(model.repositories) { repo in
                Section {
                    ForEach(repo.worktrees) { worktree in
                        WorktreeRow(info: worktree, session: model.sessions[worktree.path], now: model.now,
                                    recencyWindow: model.settings.recencyWindowSeconds)
                            .tag(worktree.path)
                            .contextMenu {
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([worktree.url]) }
                                Button("Open in Terminal") { Workspace.openTerminal(at: worktree.path) }
                                Button("Copy Path") { Workspace.copy(worktree.path) }
                                Divider()
                                Button("Refresh") { model.sessions[worktree.path]?.requestRefresh(force: true) }
                            }
                    }
                    if let error = repo.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text(repo.displayName)
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.rootPath)])
                            }
                            Button("Rediscover Worktrees") { Task { await model.rediscoverWorktrees(for: repo.id) } }
                            Divider()
                            Button("Stop Watching", role: .destructive) { repositoryToRemove = repo }
                        }
                        .help(Format.abbreviate(path: repo.rootPath))
                }
            }
        }
        .listStyle(.sidebar)
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
                if model.totalFlagged > 0 {
                    Label("\(model.totalFlagged)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Files needing attention across all worktrees")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addRepositories(at: urls)
            return true
        }
        .confirmationDialog("Stop watching \(repositoryToRemove?.displayName ?? "")?",
                            isPresented: Binding(get: { repositoryToRemove != nil }, set: { if !$0 { repositoryToRemove = nil } }),
                            presenting: repositoryToRemove) { repo in
            Button("Stop Watching", role: .destructive) { model.removeRepository(repo.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Vigil stops watching the repository. Nothing in the repository is changed; snapshot refs under refs/monitor stay until you delete them.")
        }
        .navigationTitle("Vigil")
    }
}

struct WorktreeRow: View {
    let info: WorktreeInfo
    let session: WorktreeSession?
    let now: Date
    let recencyWindow: Double

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
                Text(info.isMain ? "main worktree" : info.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                if !session.changes.isEmpty {
                    CountBadge(count: session.changes.count)
                }
            }
        }
        .padding(.vertical, 1)
        .help(Format.abbreviate(path: info.path))
    }
}
