import SwiftUI
import VigilCore

struct ChangeListView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: WorktreeSession

    private struct Row: Identifiable, Hashable {
        let change: FileChange
        let recency: Double
        let lastChanged: Date?
        var id: String { change.path }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            WorktreeHeaderView(session: session)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .searchable(text: $model.filterText, placement: .toolbar, prompt: "Filter files")
        .navigationTitle(session.displayName)
        .navigationSubtitle(Format.abbreviate(path: session.id))
    }

    @ViewBuilder
    private var content: some View {
        if session.state == nil {
            switch session.phase {
            case .failed, .missing:
                ContentUnavailableView("Cannot Watch This Worktree", systemImage: "exclamationmark.triangle",
                                       description: Text(session.lastError ?? "Unknown error"))
            default:
                VStack(spacing: 12) {
                    ProgressView()
                    Text(session.phase == .indexing ? "Indexing the working tree…" : "Starting…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let state = session.state, !state.baseline.isAvailable {
            ContentUnavailableView {
                Label(state.baseline.baseline.title, systemImage: "arrow.left.arrow.right")
            } description: {
                Text(state.baseline.unavailableReason ?? "This comparison is not available.")
            } actions: {
                if state.baseline.baseline == .start {
                    Button("Mark Start Now") { Task { await session.markStart() } }
                }
                Button("Show Uncommitted") { session.setBaseline(.head) }
            }
        } else {
            let rows = rows
            if rows.isEmpty {
                if session.changes.isEmpty {
                    ContentUnavailableView("No Changes", systemImage: "checkmark.circle",
                                           description: Text("The working tree matches \(session.state?.baseline.label ?? "the baseline")."))
                } else {
                    ContentUnavailableView.search(text: model.filterText)
                }
            } else {
                List(selection: $session.selectedPath) {
                    ForEach(rows) { row in
                        ChangeRow(change: row.change, recency: row.recency, lastChanged: row.lastChanged,
                                  now: model.now, worktreePath: session.id)
                            .tag(row.change.path)
                            .listRowBackground(rowBackground(recency: row.recency, selected: session.selectedPath == row.change.path))
                    }
                }
                .listStyle(.inset)
                .animation(.default, value: rows.map(\.id))
            }
        }
    }

    private func rowBackground(recency: Double, selected: Bool) -> some View {
        Color.accentColor.opacity(selected ? 0 : 0.14 * recency)
    }

    private var rows: [Row] {
        let now = model.now
        let window = max(5, model.settings.recencyWindowSeconds)
        let filter = model.filterText.trimmingCharacters(in: .whitespaces).lowercased()
        var rows: [Row] = []
        rows.reserveCapacity(session.changes.count)
        for change in session.changes {
            if model.flaggedOnly && !change.isFlagged { continue }
            if !filter.isEmpty && !change.path.lowercased().contains(filter) && !(change.oldPath?.lowercased().contains(filter) ?? false) { continue }
            let date = session.lastChanged[change.path]
            let recency = date.map { max(0, 1 - now.timeIntervalSince($0) / window) } ?? 0
            rows.append(Row(change: change, recency: recency, lastChanged: date))
        }
        switch model.sortOrder {
        case .recent:
            rows.sort { a, b in
                switch (a.lastChanged, b.lastChanged) {
                case let (x?, y?) where x != y: return x > y
                case (.some, .none): return true
                case (.none, .some): return false
                default: return a.change.path < b.change.path
                }
            }
        case .path:
            rows.sort { $0.change.path < $1.change.path }
        case .severity:
            rows.sort { a, b in
                let sa = a.change.maxSeverity?.rawValue ?? -1
                let sb = b.change.maxSeverity?.rawValue ?? -1
                if sa != sb { return sa > sb }
                if a.change.flags.count != b.change.flags.count { return a.change.flags.count > b.change.flags.count }
                return a.change.path < b.change.path
            }
        case .size:
            rows.sort { a, b in
                let da = (a.change.additions ?? 0) + (a.change.deletions ?? 0)
                let db = (b.change.additions ?? 0) + (b.change.deletions ?? 0)
                if da != db { return da > db }
                return a.change.path < b.change.path
            }
        }
        return rows
    }
}

struct ChangeRow: View {
    let change: FileChange
    let recency: Double
    let lastChanged: Date?
    let now: Date
    let worktreePath: String

    private var visibleFlags: [AttentionFlag] {
        change.flags.filter { $0.severity >= .warning }.sorted { $0.severity > $1.severity }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusGlyph(kind: change.kind)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    if !change.directory.isEmpty {
                        Text(change.directory + "/")
                            .foregroundStyle(.tertiary)
                    }
                    Text(change.fileName)
                        .fontWeight(.medium)
                }
                .lineLimit(1)
                .truncationMode(.head)
                if let old = change.oldPath {
                    Text("from \(old)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                ForEach(visibleFlags.prefix(2)) { flag in
                    Label(flag.message, systemImage: flag.rule.systemImage)
                        .font(.caption)
                        .foregroundStyle(flag.severity.color)
                        .lineLimit(1)
                }
                if visibleFlags.count > 2 {
                    Text("+\(visibleFlags.count - 2) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 5) {
                    FlagIcons(flags: change.flags.filter { $0.severity == .info })
                    if change.isUntracked {
                        Text("new")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    if change.isBinary {
                        Text("binary")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        DeltaText(additions: change.additions, deletions: change.deletions)
                    }
                }
                if let lastChanged, recency > 0 {
                    Text(Format.relative(lastChanged, to: now))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(change.flags.map(\.message).joined(separator: "\n"))
        .contextMenu {
            Button("Open") { Workspace.open(path: change.path, in: worktreePath) }
            Button("Reveal in Finder") { Workspace.reveal(path: change.path, in: worktreePath) }
            Button("Copy Path") { Workspace.copy(change.path) }
        }
    }
}

struct WorktreeHeaderView: View {
    let session: WorktreeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(session.state?.branch.displayName ?? session.displayName)
                    .font(.headline)
                    .lineLimit(1)
                if let branch = session.state?.branch {
                    if let ahead = branch.ahead, ahead > 0 {
                        Text("↑\(ahead)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let behind = branch.behind, behind > 0 {
                        Text("↓\(behind)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if session.isBusy {
                    ProgressView().controlSize(.small)
                } else if session.watcherActive {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                        .help("Watching the file system for changes")
                } else {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                        .help("Polling for changes")
                }
            }
            if let branch = session.state?.branch, let subject = branch.headSubject {
                HStack(spacing: 6) {
                    Text(branch.shortHead ?? "")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(subject)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 10) {
                if let state = session.state {
                    Label(state.baseline.label, systemImage: "arrow.left.arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(session.changes.count) files")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                DeltaText(additions: session.changes.totalAdditions, deletions: session.changes.totalDeletions)
                if session.flaggedCount > 0 {
                    Label("\(session.flaggedCount)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.orange)
                        .help("Files needing attention")
                }
            }
            if let start = session.startSnapshot {
                HStack(spacing: 6) {
                    Image(systemName: "flag.fill").foregroundStyle(Color.accentColor)
                    Text("Start marked \(Format.dateTime.string(from: start.date))")
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(session.snapshots.count) snapshots")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if let error = session.lastError, session.state != nil {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if let excluded = session.state?.excludedLargeFiles, !excluded.isEmpty {
                Label("\(excluded.count) large untracked files are not diffed", systemImage: "externaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(excluded.joined(separator: "\n"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
