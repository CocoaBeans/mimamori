import SwiftUI
import VigilCore

struct ActivityFeedView: View {
    @Environment(AppModel.self) private var model

    private var entries: [ActivityEntry] {
        if model.activityScopeAll { return model.activity }
        guard let selected = model.selectedWorktreeID else { return model.activity }
        return model.activity.filter { $0.worktreePath == selected }
    }

    var body: some View {
        @Bindable var model = model
        let entries = entries
        Group {
            if entries.isEmpty {
                ContentUnavailableView("Quiet So Far", systemImage: "eye",
                                       description: Text("Edits, commits and flags show up here as they happen."))
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
                            Text(detail).lineLimit(1)
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
