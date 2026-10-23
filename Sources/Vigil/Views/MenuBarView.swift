import SwiftUI
import VigilCore

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let flagged = model.totalFlagged
        let changed = model.totalChangedFiles
        if flagged > 0 {
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
        let sessions = model.orderedSessions
        if sessions.isEmpty {
            Text("No repositories watched")
        } else {
            Text("\(model.totalChangedFiles) changed · \(model.totalFlagged) flagged")
            Divider()
            ForEach(sessions) { session in
                Button {
                    show(worktree: session.id)
                } label: {
                    Text(menuTitle(for: session))
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

    private func menuTitle(for session: WorktreeSession) -> String {
        let repo = model.repository(for: session)?.displayName ?? ""
        var title = repo.isEmpty ? session.displayName : "\(repo) · \(session.displayName)"
        if session.changes.isEmpty {
            title += " · clean"
        } else {
            title += " · \(session.changes.count) changed"
            if session.flaggedCount > 0 { title += ", \(session.flaggedCount) flagged" }
        }
        return title
    }

    private func show(worktree: String?) {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let worktree { model.select(worktree: worktree) }
    }
}
