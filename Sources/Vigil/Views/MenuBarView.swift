import SwiftUI
import VigilCore

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let flagged = model.totalFlagged
        let changed = model.totalChangedFiles
        let waiting = model.worktreesNeedingAttention.count
        if waiting > 0 {
            Label("\(waiting)", systemImage: "hand.raised.fill")
        } else if flagged > 0 {
            Label("\(flagged)", systemImage: "eye.trianglebadge.exclamationmark")
        } else if changed > 0 {
            Label("\(changed)", systemImage: "eye")
        } else {
            Image(systemName: "eye")
        }
    }
}

struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let repositories = model.repositories
        if repositories.isEmpty {
            Text("No repositories watched")
        } else {
            Text("\(model.totalChangedFiles) changed · \(model.totalFlagged) flagged")
            if !model.worktreesNeedingAttention.isEmpty {
                Text("\(model.worktreesNeedingAttention.count) waiting for you")
            }
            Divider()
            ForEach(repositories) { repo in
                let sessions = model.visibleSessions(for: repo)
                if model.isCollapsed(repo) {
                    // Collapsed in the sidebar: one submenu line here too.
                    Menu(repositorySummary(repo, sessions: sessions)) {
                        if sessions.isEmpty {
                            Text("No visible worktrees")
                        }
                        ForEach(sessions) { session in
                            Button(worktreeTitle(for: session)) { show(worktree: session.id) }
                        }
                    }
                } else {
                    Section(repo.displayName) {
                        if sessions.isEmpty {
                            Text("No visible worktrees")
                        }
                        ForEach(sessions) { session in
                            Button(worktreeTitle(for: session)) { show(worktree: session.id) }
                        }
                    }
                }
            }
        }
        Divider()
        Button("Open Vigil") { show(worktree: nil) }
        Button("Refresh All") { model.refreshAll() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Vigil") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func repositorySummary(_ repo: RepositoryEntry, sessions: [WorktreeSession]) -> String {
        let changed = sessions.reduce(0) { $0 + $1.changes.count }
        let flagged = sessions.reduce(0) { $0 + $1.flaggedCount }
        var title = "\(repo.displayName) · \(sessions.count) \(sessions.count == 1 ? "worktree" : "worktrees")"
        if changed > 0 {
            title += " · \(changed) changed"
            if flagged > 0 { title += ", \(flagged) flagged" }
        } else {
            title += " · clean"
        }
        return title
    }

    private func worktreeTitle(for session: WorktreeSession) -> String {
        var title = session.displayName
        if let presence = model.agentHub.presence(for: session.id) {
            title += presence.needsAttention ? " ✋" : (presence.source == .hooks ? " ✨" : " ·")
        }
        if session.changes.isEmpty {
            title += " · clean"
        } else {
            title += " · \(session.changes.count) changed"
            if session.flaggedCount > 0 { title += ", \(session.flaggedCount) flagged" }
            let left = session.unreviewedCount
            if left < session.changes.count {
                title += left == 0 ? ", all reviewed" : ", \(left) to review"
            }
        }
        return title
    }

    private func show(worktree: String?) {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let worktree { model.select(worktree: worktree) }
    }
}
