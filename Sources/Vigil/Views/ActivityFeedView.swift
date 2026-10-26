import SwiftUI
import VigilCore

struct ActivityFeedView: View {
    @Environment(AppModel.self) private var model

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
                List(entries) { entry in
                    ActivityRow(entry: entry, showWorktree: model.activityScopeAll, now: model.now,
                                worktreeName: model.sessions[entry.worktreePath]?.displayName)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                }
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Activity")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Picker("Scope", selection: $model.activityScopeAll) {
                        Text("Worktree").tag(false)
                        Text("All").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 130)
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
                    .help("Showing: \(model.activityAgentFilter.title.lowercased()). Agents only keeps agents' events and the changes they made; hiding agent events keeps edits, commits and flags.")
                    Button {
                        model.clearActivity()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear the feed")
                    .disabled(model.activity.isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                Divider()
            }
            .background(.bar)
        }
        .onChange(of: model.activityScopeAll) { model.persistUISoon() }
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
            model.select(worktree: entry.worktreePath, path: entry.path)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: entry.kind.systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.head)
                    HStack(spacing: 6) {
                        if entry.additions != nil || entry.deletions != nil {
                            DeltaText(additions: entry.additions, deletions: entry.deletions)
                        }
                        if let detail = entry.detail {
                            Text(AgentText.shortenPaths(detail, in: entry.worktreePath)).lineLimit(1)
                        }
                        if showWorktree, let worktreeName {
                            Text(worktreeName).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(Format.relative(entry.date, to: now))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Format.dateTime.string(from: entry.date))
    }
}
