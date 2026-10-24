import SwiftUI
import VigilCore

/// One watched worktree with an agent in it.
struct AgentRow: Identifiable {
    let session: WorktreeSession
    let repositoryName: String
    let presence: AgentPresence
    var id: String { session.id }
}

extension AppModel {
    /// Every watched worktree with an agent, blocked-on-you first (longest waiting on top),
    /// then busy, then idle; alphabetical within a group so rows do not shuffle.
    var agentRows: [AgentRow] {
        let rows = orderedSessions.compactMap { session -> AgentRow? in
            guard let presence = agentHub.presence(for: session.id) else { return nil }
            return AgentRow(session: session, repositoryName: repository(for: session)?.displayName ?? "",
                            presence: presence)
        }
        return rows.sorted { a, b in
            if a.presence.urgency != b.presence.urgency { return a.presence.urgency < b.presence.urgency }
            if a.presence.needsAttention, a.presence.since != b.presence.since { return a.presence.since < b.presence.since }
            return (a.repositoryName, a.session.displayName) < (b.repositoryName, b.session.displayName)
        }
    }
}

/// A small window listing what every agent is doing; click a row to open its worktree.
struct AgentsWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let rows = model.agentRows
        Group {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No Agents Running", systemImage: "sparkles")
                } description: {
                    Text("Agents appear here while one is running in a watched worktree. Install hooks in Settings › Agents to see what each one is doing.")
                }
            } else {
                List {
                    ForEach(rows) { row in
                        AgentDashboardRow(row: row, now: model.now)
                            .contentShape(Rectangle())
                            .onTapGesture { show(row) }
                            .contextMenu {
                                Button("Show in Vigil") { show(row) }
                                Button("Session Summary…") {
                                    show(row)
                                    model.showSummary(for: row.session.id)
                                }
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.session.id)])
                                }
                                Button("Open in Terminal") { Workspace.openTerminal(at: row.session.id) }
                            }
                            .help("Show \(row.session.displayName) in the main window")
                    }
                }
                .listStyle(.inset)
                .animation(.default, value: rows.map(\.id))
            }
        }
        .frame(minWidth: 340, minHeight: 180)
        .navigationTitle("Agents")
        .navigationSubtitle(summary(rows))
        .toolbar {
            ToolbarItem {
                Toggle(isOn: Binding(get: { model.settings.agentsWindowFloats },
                                     set: { value in
                                         var copy = model.settings
                                         copy.agentsWindowFloats = value
                                         model.updateSettings(copy)
                                     })) {
                    Label("Keep on Top", systemImage: model.settings.agentsWindowFloats ? "pin.fill" : "pin")
                }
                .help(model.settings.agentsWindowFloats ? "Floating above other windows. Click to stop." : "Keep this window above other windows")
            }
        }
    }

    private func summary(_ rows: [AgentRow]) -> String {
        guard !rows.isEmpty else { return "" }
        let waiting = rows.filter(\.presence.needsAttention).count
        let working = rows.filter(\.presence.isWorking).count
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) need\(waiting == 1 ? "s" : "") you") }
        if working > 0 { parts.append("\(working) working") }
        let rest = rows.count - waiting - working
        if rest > 0 { parts.append("\(rest) idle") }
        return parts.joined(separator: " · ")
    }

    private func show(_ row: AgentRow) {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        model.select(worktree: row.session.id)
    }
}

struct AgentDashboardRow: View {
    let row: AgentRow
    let now: Date

    private var presence: AgentPresence { row.presence }

    /// Paths inside the worktree read better relative to it, and others from ~.
    private func relative(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return text.replacingOccurrences(of: row.session.id + "/", with: "")
            .replacingOccurrences(of: home + "/", with: "~/")
    }

    /// The last tool call, when the status line does not already name it.
    private var lastCall: String? {
        switch presence.activity {
        case .working, .needsPermission: return nil
        case .askedQuestion, .ready, .idle: break
        }
        guard let call = presence.lastToolCall else { return nil }
        let target = call.summary.map { " " + relative($0) } ?? ""
        return "last: \(call.toolName)\(target), \(Format.relative(call.finishedAt ?? call.startedAt, to: now))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: presence.systemImage)
                .font(.title3)
                .foregroundStyle(presence.tint)
                .frame(width: 24)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.session.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(row.repositoryName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(presence.timing(now: now))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .help(presence.timingHelp)
                }
                Text("\(presence.kind.displayName) · \(relative(presence.statusText))")
                    .foregroundStyle(presence.needsAttention ? presence.tint : .primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: 8) {
                    if let lastCall {
                        Text(lastCall)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if presence.source == .hooks, presence.toolCallsThisTurn > 0 {
                        Text(presence.toolCallsThisTurn == 1 ? "1 tool call this turn" : "\(presence.toolCallsThisTurn) tool calls this turn")
                    }
                    Spacer(minLength: 6)
                    ChangeSummary(session: row.session)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}

/// "9 changed · 4 to review" plus the flagged count, for a worktree.
private struct ChangeSummary: View {
    let session: WorktreeSession

    var body: some View {
        let total = session.changes.count
        HStack(spacing: 6) {
            if total == 0 {
                Text("clean")
            } else {
                let left = session.unreviewedCount
                Text(left < total ? "\(total) changed · \(left) to review" : "\(total) changed")
                if session.flaggedCount > 0 {
                    Label("\(session.flaggedCount)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .monospacedDigit()
        .fixedSize()
    }
}
