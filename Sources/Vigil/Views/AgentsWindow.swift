import SwiftUI
import VigilCore

/// One watched worktree with an agent in it.
struct AgentRow: Identifiable {
    let session: WorktreeSession
    let repositoryName: String
    let presence: AgentPresence
    /// Changed files the agent touched in its current (or last) turn, most recent first.
    let files: [FileChange]
    var id: String { session.id }
}

extension AppModel {
    /// Every watched worktree with an agent, blocked-on-you first (longest waiting on top),
    /// then busy, then idle; alphabetical within a group so rows do not shuffle.
    var agentRows: [AgentRow] {
        let rows = orderedSessions.compactMap { session -> AgentRow? in
            guard let presence = agentHub.presence(for: session.id) else { return nil }
            return AgentRow(session: session, repositoryName: repository(for: session)?.displayName ?? "",
                            presence: presence, files: filesTouched(in: session, by: presence))
        }
        return rows.sorted { a, b in
            if a.presence.urgency != b.presence.urgency { return a.presence.urgency < b.presence.urgency }
            if a.presence.needsAttention, a.presence.since != b.presence.since { return a.presence.since < b.presence.since }
            return (a.repositoryName, a.session.displayName) < (b.repositoryName, b.session.displayName)
        }
    }

    /// Files the agent's tools edited this turn, plus any that changed on disk during it (a
    /// shell command's edits have no file path), limited to those still differing from the baseline.
    func filesTouched(in session: WorktreeSession, by presence: AgentPresence) -> [FileChange] {
        guard let start = presence.turnStartedAt else { return [] }
        var ordered: [String] = []
        var seen = Set<String>()
        for step in presence.turnSteps.reversed() where step.isMutating {
            guard let file = step.filePath else { continue }
            let path = file.hasPrefix(session.id + "/") ? String(file.dropFirst(session.id.count + 1)) : file
            if seen.insert(path).inserted { ordered.append(path) }
        }
        for (path, date) in session.lastChanged.sorted(by: { $0.value > $1.value }) where date >= start {
            if seen.insert(path).inserted { ordered.append(path) }
        }
        return ordered.compactMap { session.change(for: $0) }
    }
}

/// A small window listing what every agent is doing; click a row to open its worktree.
struct AgentsWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let rows = model.agentRows
        let detailed = model.settings.agentsWindowDetailed
        Group {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No Agents Running", systemImage: "sparkles")
                } description: {
                    Text("Agents appear here while one is running in a watched worktree. Install hooks in Settings › Agents to see what each one is doing.")
                }
            } else {
                // A plain stack rather than a List: a table view keeps its scroll offset when a row
                // sorts to the top, which pushed the agent waiting on you under the title bar.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            HoverRow {
                                AgentDashboardRow(
                                    row: row, now: model.now, detailed: detailed,
                                    canGoToAgent: AgentApps.canGo(to: row.presence),
                                    onGoToAgent: { goToAgent(row) },
                                    onSummary: { summary(row) },
                                    onOpenFile: { path in show(row, path: path) })
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { show(row) }
                            .contextMenu {
                                Button("Show in Vigil") { show(row) }
                                Button("Go to Agent") { goToAgent(row) }
                                Button("Session Summary…") { summary(row) }
                                Divider()
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.session.id)])
                                }
                                Button("Open in Terminal") { Workspace.openTerminal(at: row.session.id) }
                            }
                            .help("Show \(row.session.displayName) in the main window")
                            if row.id != rows.last?.id { Divider().padding(.leading, 48) }
                        }
                    }
                    .padding(.vertical, 4)
                    .animation(.default, value: rows.map(\.id))
                }
            }
        }
        .frame(minWidth: 360, minHeight: 180)
        .navigationTitle("Agents")
        .navigationSubtitle(summaryLine(rows))
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: setting(\.agentsWindowDetailed)) {
                    Label("Details", systemImage: "rectangle.grid.1x2")
                }
                .help(detailed ? "Showing each agent's task, steps and files. Click for one line per agent." : "Show each agent's task, recent steps and files")
                Toggle(isOn: setting(\.agentsWindowFloats)) {
                    Label("Keep on Top", systemImage: model.settings.agentsWindowFloats ? "pin.fill" : "pin")
                }
                .help(model.settings.agentsWindowFloats ? "Floating above other windows. Click to stop." : "Keep this window above other windows")
            }
        }
    }

    private func setting(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { value in
                    var copy = model.settings
                    copy[keyPath: keyPath] = value
                    model.updateSettings(copy)
                })
    }

    private func summaryLine(_ rows: [AgentRow]) -> String {
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

    private func show(_ row: AgentRow, path: String? = nil) {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        model.select(worktree: row.session.id, path: path)
    }

    private func summary(_ row: AgentRow) {
        show(row)
        model.showSummary(for: row.session.id)
    }

    private func goToAgent(_ row: AgentRow) {
        guard let app = AgentApps.app(for: row.presence) else {
            NSSound.beep()
            return
        }
        app.activate()
    }
}

struct AgentDashboardRow: View {
    let row: AgentRow
    let now: Date
    var detailed = true
    var canGoToAgent = false
    var onGoToAgent: () -> Void = {}
    var onSummary: () -> Void = {}
    var onOpenFile: (String) -> Void = { _ in }

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

    /// With details on, the step list names the running tool, so the status line need not.
    private var statusText: String {
        if detailed, presence.source == .hooks, case .working = presence.activity, !presence.turnSteps.isEmpty {
            return "working"
        }
        return relative(presence.statusText)
    }

    private var timing: String {
        let base = presence.timing(now: now)
        guard detailed, presence.isWorking, presence.toolCallsThisTurn > 0 else { return base }
        return base + " · " + (presence.toolCallsThisTurn == 1 ? "1 step" : "\(presence.toolCallsThisTurn) steps")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: presence.systemImage)
                .font(.title3)
                .foregroundStyle(presence.tint)
                .frame(width: 24)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: detailed ? 5 : 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.session.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(row.repositoryName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(timing)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .help(presence.timingHelp)
                }
                Text("\(presence.kind.displayName) · \(statusText)")
                    .foregroundStyle(presence.needsAttention ? presence.tint : .primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if detailed {
                    details
                } else {
                    compactFooter
                }
            }
        }
        .padding(.vertical, detailed ? 7 : 5)
    }

    private var compactFooter: some View {
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

    @ViewBuilder
    private var details: some View {
        if let task = presence.task, !task.isEmpty {
            Label {
                Text(task)
                    .lineLimit(2)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: "text.bubble")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .help((presence.turnStartedAt == nil || presence.activity == .ready ? "Last task: " : "Task: ") + task)
        }
        let steps = Array(presence.turnSteps.suffix(3).reversed())
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(steps) { step in
                    StepLine(step: step, target: step.summary.map(relative), now: now)
                }
            }
            .padding(.top, 1)
        }
        if !row.files.isEmpty {
            FileChips(files: row.files, onOpen: onOpenFile)
        }
        HStack(spacing: 8) {
            if canGoToAgent {
                Button(action: onGoToAgent) {
                    Label("Go to agent", systemImage: "arrow.up.forward.app")
                }
                .help("Bring the app this agent runs in to the front")
            }
            Button(action: onSummary) {
                Label("Summary", systemImage: "doc.text")
            }
            .help("Write up this session as Markdown")
            Spacer(minLength: 6)
            ChangeSummary(session: row.session)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .padding(.top, 2)
    }
}

/// A row with a light highlight under the pointer.
private struct HoverRow<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 14)
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
            .onHover { hovering = $0 }
    }
}

/// One recent tool call: what kind of step, what it acted on, and how long ago.
private struct StepLine: View {
    let step: AgentToolCall
    let target: String?
    let now: Date

    private var icon: (name: String, color: Color) {
        switch step.category {
        case .edit: ("pencil", .blue)
        case .command: ("terminal", .green)
        case .read: ("doc.text", .secondary)
        case .search: ("magnifyingglass", .secondary)
        case .web: ("globe", .teal)
        case .subagent: ("person.2", .purple)
        case .question: ("questionmark.bubble", .orange)
        case .other: ("wrench.and.screwdriver", .secondary)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon.name)
                .foregroundStyle(icon.color)
                .frame(width: 14)
            Text(step.toolName)
                .fontWeight(.medium)
            if let target, !target.isEmpty {
                Text(target)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if let finished = step.finishedAt {
                Text(Format.relative(finished, to: now))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            } else {
                Text("running")
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
            }
        }
        .font(.system(.caption, design: .monospaced))
    }
}

/// Chips for the files touched this turn; flagged ones tinted. Click one to open its diff.
private struct FileChips: View {
    let files: [FileChange]
    let onOpen: (String) -> Void
    private static let limit = 6

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(files.prefix(Self.limit)) { file in
                Button {
                    onOpen(file.path)
                } label: {
                    HStack(spacing: 4) {
                        Text(file.fileName)
                        if !file.isBinary, let additions = file.additions, let deletions = file.deletions {
                            Text("+\(additions) −\(deletions)").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(file.isFlagged ? AnyShapeStyle(Color.orange.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                                in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(file.isFlagged ? Color.orange : Color.primary)
                }
                .buttonStyle(.plain)
                .help(file.flags.isEmpty ? file.path : file.path + "\n" + file.flags.map(\.message).joined(separator: "\n"))
            }
            if files.count > Self.limit {
                Text("+\(files.count - Self.limit) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            }
        }
    }
}

/// Lays children out left to right, wrapping onto new lines as needed.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
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
