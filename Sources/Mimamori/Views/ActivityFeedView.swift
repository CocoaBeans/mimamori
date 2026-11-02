import SwiftUI
import MimamoriCore

struct ActivityFeedView: View {
    @Environment(AppModel.self) private var model
    /// Agent runs opened to show their steps, by the run's id.
    @State private var openRuns: Set<UUID> = []

    private var entries: [ActivityEntry] {
        let filter = model.activityAgentFilter
        let selected = model.activityScopeAll ? nil : model.selectedWorktreeID
        guard selected != nil || filter != .all else { return model.activity }
        return model.activity.filter { entry in
            (selected == nil || entry.worktreePath == selected) && filter.includes(entry)
        }
    }

    private var emptyTitle: String {
        switch model.activityAgentFilter {
        case .all: "Quiet So Far"
        case .agentsOnly: "No Agent Activity"
        case .hideAgentEvents: "No Repository Activity"
        }
    }

    private var emptyDescription: String {
        switch model.activityAgentFilter {
        case .all: "Edits, commits and flags show up here as they happen."
        case .agentsOnly: "Agents' turns, tool calls and the changes they make show up here."
        case .hideAgentEvents: "Edits, commits and flags show up here; agents' own events are hidden."
        }
    }

    var body: some View {
        @Bindable var model = model
        let entries = entries
        Group {
            if entries.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: model.activityAgentFilter == .agentsOnly ? "sparkles" : "eye",
                                       description: Text(emptyDescription))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(ActivityFeedGrouping.items(entries)) { item in
                    Group {
                        switch item {
                        case .day(let day):
                            DayHeader(day: day, now: model.now)
                                .listRowSeparator(.hidden)
                        case .entry(let entry):
                            ActivityRow(entry: entry, showWorktree: model.activityScopeAll, now: model.now,
                                        worktreeName: model.sessions[entry.worktreePath]?.displayName)
                                .equatable()
                        case .run(let run):
                            AgentRunRow(run: run, showWorktree: model.activityScopeAll, now: model.now,
                                        worktreeName: model.sessions[run.worktreePath]?.displayName,
                                        isOpen: Binding(get: { openRuns.contains(run.id) || model.debugFlags.contains("open-runs") },
                                                        set: { if $0 { openRuns.insert(run.id) } else { openRuns.remove(run.id) } }))
                        }
                    }
                    // A faint line between entries, starting under the text rather than the icon.
                    .listRowSeparatorTint(Color.primary.opacity(0.08))
                    .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 6))
                }
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if !ActivityToolbar.isAvailable {
                        Text("Activity")
                            .font(.headline)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                    }
                    Picker("Activity from", selection: $model.activityScopeAll) {
                        Text("Worktree").tag(false)
                        Text("All").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 130)
                    .help("Show the selected worktree's activity, or every worktree's")
                    if ActivityToolbar.isAvailable {
                        Spacer(minLength: 4)
                    }
                    Menu {
                        Picker("Show", selection: $model.activityAgentFilter) {
                            ForEach(ActivityAgentFilter.allCases, id: \.self) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: model.activityAgentFilter == .all
                              ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Filter the feed")
                    .help("Showing: \(model.activityAgentFilter.title.lowercased()). Agents only keeps agents' events and the changes they made; hiding agent events keeps edits, commits and flags.")
                    Button {
                        model.clearActivity()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear the feed")
                    .accessibilityLabel("Clear the feed")
                    .disabled(model.activity.isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                Divider()
            }
            .background(.bar)
        }
        .activityToolbar(shown: model.showActivity)
        .onChange(of: model.activityScopeAll) { model.persistUISoon() }
    }
}

/// The pane's own part of the toolbar, on macOS 26: its title at the leading edge, where it stays
/// whole however narrow the pane is, then the Agents and Activity buttons at the trailing edge.
/// Earlier systems keep the title in the pane's header and the buttons in the window's toolbar.
struct ActivityToolbar {
    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }
}

#if compiler(>=6.2)
@available(macOS 26, *)
extension ActivityToolbar: ToolbarContent {
    var body: some ToolbarContent {
        // A title, so without the glass capsule a toolbar item sits on.
        ToolbarItem {
            Text("Activity")
                .font(.headline)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        ToolbarItem { AgentsToolbarButton() }
        ToolbarItem { ActivityToolbarToggle() }
    }
}
#endif

extension View {
    /// A closed inspector keeps its toolbar items, so they come and go with the pane.
    @ViewBuilder
    fileprivate func activityToolbar(shown: Bool) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            toolbar {
                if shown { ActivityToolbar() }
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// "Today", "Yesterday", or the date, above each day's entries.
struct DayHeader: View {
    let day: Date
    let now: Date

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return day.formatted(date: .complete, time: .omitted)
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// An agent's run of tool calls, folded into one row: who, what kinds of steps, which files.
/// Opening it lists every step and change in it.
struct AgentRunRow: View {
    let run: AgentRun
    let showWorktree: Bool
    let now: Date
    let worktreeName: String?
    @Binding var isOpen: Bool

    private var files: String? {
        let names = run.files.map { ($0 as NSString).lastPathComponent }
        guard let first = names.first else { return nil }
        return names.count == 1 ? first : names.count == 2 ? "\(first), \(names[1])" : "\(first) and \(names.count - 1) more"
    }

    var body: some View {
        let worktree = showWorktree ? worktreeName : nil
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: AgentKind.symbolName(forDisplayName: run.agent))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(run.agent): \(run.summary)")
                                .font(.callout)
                                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            // With nothing else to say below, the time comes up beside the title.
                            if files == nil && worktree == nil {
                                ActivityTime(date: run.latestAt, now: now)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(isOpen ? 90 : 0))
                        }
                        if files != nil || worktree != nil {
                            HStack(spacing: 6) {
                                if let files {
                                    Text(files).lineLimit(1)
                                }
                                if let worktree {
                                    Text(worktree).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                ActivityTime(date: run.latestAt, now: now)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Hide the steps" : "Show each step, \(Format.time.string(from: run.startedAt)) to \(Format.time.string(from: run.latestAt))")
            .accessibilityLabel("\(run.agent): \(run.summary)")
            .accessibilityHint(isOpen ? "Hides the steps" : "Shows each step")

            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(run.entries) { entry in
                        ActivityRow(entry: entry, showWorktree: false, now: now, worktreeName: nil)
                            .equatable()
                    }
                }
                .padding(.leading, 22)
            }
        }
    }
}

/// A new entry every few seconds rebuilds the visible rows; one whose inputs are unchanged need
/// not draw again.
extension ActivityRow: @preconcurrency Equatable {
    static func == (a: ActivityRow, b: ActivityRow) -> Bool {
        a.entry == b.entry && a.showWorktree == b.showWorktree && a.now == b.now && a.worktreeName == b.worktreeName
    }
}

struct ActivityRow: View {
    @Environment(AppModel.self) private var model
    let entry: ActivityEntry
    let showWorktree: Bool
    let now: Date
    let worktreeName: String?

    private var tint: Color {
        if let severity = entry.severity { return severity.color }
        switch entry.kind {
        case .created: return .green
        case .deleted: return .red
        case .modified: return .orange
        case .renamed: return .blue
        case .reverted: return .secondary
        case .committed: return .purple
        case .headMoved, .branchChanged: return .indigo
        case .started, .snapshot: return .accentColor
        case .flagged: return .orange
        case .watching: return .secondary
        case .agentSession: return .accentColor
        case .agentTurn: return .teal
        case .agentTool: return .secondary
        case .agentAttention: return .orange
        }
    }

    var body: some View {
        Button {
            if entry.kind == .committed, let commit = entry.detail {
                model.showCommit(commit, in: entry.worktreePath)
            } else {
                model.select(worktree: entry.worktreePath, path: entry.path)
            }
        } label: {
            let worktree = showWorktree ? worktreeName : nil
            let hasCounts = entry.additions != nil || entry.deletions != nil
            let hasDetails = hasCounts || entry.detail != nil || worktree != nil
            HStack(alignment: .top, spacing: 6) {
                // An agent's own entries show which agent; everything else what happened.
                Image(systemName: entry.kind.isAgentEvent ? entry.agent.map(AgentKind.symbolName(forDisplayName:)) ?? entry.kind.systemImage
                      : entry.kind.systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(entry.title)
                            .font(.callout)
                            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                            .lineLimit(2)
                            .truncationMode(.head)
                        // With nothing else to say below, the time comes up beside the title.
                        if !hasDetails {
                            Spacer(minLength: 4)
                            ActivityTime(date: entry.date, now: now)
                        }
                    }
                    if hasDetails {
                        HStack(spacing: 6) {
                            if hasCounts {
                                DeltaText(additions: entry.additions, deletions: entry.deletions)
                            }
                            if let detail = entry.detail {
                                Text(AgentText.shortenPaths(detail, in: entry.worktreePath)).lineLimit(1)
                            }
                            if let worktree {
                                Text(worktree).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            ActivityTime(date: entry.date, now: now)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.kind == .committed ? "\(Format.dateTime.string(from: entry.date)) · Show this commit"
                                        : Format.dateTime.string(from: entry.date))
    }
}

/// How long ago, in the feed's caption style; it keeps its size in a narrow column.
struct ActivityTime: View {
    let date: Date
    let now: Date

    var body: some View {
        Text(Format.relative(date, to: now))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize()
    }
}
