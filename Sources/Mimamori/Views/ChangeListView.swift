import SwiftUI
import MimamoriCore

struct ChangeListView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: WorktreeSession

    var body: some View {
        @Bindable var model = model
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Picker("Changes or commits", selection: $model.showCommits) {
                        Text("Changes").tag(false)
                        Text("Commits").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .padding(.horizontal, 12)
                    .padding(.top, 9)
                    .help("Changed files in the working tree, or the branch's commits (⇧⌘H)")
                    WorktreeHeaderView(session: session)
                    HStack(spacing: 8) {
                        FilterField()
                        if !model.showCommits {
                            ListControls()
                        }
                        Divider().frame(height: 16)
                        SessionControls(session: session)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 9)
                    Divider()
                }
                .background(.bar)
            }
            .navigationTitle(session.displayName)
            .navigationSubtitle(Self.shortPath(session.id))
    }

    private var emptyFilterDescription: String {
        switch (model.flaggedOnly, model.hideReviewed) {
        case (true, true): "No file left to review needs attention."
        case (true, false): "No changed file needs attention."
        default: "Every changed file is hidden by the list's filters."
        }
    }

    /// The last two path components, enough to tell worktrees apart without a toolbar-wide subtitle.
    private static func shortPath(_ path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        return components.suffix(2).joined(separator: "/")
    }

    @ViewBuilder
    private var content: some View {
        if model.showCommits {
            CommitListView(session: session)
        } else {
            changeList
        }
    }

    @ViewBuilder
    private var changeList: some View {
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
                        .help("Snapshot the working tree now and compare against it (⇧⌘S)")
                }
                Button("Show Uncommitted") { session.setBaseline(.head) }
                    .help("Compare the working tree with HEAD instead (⌘1)")
            }
        } else {
            let rows = model.listedChanges(in: session)
            if rows.isEmpty {
                emptyList
            } else {
                List(selection: $session.selectedPath) {
                    ForEach(rows) { row in
                        let review = session.reviewStatus(of: row.change)
                        ChangeRow(change: row.change, recency: row.recency, lastChanged: row.lastChanged,
                                  now: model.now, worktreePath: session.id,
                                  attribution: session.attributions[row.change.path],
                                  review: review,
                                  onToggleReviewed: { session.setReviewed(!review.isReviewed, paths: [row.change.path]) })
                            .equatable()
                            .tag(row.change.path)
                            .listRowBackground(rowBackground(recency: row.recency, selected: session.selectedPath == row.change.path))
                    }
                }
                .listStyle(.inset)
                .animation(.default, value: rows.map(\.id))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    HiddenChangesBar(hidden: model.hiddenChanges(in: session))
                }
            }
        }
    }

    private func rowBackground(recency: Double, selected: Bool) -> some View {
        Color.accentColor.opacity(selected ? 0 : 0.14 * recency)
    }

    @ViewBuilder
    private var emptyList: some View {
        let hidden = model.hiddenChanges(in: session)
        if session.changes.isEmpty {
            ContentUnavailableView("No Changes", systemImage: "checkmark.circle",
                                   description: Text("The working tree matches \(session.state?.baseline.label ?? "the baseline")."))
        } else if hidden.reasons == [.search] {
            ContentUnavailableView.search(text: model.filterText)
        } else if hidden.reasons == [.reviewed] {
            ContentUnavailableView {
                Label("Nothing Left to Review", systemImage: "checkmark.circle")
            } description: {
                Text("You have reviewed all \(session.changes.count) changed files, and To review hides them. Files an agent edits again come back here.")
            } actions: {
                Button("Show Reviewed Files") { model.hideReviewed = false }
                    .help("Turn off To review and list every changed file (⌥⌘R)")
            }
        } else {
            ContentUnavailableView {
                Label("Nothing to Show", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(emptyFilterDescription + " " + hidden.summary(searchText: model.filterText) + ".")
            } actions: {
                Button("Show All Files") { model.showAllChanges() }
                    .help("Turn off every filter on the list")
            }
        }
    }
}

/// The header's review count, which doubles as the To review filter: on, the list shows only
/// files you have not reviewed yet.
struct ToReviewToggle: View {
    @Environment(AppModel.self) private var model
    let session: WorktreeSession

    var body: some View {
        @Bindable var model = model
        let left = session.unreviewedCount
        Toggle(isOn: $model.hideReviewed) {
            if left == 0 {
                Label("All reviewed", systemImage: "checkmark.circle.fill")
            } else {
                Label("\(left) to review", systemImage: model.hideReviewed
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(model.hideReviewed ? .accentColor : nil)
        .fixedSize()
        .help(model.hideReviewed
              ? "Showing only files to review. Click to show reviewed files too (⌥⌘R)."
              : "\(session.reviewedCount) of \(session.changes.count) reviewed. Click to show only files to review (⌥⌘R); ⌘↩ marks the selected file reviewed and moves to the next.")
    }
}

/// Says how many files the list's filters hide, and brings them back.
struct HiddenChangesBar: View {
    @Environment(AppModel.self) private var model
    let hidden: HiddenChanges

    var body: some View {
        if hidden.total > 0 {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(hidden.summary(searchText: model.filterText))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Button(hidden.reasons.count == 1 ? "Show" : "Show All") { model.showAllChanges() }
                        .buttonStyle(.borderless)
                        .help("Turn off the filters hiding these files")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
    }
}

/// How many changed files the list's filters hide, each counted under the first filter that hides it.
struct HiddenChanges: Equatable {
    enum Reason: Hashable { case reviewed, unflagged, search }
    var reviewed = 0
    var unflagged = 0
    var search = 0

    var total: Int { reviewed + unflagged + search }
    var reasons: Set<Reason> {
        var reasons = Set<Reason>()
        if reviewed > 0 { reasons.insert(.reviewed) }
        if unflagged > 0 { reasons.insert(.unflagged) }
        if search > 0 { reasons.insert(.search) }
        return reasons
    }

    /// "4 reviewed files hidden", or for several filters "6 files hidden by To review and Flagged only".
    func summary(searchText: String) -> String {
        func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }
        switch reasons {
        case [.reviewed]: return reviewed == 1 ? "1 reviewed file hidden" : "\(reviewed) reviewed files hidden"
        case [.unflagged]: return "\(files(unflagged)) without flags hidden"
        case [.search]: return "\(files(search)) not matching “\(searchText.trimmingCharacters(in: .whitespaces))”"
        default:
            var names: [String] = []
            if reviewed > 0 { names.append("To review") }
            if unflagged > 0 { names.append("Flagged only") }
            if search > 0 { names.append("the filter") }
            let joined = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names.joined()
            return "\(files(total)) hidden by \(joined)"
        }
    }
}

/// One file in the change list, with how recently it changed.
struct ListedChange: Identifiable, Hashable {
    let change: FileChange
    let recency: Double
    let lastChanged: Date?
    var id: String { change.path }
}

extension AppModel {
    /// What the list's filters hide in `session`, for saying so under the list.
    func hiddenChanges(in session: WorktreeSession) -> HiddenChanges {
        let filter = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        var hidden = HiddenChanges()
        for change in session.changes {
            if hideReviewed && session.reviewStatus(of: change).isReviewed {
                hidden.reviewed += 1
            } else if flaggedOnly && !change.isFlagged {
                hidden.unflagged += 1
            } else if !filter.isEmpty && !change.path.lowercased().contains(filter) && !(change.oldPath?.lowercased().contains(filter) ?? false) {
                hidden.search += 1
            }
        }
        return hidden
    }

    /// Turns off every filter on the change list.
    func showAllChanges() {
        hideReviewed = false
        flaggedOnly = false
        filterText = ""
    }

    /// The session's changes as the list shows them: filtered and sorted.
    func listedChanges(in session: WorktreeSession) -> [ListedChange] {
        let now = self.now
        let window = max(5, settings.recencyWindowSeconds)
        let filter = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        var rows: [ListedChange] = []
        rows.reserveCapacity(session.changes.count)
        for change in session.changes {
            if flaggedOnly && !change.isFlagged { continue }
            if hideReviewed && session.reviewStatus(of: change).isReviewed { continue }
            if !filter.isEmpty && !change.path.lowercased().contains(filter) && !(change.oldPath?.lowercased().contains(filter) ?? false) { continue }
            let date = session.lastChanged[change.path]
            let recency = date.map { max(0, 1 - now.timeIntervalSince($0) / window) } ?? 0
            rows.append(ListedChange(change: change, recency: recency, lastChanged: date))
        }
        switch sortOrder {
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


/// A row whose file, timing, attribution and review mark are unchanged need not draw again. The
/// review action is left out: it always toggles this row's own path.
extension ChangeRow: @preconcurrency Equatable {
    static func == (a: ChangeRow, b: ChangeRow) -> Bool {
        a.change == b.change && a.recency == b.recency && a.lastChanged == b.lastChanged && a.now == b.now
            && a.worktreePath == b.worktreePath && a.attribution == b.attribution && a.review == b.review
            && (a.onToggleReviewed == nil) == (b.onToggleReviewed == nil)
    }
}

struct ChangeRow: View {
    let change: FileChange
    let recency: Double
    let lastChanged: Date?
    let now: Date
    let worktreePath: String
    var attribution: ChangeAttribution? = nil
    var review: ReviewStatus = .unreviewed
    var onToggleReviewed: (() -> Void)? = nil

    private var visibleFlags: [AttentionFlag] {
        change.flags.filter { $0.severity >= .warning }.sorted { $0.severity > $1.severity }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusGlyph(kind: change.kind)
                .padding(.top, 1)
                .opacity(review.isReviewed ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    FileTypeIcon(path: change.path)
                        .font(.caption)
                        .frame(width: 14)
                        .padding(.trailing, 4)
                    if !change.directory.isEmpty {
                        Text(change.directory + "/")
                            .foregroundStyle(.secondary)
                    }
                    Text(change.fileName)
                        .fontWeight(review.isReviewed ? .regular : .medium)
                        .foregroundStyle(review.isReviewed ? .secondary : .primary)
                        // The folder gives way first.
                        .layoutPriority(1)
                }
                .lineLimit(1)
                .truncationMode(.head)
                if case .changedSinceReview(let mark) = review {
                    Label("changed since your review", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .help("You reviewed this file at \(Format.time.string(from: mark.reviewedAt)); it has changed since")
                }
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
                if let attribution {
                    Label(attribution.label, systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 5) {
                    if review.isReviewed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Reviewed")
                    }
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
            if let onToggleReviewed {
                Button(review.isReviewed ? "Mark as Not Reviewed" : "Mark as Reviewed", action: onToggleReviewed)
                Divider()
            }
            Button("Open") { Workspace.open(path: change.path, in: worktreePath) }
            Button("Reveal in Finder") { Workspace.reveal(path: change.path, in: worktreePath) }
            Button("Copy Path") { Workspace.copy(change.path) }
        }
    }
}

struct WorktreeHeaderView: View {
    @Environment(AppModel.self) private var model
    let session: WorktreeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(session.state?.branch.displayName ?? session.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let branch = session.state?.branch {
                    if let ahead = branch.ahead, ahead > 0 {
                        Text("↑\(ahead)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let behind = branch.behind, behind > 0 {
                        Text("↓\(behind)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Text("\(session.changes.count) files")
                        .foregroundStyle(.secondary)
                    if !model.showCommits && !session.changes.isEmpty {
                        ToReviewToggle(session: session)
                    }
                    // No bar: the branch name needs the room more than one total does.
                    DeltaText(additions: session.changes.totalAdditions, deletions: session.changes.totalDeletions, bar: false)
                    AttentionBadgeButton(sessions: [session], arrowEdge: .top, debugID: "header")
                }
                .font(.caption.monospacedDigit())
                .fixedSize()
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
            if !model.showCommits {
                HStack(spacing: 8) {
                    BaselinePicker(session: session)
                        .controlSize(.small)
                    if let state = session.state, state.baseline.baseline != .head {
                        Text(state.baseline.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
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
                .lineLimit(1)
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
                    .lineLimit(1)
                    .help(excluded.joined(separator: "\n"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// Inline filter for the change list. ⌘F focuses it; Escape clears it.
struct FilterField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(model.showCommits ? "Filter commits" : "Filter files", text: $model.filterText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand {
                    model.filterText = ""
                    focused = false
                }
            if !model.filterText.isEmpty {
                Button {
                    model.filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
                .accessibilityLabel("Clear the filter")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        .onChange(of: model.filterFocusToken) { focused = true }
    }
}

/// The flagged-only toggle and the sort menu for the change list.
struct ListControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 4) {
            Toggle(isOn: $model.flaggedOnly) {
                Image(systemName: model.flaggedOnly ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .tint(.orange)
            .help("Show only files that need attention (⇧⌘F)")
            .accessibilityLabel("Flagged only")

            Menu {
                Picker("Sort By", selection: $model.sortOrder) {
                    ForEach(ChangeSortOrder.allCases, id: \.self) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort: \(model.sortOrder.title)")
            .accessibilityLabel("Sort")
        }
        .controlSize(.small)
    }
}

/// Mark Start, the session summary and Refresh, next to the filter.
struct SessionControls: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let session: WorktreeSession

    var body: some View {
        HStack(spacing: 4) {
            Button {
                Task { await session.markStart() }
            } label: {
                Image(systemName: session.startSnapshot == nil ? "flag" : "flag.fill")
            }
            .help("Mark Start: snapshot the working tree now and compare against it (⇧⌘S)")
            .accessibilityLabel("Mark start")
            Button {
                openWindow.summary(for: session.id)
            } label: {
                Image(systemName: "doc.text")
            }
            .help("Session summary: what changed, what needs a look and what the agent did, as Markdown (⇧⌘E)")
            .accessibilityLabel("Session summary")
            Button {
                session.requestRefresh(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh now (⌘R)")
            .accessibilityLabel("Refresh")
            .disabled(session.isBusy)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}
