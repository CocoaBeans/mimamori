import SwiftUI
import MimamoriCore

/// The worktree's commits in the middle column: what the branch added since it left its base,
/// then earlier history. Selecting a commit expands it to its files.
struct CommitListView: View {
    @Environment(AppModel.self) private var model
    let session: WorktreeSession

    var body: some View {
        content
            .task(id: session.state?.branch.headOID) { session.loadHistoryIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if let history = session.history {
            let since = filtered(history.sinceBranchPoint)
            let earlier = filtered(history.earlier)
            if history.all.isEmpty {
                ContentUnavailableView("No Commits Yet", systemImage: "circle.dashed",
                                       description: Text("Commits on this branch show up here."))
            } else if since.isEmpty && earlier.isEmpty {
                ContentUnavailableView.search(text: model.filterText)
            } else {
                List(selection: Binding(get: { session.commitSelection }, set: { session.select($0) })) {
                    if !since.isEmpty {
                        Section {
                            rows(since)
                        } header: {
                            Text(sinceTitle(history) + " · \(history.sinceBranchPoint.count)")
                                .help(history.reference.map { "Commits on this branch that \($0) does not have" } ?? "")
                        }
                    }
                    if !earlier.isEmpty {
                        Section(history.reference.map { "On \($0)" } ?? "History") {
                            rows(earlier)
                            if history.hasMore && model.filterText.isEmpty {
                                Button {
                                    Task { await session.loadMoreHistory() }
                                } label: {
                                    Label(session.loadingHistory ? "Loading…" : "Load more commits", systemImage: "ellipsis")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .disabled(session.loadingHistory)
                                .help("Load the next 100 commits")
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        } else if let error = session.historyError {
            ContentUnavailableView("Could Not Read the History", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if session.state != nil && session.state?.branch.headOID == nil {
            ContentUnavailableView("No Commits Yet", systemImage: "circle.dashed",
                                   description: Text("Commits on this branch show up here."))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func rows(_ commits: [CommitRecord]) -> some View {
        ForEach(commits) { commit in
            CommitRow(commit: commit, now: model.now, isOpen: session.openCommit?.oid == commit.oid,
                      flaggedCount: session.openCommit?.oid == commit.oid ? session.openCommitChanges.flaggedCount : 0)
                .tag(CommitSelection.commit(commit.oid))
            if session.openCommit?.oid == commit.oid {
                if let error = session.openCommitError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.leading, 22)
                } else if session.openCommitChanges.isEmpty && commit.filesChanged > 0 {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 22)
                }
                ForEach(session.shownCommitChanges) { change in
                    ChangeRow(change: change, recency: 0, lastChanged: nil, now: model.now, worktreePath: session.id)
                        .padding(.leading, 22)
                        .tag(CommitSelection.file(commit: commit.oid, path: change.path))
                }
                if session.hiddenCommitChangeCount > 0 {
                    MoreCommitFilesButton(session: session)
                        .padding(.leading, 22)
                }
            }
        }
    }

    private func sinceTitle(_ history: CommitHistory) -> String {
        guard let reference = history.reference else { return "This branch" }
        // On the default branch, the reference is its upstream: these are not pushed yet.
        return reference.contains("/") ? "Not in \(reference)" : "Since branch point"
    }

    private func filtered(_ commits: [CommitRecord]) -> [CommitRecord] {
        let filter = model.filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !filter.isEmpty else { return commits }
        return commits.filter { commit in
            commit.subject.lowercased().contains(filter) || commit.author.lowercased().contains(filter)
                || commit.oid.hasPrefix(filter)
        }
    }
}

/// One commit in the list: its id and subject, then who made it, when, and how much it changed.
struct CommitRow: View {
    let commit: CommitRecord
    let now: Date
    var isOpen = false
    /// Files needing attention, once the commit is open and its files are known.
    var flaggedCount = 0

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(commit.shortOID)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                    Text(commit.subject)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 6) {
                    if commit.isMerge {
                        Image(systemName: "arrow.triangle.merge")
                            .help("A merge, shown against its first parent")
                    }
                    Text(commit.author)
                        .lineLimit(1)
                    Text(Format.relative(commit.date, to: now))
                        .monospacedDigit()
                    if commit.filesChanged > 0 {
                        Text("\(commit.filesChanged) \(commit.filesChanged == 1 ? "file" : "files")")
                        DeltaText(additions: commit.additions, deletions: commit.deletions)
                    }
                    if flaggedCount > 0 {
                        Label("\(flaggedCount)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("\(flaggedCount) of its files need attention")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .help(Format.dateTime.string(from: commit.date))
    }
}

/// Shows more of a large commit's files: they come a page at a time.
struct MoreCommitFilesButton: View {
    let session: WorktreeSession

    var body: some View {
        let hidden = session.hiddenCommitChangeCount
        Button {
            session.showMoreCommitFiles()
        } label: {
            Label("Show \(min(hidden, session.openCommitFileLimit)) more of \(hidden) remaining files",
                  systemImage: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("This commit changed \(session.openCommitChanges.count) files; they are listed a page at a time, files needing attention first.")
    }
}

/// The detail pane for a selected commit: its message, author and files.
struct CommitOverviewView: View {
    let session: WorktreeSession
    let commit: CommitRecord

    private var body_: String? {
        guard let message = session.openCommitMessage else { return nil }
        let lines = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let rest = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return rest.isEmpty ? nil : rest
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(commit.subject)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text(commit.oid)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        CopyButton(help: "Copy the commit id") { Workspace.copy(commit.oid) }
                            .buttonStyle(.borderless)
                    }
                    .foregroundStyle(.secondary)
                    Text("\(commit.author) · \(Format.dateTime.string(from: commit.date))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if commit.isMerge {
                        Label("Merge of \(commit.parents.map { String($0.prefix(7)) }.joined(separator: " and ")), shown against the first",
                              systemImage: "arrow.triangle.merge")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if let body_ {
                    Text(body_)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack(spacing: 8) {
                    Text("\(session.openCommitChanges.count) \(session.openCommitChanges.count == 1 ? "file" : "files") changed")
                    DeltaText(additions: session.openCommitChanges.totalAdditions, deletions: session.openCommitChanges.totalDeletions)
                    let flagged = session.openCommitChanges.flaggedCount
                    if flagged > 0 {
                        Label("\(flagged) \(flagged == 1 ? "needs" : "need") attention", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .font(.callout)
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(session.shownCommitChanges) { change in
                        Button {
                            session.select(.file(commit: commit.oid, path: change.path))
                        } label: {
                            ChangeRow(change: change, recency: 0, lastChanged: nil, now: Date(), worktreePath: session.id)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show this file's diff in the commit")
                    }
                    if session.hiddenCommitChangeCount > 0 {
                        MoreCommitFilesButton(session: session)
                    }
                }
                if let error = session.openCommitError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
