import SwiftUI
import MimamoriCore

/// The toolbar's agent status, like Xcode's activity view: the agent that most needs you across
/// every worktree, or how many are working, whichever worktree is selected. Click it for that
/// agent's banner and the others. Its own view, so agents' updates redraw only the pill.
struct AgentStatusPill: View {
    @Environment(AppModel.self) private var model
    @State private var showingDetails = false

    var body: some View {
        let rows = model.agentRows
        Button {
            showingDetails.toggle()
        } label: {
            PillLabel(rows: rows, now: model.agentNow)
        }
        .buttonStyle(.plain)
        .disabled(rows.isEmpty)
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            AgentStatusPopover(onDone: { showingDetails = false })
                .environment(model)
        }
        .help(rows.isEmpty ? "No agents are running in a worktree Mimamori watches" : "Show the agents at work")
        .task {
            // MIMAMORI_DEBUG_FLAGS=status-pill opens the popover, once agents have reported.
            guard model.debugFlags.contains("status-pill") else { return }
            try? await Task.sleep(for: .seconds(4))
            showingDetails = true
        }
        .accessibilityLabel(PillLabel.describe(rows, now: model.agentNow))
    }
}

/// The pill's place in the toolbar before macOS 26: the middle. (On macOS 26 it belongs to the diff
/// column; see `DiffColumnToolbar`.)
struct AgentStatusPillItem: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) { AgentStatusPill() }
    }
}

/// What the pill says: the agent waiting on you longest, else who is working, else who is ready.
private struct PillLabel: View {
    let rows: [AgentRow]
    let now: Date

    private var waiting: [AgentRow] { rows.filter(\.presence.needsAttention) }
    private var working: [AgentRow] { rows.filter(\.presence.isWorking) }

    var body: some View {
        HStack(spacing: 6) {
            if let first = waiting.first {
                AgentBadge(presence: first.presence, size: 18)
                Text("\(first.presence.kind.displayName) needs you")
                    .fontWeight(.semibold)
                Text("· \(Self.short(first.session.displayName)) · \(Format.duration(since: first.presence.since, to: now))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if waiting.count > 1 {
                    CountBadge(count: waiting.count - 1, tint: .orange)
                        .help("\(waiting.count - 1) more waiting on you")
                }
            } else if !rows.isEmpty {
                let shown = working.isEmpty ? rows : working
                Badges(rows: Array(shown.prefix(3)))
                Text(working.isEmpty ? (rows.count == 1 ? "1 agent ready" : "\(rows.count) agents ready")
                     : "\(working.count) working")
                    .fontWeight(.medium)
            } else {
                Image(systemName: "moon.zzz")
                    .foregroundStyle(.secondary)
                Text("No agents")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(tint.opacity(rows.isEmpty ? 0 : 0.16), in: Capsule())
        .fixedSize()
    }

    /// A long branch name cut in the middle, so the pill stays a pill: "feature/sessi…ory-pressure".
    static func short(_ name: String, limit: Int = 28) -> String {
        guard name.count > limit else { return name }
        return name.prefix(limit / 2 - 1) + "…" + name.suffix(limit / 2)
    }

    private var tint: Color {
        if !waiting.isEmpty { return .orange }
        if !working.isEmpty { return .blue }
        return .green
    }

    /// "Codex needs you in w2, waiting 42s. 2 working."
    static func describe(_ rows: [AgentRow], now: Date) -> String {
        guard !rows.isEmpty else { return "No agents" }
        let waiting = rows.filter(\.presence.needsAttention)
        let working = rows.filter(\.presence.isWorking).count
        var parts: [String] = []
        if let first = waiting.first {
            parts.append("\(first.presence.kind.displayName) needs you in \(first.session.displayName), \(first.presence.timing(now: now))")
            if waiting.count > 1 { parts.append("\(waiting.count - 1) more waiting on you") }
        }
        if working > 0 { parts.append("\(working) working") }
        if waiting.isEmpty, working == 0 { parts.append(rows.count == 1 ? "1 agent ready" : "\(rows.count) agents ready") }
        return "Agents: " + parts.joined(separator: ". ")
    }
}

/// A few agents' badges, overlapping a little.
private struct Badges: View {
    let rows: [AgentRow]

    var body: some View {
        HStack(spacing: -5) {
            ForEach(rows) { row in
                AgentBadge(presence: row.presence, size: 18)
                    .background(Circle().fill(.background))
            }
        }
    }
}

/// The pill's popover: the most pressing agent's banner, then every other agent.
struct AgentStatusPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let onDone: () -> Void

    var body: some View {
        let rows = model.agentRows
        VStack(alignment: .leading, spacing: 0) {
            if let first = rows.first {
                banner(first)
                HStack {
                    Spacer()
                    Button("Show \(first.session.displayName)") { show(first.session.id) }
                        .keyboardShortcut(.defaultAction)
                        .help("Select \(first.session.displayName) in this window")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            let others = rows.dropFirst()
            if !others.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(others.count == 1 ? "Also at work" : "\(others.count) more agents")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                    let agents = model.widgetAgents(details: false)
                    ForEach(others) { row in
                        if let agent = agents.first(where: { $0.worktreePath == row.id }) {
                            AgentLink(agent: agent) {
                                AgentRowView(agent: agent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(8)
                .environment(\.openAgent) { show($0.worktreePath) }
            }
        }
        .frame(width: 440)
    }

    private func banner(_ row: AgentRow) -> some View {
        let worktree = row.session.id
        let presence = row.presence
        return AgentStatusBanner(presence: presence, now: model.agentNow, details: AgentBannerDetails(
            worktree: worktree,
            files: row.files,
            expanded: true,
            canGoToAgent: AgentApps.canGo(to: presence),
            onToggle: {},
            onOpenFile: { path in show(worktree, path: path) },
            onGoToAgent: {
                onDone()
                AgentApps.bringForward(presence)
            },
            onSummary: {
                onDone()
                openWindow.summary(for: worktree)
            },
            onDismissCollision: { model.agentHub.dismissCollision(in: worktree) },
            canToggle: false))
    }

    private func show(_ worktree: String, path: String? = nil) {
        onDone()
        model.select(worktree: worktree, path: path)
    }
}
