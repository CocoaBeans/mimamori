import SwiftUI
import MimamoriCore

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

/// The menu-bar popover: the agents at work, drawn with the desktop widget's rows and live
/// timers, then the worktrees Mimamori watches and its commands.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.isRenderingWidgetPreview) private var isPreview
    @Environment(\.openSettings) private var openSettings
    /// Closes the popover: opening a window does not.
    @Environment(\.dismiss) private var dismiss
    /// The list's own height: a scroll view has none, and the popover would shrink to nothing.
    @State private var listHeight: CGFloat = 200
    /// Whether the popover is showing: its window stays around while it is closed.
    @State private var isOpen = false

    /// Tall enough for a long list, short enough to stay on screen below the menu bar.
    private var maximumListHeight: CGFloat {
        max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 160)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isPreview {
                // ImageRenderer cannot draw a scroll view.
                list
            } else if isOpen {
                ScrollView {
                    list.onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
                }
                .frame(height: min(listHeight, maximumListHeight))
            } else {
                // Closed, the popover's window stays around; drawing nothing in it keeps every
                // agent event from redrawing a list nobody can see.
                Color.clear.frame(height: min(listHeight, maximumListHeight))
            }
            Divider()
            footer
        }
        .onAppear { isOpen = true }
        .onDisappear { isOpen = false }
        .frame(width: 340)
        .buttonStyle(PanelButtonStyle())
        .environment(\.openAgent) { show(worktree: $0.worktreePath) }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            agents
            Divider()
            worktrees
        }
    }

    private var agents: some View {
        let snapshot = AgentWidgetSnapshot(agents: model.widgetAgents(details: true))
        // The most pressing state washes the top, as on the widget.
        let mood = snapshot.agents.first.map { $0.collision != nil ? Color.orange : $0.state.tint } ?? .secondary
        return VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(snapshot: snapshot)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            if snapshot.agents.isEmpty {
                Label("No agents at work", systemImage: "moon.stars.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
            ForEach(snapshot.agents) { agent in
                AgentLink(agent: agent) {
                    AgentRowView(agent: agent, detailed: true)
                }
            }
        }
        .padding(8)
        .padding(.top, 4)
        .background(LinearGradient(colors: [mood.opacity(0.2), mood.opacity(0.02)], startPoint: .top, endPoint: .bottom))
    }

    private var worktrees: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Worktrees")
                    .font(.headline)
                Spacer()
                Text("\(model.totalChangedFiles) changed · \(model.totalFlagged) flagged")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.totalFlagged > 0 ? Color.orange : Color.secondary)
            }
            .padding(.horizontal, 6)
            if model.repositories.isEmpty {
                Text("No repositories watched")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                Button("Add Repository…") {
                    dismiss()
                    model.promptForRepository()
                }
            }
            ForEach(model.repositories) { repo in
                let sessions = model.visibleSessions(for: repo)
                Text(repo.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.top, 8)
                if sessions.isEmpty {
                    Text("No visible worktrees")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                } else if model.isCollapsed(repo) {
                    // Collapsed in the sidebar: one line here too.
                    Button { show(worktree: sessions[0].id) } label: {
                        let changes = sessions.flatMap(\.changes)
                        PanelWorktreeLine(glyph: AgentGlyph(symbol: "square.stack.3d.up", tint: .secondary),
                                          title: sessions.count == 1 ? "1 worktree" : "\(sessions.count) worktrees",
                                          status: status(changed: changes.count, flagged: changes.flaggedCount, toReview: nil),
                                          diff: (changes.totalAdditions, changes.totalDeletions))
                    }
                    .help("Show \(repo.displayName) in Mimamori")
                } else {
                    ForEach(sessions) { session in
                        Button { show(worktree: session.id) } label: { line(for: session) }
                            .help("Show \(session.displayName) in Mimamori")
                    }
                }
            }
        }
        .padding(8)
    }

    private func line(for session: WorktreeSession) -> some View {
        let presence = model.agentHub.presence(for: session.id)
        let left = session.unreviewedCount
        return PanelWorktreeLine(
            glyph: presence.map(AgentGlyph.init(presence:))
                ?? AgentGlyph(symbol: session.info.isMain ? "shippingbox" : "arrow.triangle.branch", tint: .secondary),
            title: session.displayName,
            status: status(changed: session.changes.count, flagged: session.flaggedCount,
                           toReview: left < session.changes.count ? left : nil),
            diff: (session.changes.totalAdditions, session.changes.totalDeletions))
    }

    /// "5 changed · 1 flagged · 2 to review", or "clean".
    private func status(changed: Int, flagged: Int, toReview: Int?) -> (text: String, warning: Bool) {
        guard changed > 0 else { return ("clean", false) }
        var parts = ["\(changed) changed"]
        if flagged > 0 { parts.append("\(flagged) flagged") }
        if let toReview { parts.append(toReview == 0 ? "all reviewed" : "\(toReview) to review") }
        return (parts.joined(separator: " · "), flagged > 0)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button("Open Mimamori") { show(worktree: nil) }
                .help("Open Mimamori's window")
            Button("Agents") {
                openWindow(id: "agents")
                NSApplication.shared.activate(ignoringOtherApps: true)
                dismiss()
            }
            .help("Open the Agents window (⇧⌘A)")
            Spacer()
            Button { model.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh every worktree")
                .accessibilityLabel("Refresh All")
            Button {
                openSettings()
                NSApplication.shared.activate(ignoringOtherApps: true)
                dismiss()
            } label: { Image(systemName: "gearshape") }
                .help("Settings… (⌘,)")
                .accessibilityLabel("Settings")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .keyboardShortcut("q")
                .help("Quit Mimamori (⌘Q)")
                .accessibilityLabel("Quit Mimamori")
        }
        .padding(6)
    }

    private func show(worktree: String?) {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let worktree { model.select(worktree: worktree) }
        dismiss()
    }
}

/// A worktree in the popover: its agent's glyph or a branch, its name, and what changed.
private struct PanelWorktreeLine: View {
    let glyph: AgentGlyph
    let title: String
    let status: (text: String, warning: Bool)
    /// Lines added and removed across its changes.
    var diff: (additions: Int, deletions: Int) = (0, 0)

    var body: some View {
        HStack(spacing: 8) {
            glyph
                .frame(width: 16)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 8)
            if diff.additions + diff.deletions > 0 {
                DiffBar(additions: diff.additions, deletions: diff.deletions, block: 5)
            }
            Text(status.text)
                .font(.caption)
                .foregroundStyle(status.warning ? Color.orange : Color.secondary)
                .lineLimit(1)
        }
        .font(.callout)
    }
}

/// Plain rows that light up under the pointer, like a menu's.
private struct PanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelButton(configuration: configuration)
    }

    private struct PanelButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(minHeight: 22)
                .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
