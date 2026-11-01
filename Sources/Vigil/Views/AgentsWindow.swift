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
        // Every agent working here: with two, each one's edits matter.
        let everyone = [presence] + presence.others
        guard let start = everyone.compactMap(\.turnStartedAt).min() else { return [] }
        var ordered: [String] = []
        var seen = Set<String>()
        for step in everyone.flatMap(\.turnSteps).sorted(by: { $0.startedAt > $1.startedAt }) where step.isMutating {
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
                    LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                        let collapsed = Set(model.settings.agentsWindowCollapsed)
                        ForEach(AgentSection.group(rows), id: \.section) { group in
                            let isCollapsed = collapsed.contains(group.section.key)
                            Section {
                                if !isCollapsed {
                                    // Keyed by section too: a lazy stack kept showing a card's old
                                    // state after it moved to another section.
                                    ForEach(group.rows) { row in
                                        card(row, detailed: detailed).id("\(group.section.rawValue) \(row.id)")
                                    }
                                }
                            } header: {
                                AgentSectionHeader(section: group.section, rows: group.rows, collapsed: isCollapsed) {
                                    toggle(group.section)
                                }
                            }
                        }
                    }
                    .padding([.horizontal, .bottom], 10)
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

    private func card(_ row: AgentRow, detailed: Bool) -> some View {
        AgentCard(presence: row.presence) {
            AgentDashboardRow(
                row: row, now: model.agentNow, detailed: detailed,
                canGoToAgent: AgentApps.canGo(to: row.presence),
                onGoToAgent: { goToAgent(row) },
                onSummary: { summary(row) },
                onOpenFile: { path in show(row, path: path) },
                onDismissCollision: { model.agentHub.dismissCollision(in: row.id) })
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
    }

    /// Folds a section to its header, or opens it; remembered across launches.
    private func toggle(_ section: AgentSection) {
        var copy = model.settings
        if let index = copy.agentsWindowCollapsed.firstIndex(of: section.key) {
            copy.agentsWindowCollapsed.remove(at: index)
        } else {
            copy.agentsWindowCollapsed.append(section.key)
        }
        withAnimation(.easeOut(duration: 0.2)) { model.updateSettings(copy) }
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
        openWindow.summary(for: row.session.id)
    }

    private func goToAgent(_ row: AgentRow) {
        AgentApps.bringForward(row.presence)
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
    var onDismissCollision: () -> Void = {}

    private var presence: AgentPresence { row.presence }

    private func relative(_ text: String) -> String { AgentText.shortenPaths(text, in: row.session.id) }

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

    /// "4 steps", beside the timer while the agent works.
    private var steps: String? {
        guard detailed, presence.isWorking, presence.toolCallsThisTurn > 0 else { return nil }
        return presence.toolCallsThisTurn == 1 ? "1 step" : "\(presence.toolCallsThisTurn) steps"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentBadge(presence: presence, size: 28)
            VStack(alignment: .leading, spacing: detailed ? 5 : 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Project first, then the branch: the project is what you recognize at a glance.
                    if !row.repositoryName.isEmpty {
                        Text(row.repositoryName)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                    }
                    Text(row.session.displayName)
                        .font(.title3)
                        .foregroundStyle(row.repositoryName.isEmpty ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if let steps {
                        Text(steps)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    AgentTimerPill(presence: presence, now: now)
                }
                Text("\(presence.kind.displayName) · \(statusText)")
                    .foregroundStyle(presence.source == .hooks && presence.activity.needsAttention ? presence.tint : .primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if let collision = presence.collision {
                    AgentCollisionNote(collision: collision, worktree: row.session.id, onDismiss: onDismissCollision)
                }
                if detailed {
                    details
                } else {
                    compactFooter
                }
                // After this agent's own steps and files, so none of them reads as another's.
                if !presence.others.isEmpty {
                    OtherAgentsList(others: presence.others, now: now, worktree: row.session.id)
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
                    StepLine(step: step, target: step.summary.map(relative), now: now, waiting: step.id == presence.awaitingCallID)
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

/// The Agents window's groups, in the order it lists them.
enum AgentSection: Int, Hashable, CaseIterable {
    case needsYou, working, ready, ended

    init(_ presence: AgentPresence) {
        self = AgentSection(rawValue: min(presence.urgency, AgentSection.ended.rawValue)) ?? .ended
    }

    /// What the settings remember a collapsed section by.
    var key: String { String(describing: self) }

    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .ready: "Ready"
        case .ended: "Ended"
        }
    }

    var tint: Color {
        switch self {
        case .needsYou: .orange
        case .working: .blue
        case .ready: .green
        case .ended: .secondary
        }
    }

    /// `rows` in their sections, keeping their order; empty sections left out.
    static func group(_ rows: [AgentRow]) -> [(section: AgentSection, rows: [AgentRow])] {
        let bySection = Dictionary(grouping: rows) { AgentSection($0.presence) }
        return allCases.compactMap { section in bySection[section].map { (section, $0) } }
    }
}

/// "Needs you 2" on a rounded tab of the section's colour, pinned above its agents while they
/// scroll. Click it to fold the section to its header, which then shows who is in it.
private struct AgentSectionHeader: View {
    let section: AgentSection
    let rows: [AgentRow]
    let collapsed: Bool
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                CountBadge(count: rows.count, tint: section.tint)
                Spacer(minLength: 6)
                if collapsed {
                    HStack(spacing: 3) {
                        ForEach(rows.prefix(8)) { row in
                            AgentBadge(presence: row.presence, size: 18)
                        }
                        if rows.count > 8 {
                            Text("+\(rows.count - 8)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .foregroundStyle(section.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(section.tint.opacity(hovering ? 0.2 : 0.13), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.top, 6)
        .padding(.bottom, 2)
        // Pinned, it hides the cards scrolling under it.
        .background(Color(nsColor: .windowBackgroundColor))
        .help(collapsed ? "Show these agents" : "Fold these agents away")
        .accessibilityLabel("\(section.title), \(rows.count == 1 ? "1 agent" : "\(rows.count) agents")")
        .accessibilityValue(collapsed ? "collapsed" : "expanded")
        .accessibilityAddTraits(.isHeader)
    }
}

/// An agent's row as a card tinted by its state, like the banner above the diff; a little
/// stronger under the pointer.
private struct AgentCard<Content: View>: View {
    let presence: AgentPresence
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .agentCard(presence, highlighted: hovering)
            .onHover { hovering = $0 }
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
                DiffBar(additions: session.changes.totalAdditions, deletions: session.changes.totalDeletions)
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
