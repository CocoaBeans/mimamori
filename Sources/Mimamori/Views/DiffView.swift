import SwiftUI
import MimamoriCore

struct DiffView: View {
    @Environment(AppModel.self) private var model
    let session: WorktreeSession
    let change: FileChange
    /// Shows the change as one commit made it, against its parent, rather than in the working tree.
    var commit: CommitRecord? = nil

    /// The diff on screen, set in one go when a load finishes.
    @State private var loaded: LoadedDiff?
    @State private var errorText: String?
    @State private var showAll = false
    @State private var targetLineID: Int?
    /// The file and reviewed version for which you chose the full diff over the since-review one.
    @State private var fullDiffKey: String?
    /// A reviewed blob found missing from the object store.
    @State private var missingReviewBlob: String?
    /// A line to jump to once the full diff has loaded.
    @State private var pendingJump: Int?
    /// Where the note being written goes, if one is. It lives in the model: closing the main window
    /// drops its views, and a half-written note outlives that. A commit's diff takes no notes.
    private var noteDraft: NoteDraft? {
        get { commit == nil ? model.noteDraft : nil }
        nonmutating set { if commit == nil { model.noteDraft = newValue } }
    }
    /// Its words, which only the composer reads as it draws.
    private var noteText: NoteDraftText { model.noteDraftText }
    /// Debug builds: the `discard:` flags open their confirmation once per launch.
    @MainActor private static var openedDebugDiscard = false

    private var diff: FileDiff? { loaded?.diff }
    private var loadedSinceReview: Bool { loaded?.source == .sinceReview }

    private var review: ReviewStatus { commit == nil ? session.reviewStatus(of: change) : .unreviewed }

    /// The blob you reviewed, when the file has changed since and a text diff against it makes sense.
    private var reviewedBlob: String? {
        guard case .changedSinceReview(let mark) = review, change.newOID != nil,
              !change.isBinary, !change.isSubmodule else { return nil }
        return mark.blob
    }

    private var sinceReviewKey: String { "\(change.path)|\(reviewedBlob ?? "")" }
    private var wantsSinceReview: Bool { reviewedBlob != nil && fullDiffKey != sinceReviewKey }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    DiffHeaderView(change: change, diff: diff, worktreePath: session.id,
                                   attribution: commit == nil ? session.attributions[change.path] : nil,
                                   review: review, sinceReview: sinceReviewInfo,
                                   onToggleReviewed: commit == nil ? { model.toggleReviewForSelection() } : nil,
                                   notesMenu: notesMenu, onDiscardFile: discardFileAction) { lineNumber in
                        jump(toNewLine: lineNumber)
                    }
                    Divider()
                }
                .background(.bar)
            }
            .task(id: "\(commit?.oid ?? "")|\(change.contentKey)|\(reviewedBlob ?? "")|\(wantsSinceReview)|\(model.settings.syntaxHighlighting)") {
                showAll = false
                targetLineID = nil
                if noteDraft?.editing == nil, noteText.text.isEmpty { noteDraft = nil }
                await load()
                // MIMAMORI_DEBUG_FLAGS=diff-line:<n>: jump to new-file line n, as a flag's link does.
                if let flag = model.debugFlags.first(where: { $0.hasPrefix("diff-line:") }),
                   let number = Int(flag.dropFirst("diff-line:".count)) {
                    jump(toNewLine: number)
                }
                // MIMAMORI_DEBUG_FLAGS=note-line:<n> or note-line:<n>-<m>: start a note there, as its bubble does.
                if commit == nil, let flag = model.debugFlags.first(where: { $0.hasPrefix("note-line:") }), noteDraft == nil, let diff {
                    let bounds = flag.dropFirst("note-line:".count).split(separator: "-").compactMap { Int($0) }
                    if let first = bounds.first, let last = bounds.last, first <= last,
                       let hunk = diff.hunks.first(where: { $0.lines.contains { $0.newNumber == first && $0.kind != .deletion } }) {
                        noteText.text = ""
                        noteDraft = NoteDraft(side: .new, lines: first...last, hunk: hunk.id)
                    }
                }
                // MIMAMORI_DEBUG_FLAGS=discard:<n> or discard:file, with :confirm to go ahead: ask to discard
                // hunk n or the whole file, as their buttons do.
                if let flag = model.debugFlags.first(where: { $0.hasPrefix("discard:") }), !Self.openedDebugDiscard {
                    let target = flag.split(separator: ":")[1]
                    let confirms = flag.hasSuffix(":confirm")
                    if target == "file", let discardFileAction {
                        Self.openedDebugDiscard = true
                        discardFileAction()
                        session.discardRequest?.confirmsItself = confirms
                    } else if let number = Int(target), let diff, number >= 1, number <= diff.hunks.count, let discardAction {
                        Self.openedDebugDiscard = true
                        discardAction(diff.hunks[number - 1])
                        session.discardRequest?.confirmsItself = confirms
                    }
                }
            }
    }

    /// The diff on screen when it is the working tree's full diff of the version of the file
    /// listed now: the only one whose hunks can be thrown away.
    private var fullWorkingDiff: (loaded: LoadedDiff, change: FileChange)? {
        guard commit == nil, let loaded, case .workingTree(let made) = loaded.source,
              made.contentKey == change.contentKey else { return nil }
        return (loaded, made)
    }

    /// Asks to throw a hunk away, where that's offered: in the working tree's diff against HEAD,
    /// as loaded for the version of the file listed now.
    private var discardAction: ((DiffHunk) -> Void)? {
        guard session.offersDiscarding, let working = fullWorkingDiff,
              Discarding.hunkUnsupportedReason(for: working.change) == nil else {
            return nil
        }
        let session = session
        return { hunk in
            session.discardRequest = DiscardRequest(change: working.change, scope: .hunk(hunk),
                                                    diff: working.loaded.diff, decorations: working.loaded.decorations)
        }
    }

    /// Asks to put the whole file back as HEAD has it. The diff on screen goes with it when it is
    /// the full one; otherwise the confirmation reads it.
    private var discardFileAction: (() -> Void)? {
        guard commit == nil, session.offersDiscarding, Discarding.fileUnsupportedReason(for: change) == nil else { return nil }
        let full = fullWorkingDiff?.loaded
        let session = session
        let change = change
        return {
            session.discardRequest = DiscardRequest(change: change, scope: .file, diff: full?.diff,
                                                    decorations: full?.decorations ?? .empty)
        }
    }

    /// The file's notes, in the working tree only: a commit's diff is history.
    private var noteContext: DiffNotes? {
        guard commit == nil else { return nil }
        let session = session
        return DiffNotes(
            notes: session.notes.notes(for: change.path), currentBlob: change.newOID, showsOldSide: !loadedSinceReview,
            add: { [path = change.path] side, lines, quote, text in
                session.addNote(path: path, side: side, lines: lines, quote: quote, text: text)
            },
            edit: { session.editNote($0, text: $1) },
            delete: { session.deleteNote($0) },
            setResolved: { session.setNoteResolved($0, $1) })
    }

    private var notesMenu: DiffHeaderView.NotesMenu? {
        guard commit == nil else { return nil }
        let fileNotes = session.notes.unsent.filter { $0.path == change.path }
        let all = session.notes.unsent
        return DiffHeaderView.NotesMenu(
            open: session.notes.open.filter { $0.path == change.path }.count,
            fileUnsent: fileNotes.count, worktreeUnsent: all.count,
            canAddFileNote: diff.map { !$0.hunks.isEmpty } ?? false,
            addFileNote: {
                noteText.text = ""
                noteDraft = NoteDraft(lines: nil)
            },
            copyFile: { copyNotes(fileNotes) },
            copyAll: { copyNotes(all) })
    }

    /// Copies `notes` as one prompt to paste into the agent, by file and line, and records them as copied.
    private func copyNotes(_ notes: [ReviewNote]) {
        guard !notes.isEmpty else { return }
        let ordered = notes.sorted { ($0.path, $0.lines?.lowerBound ?? 0) < ($1.path, $1.lines?.lowerBound ?? 0) }
        Workspace.copy(ReviewNotePrompt.format(ordered, branch: session.displayName))
        session.markNotesSent(ordered.map(\.id), to: nil)
    }

    private var sinceReviewInfo: DiffHeaderView.SinceReview? {
        guard case .changedSinceReview(let mark) = review else { return nil }
        let unavailable: String?
        if change.newOID == nil {
            unavailable = "It was deleted after your review."
        } else if change.isBinary || change.isSubmodule {
            unavailable = nil
        } else if mark.blob == nil {
            unavailable = "The version you reviewed was not recorded."
        } else if missingReviewBlob == mark.blob {
            unavailable = "The version you reviewed is no longer stored, so this is the full diff."
        } else {
            unavailable = nil
        }
        let available = reviewedBlob != nil && missingReviewBlob != reviewedBlob
        return DiffHeaderView.SinceReview(
            reviewedAt: mark.reviewedAt,
            unavailableReason: unavailable,
            showingSinceReview: available
                ? Binding(get: { fullDiffKey != sinceReviewKey }, set: { fullDiffKey = $0 ? nil : sinceReviewKey })
                : nil,
            shown: loadedSinceReview ? diff : nil)
    }

    @ViewBuilder
    private var content: some View {
        if change.isSubmodule {
            ContentUnavailableView("Submodule Pointer Changed", systemImage: "shippingbox",
                                   description: Text(pointerDescription))
        } else if change.isBinary {
            ContentUnavailableView("Binary File", systemImage: "doc.zipper",
                                   description: Text(binaryDescription))
        } else if let loaded {
            if loaded.diff.hunks.isEmpty {
                ContentUnavailableView("No Text Changes", systemImage: "doc", description: Text(emptyDiffDescription(loaded.diff)))
            } else {
                DiffContentView(diff: loaded.diff, decorations: loaded.decorations, wrap: model.settings.wrapDiffLines,
                                sideBySide: model.settings.diffLayout == .sideBySide,
                                fontSize: model.settings.diffFontSize, showAll: $showAll, targetLineID: $targetLineID,
                                flags: AttentionFlag.byLine(change.flags),
                                currentBranch: commit == nil ? currentSideName : nil,
                                notes: noteContext, draft: Binding(get: { noteDraft }, set: { noteDraft = $0 }),
                                draftText: noteText, discard: discardAction)
            }
        } else if let errorText {
            ContentUnavailableView("Could Not Load Diff", systemImage: "exclamationmark.triangle",
                                   description: Text(errorText))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What a conflict's current side ("HEAD") is: the branch, or in a rebase what it replays onto.
    private var currentSideName: String? {
        guard let state = session.state else { return nil }
        if let operation = state.operation, operation.kind == .rebase { return operation.onto }
        return state.branch.branch
    }

    private func emptyDiffDescription(_ diff: FileDiff) -> String {
        if diff.isBinary { return "Binary content changed." }
        if change.kind == .renamed || diff.isRename { return "The file was renamed; its contents are unchanged." }
        if change.kind == .copied { return "The file was copied; its contents are unchanged." }
        if change.modeChanged { return "Only the file mode changed (\(change.oldMode) to \(change.newMode))." }
        return "Only metadata changed."
    }

    private var pointerDescription: String {
        "\(change.oldOID?.prefix(7) ?? "none") → \(change.newOID?.prefix(7) ?? "none")"
    }

    private var binaryDescription: String {
        switch change.kind {
        case .added: "A new binary file was added."
        case .deleted: "The binary file was deleted."
        default: "The binary content changed."
        }
    }

    private func jump(toNewLine number: Int) {
        guard let diff else { return }
        for hunk in diff.hunks {
            if let line = hunk.lines.first(where: { $0.newNumber == number }) {
                showAll = true
                targetLineID = line.id
                return
            }
        }
        // The flagged line predates your review: it is only in the full diff.
        if loadedSinceReview {
            pendingJump = number
            fullDiffKey = sinceReviewKey
        }
    }

    private func load() async {
        errorText = nil
        // Another file's diff goes at once; this file's stays up until its new one is ready.
        if loaded?.diff.path != change.path { loaded = nil }
        do {
            if wantsSinceReview, let blob = reviewedBlob {
                if let since = try await session.diffSinceReview(for: change, reviewedBlob: blob) {
                    await show(since, from: .sinceReview)
                    return
                }
                missingReviewBlob = blob
            }
            let full = if let commit {
                try await session.diff(for: change, in: commit)
            } else {
                try await session.diff(for: change)
            }
            if let full {
                await show(full, from: commit == nil ? .workingTree(change) : .commit)
                if commit == nil { session.reanchorNotes(in: full, for: change) }
            } else {
                loaded = nil
                errorText = "git produced no diff for this file."
            }
            if let line = pendingJump {
                pendingJump = nil
                jump(toNewLine: line)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Shows a diff with its colors and where it came from, all at once: it never flashes plain
    /// first, and Discard never goes with another diff's hunks.
    private func show(_ diff: FileDiff, from source: LoadedDiff.Source) async {
        let path = change.path
        let highlight = model.settings.syntaxHighlighting
        let decorations = await Task.detached(priority: .userInitiated) {
            DiffDecorations.compute(for: diff, path: path, highlightSyntax: highlight)
        }.value
        guard !Task.isCancelled else { return }
        loaded = LoadedDiff(diff: diff, decorations: decorations, source: source)
    }
}

/// A diff as shown, with its colors and what it was made from. One value, so none of the
/// three can be left over from an earlier load.
struct LoadedDiff {
    enum Source: Equatable {
        /// The working tree against the baseline, made from this version of the file.
        case workingTree(FileChange)
        /// The working tree against the version you reviewed.
        case sinceReview
        /// One commit against its parent.
        case commit
    }

    var diff: FileDiff
    /// Syntax colors and word emphasis, worked out off the main thread.
    var decorations: DiffDecorations
    var source: Source
}

struct DiffHeaderView: View {
    @Environment(AppModel.self) private var model
    let change: FileChange
    let diff: FileDiff?
    let worktreePath: String
    var attribution: ChangeAttribution? = nil
    var review: ReviewStatus = .unreviewed
    var sinceReview: SinceReview? = nil
    var onToggleReviewed: (() -> Void)? = nil
    var notesMenu: NotesMenu? = nil
    /// Asks to discard all of the file's changes; nil where that isn't offered.
    var onDiscardFile: (() -> Void)? = nil
    let onJump: (Int) -> Void

    /// The file's notes for the agent, and what you can do with them.
    struct NotesMenu {
        /// Notes on this file not yet resolved.
        var open: Int
        var fileUnsent: Int
        var worktreeUnsent: Int
        var canAddFileNote: Bool
        var addFileNote: () -> Void
        var copyFile: () -> Void
        var copyAll: () -> Void
    }

    /// How the file stands against the version you reviewed, when it changed since.
    struct SinceReview {
        var reviewedAt: Date
        /// Why there is no since-review diff to offer, when that is not obvious.
        var unavailableReason: String?
        /// Picks between the since-review and the full diff; nil when only the full diff exists.
        var showingSinceReview: Binding<Bool>?
        /// The since-review diff when it is the one on screen.
        var shown: FileDiff?
    }

    /// "Claude Code · Edit", then what the call acted on when that is not this file, which the
    /// header already names: "Claude Code · Bash · npm run format".
    private func attributionText(_ attribution: ChangeAttribution) -> String {
        guard let detail = attribution.detail.map({ AgentText.shortenPaths($0, in: worktreePath) }),
              detail != change.path else { return attribution.label }
        return attribution.label + " · " + detail
    }

    private var wrapBinding: Binding<Bool> {
        Binding(
            get: { model.settings.wrapDiffLines },
            set: { value in
                var copy = model.settings
                copy.wrapDiffLines = value
                model.updateSettings(copy)
            })
    }

    private var sideBySide: Bool { model.settings.diffLayout == .sideBySide }

    private var sideBySideBinding: Binding<Bool> {
        Binding(
            get: { sideBySide },
            set: { value in
                var copy = model.settings
                copy.diffLayout = value ? .sideBySide : .unified
                model.updateSettings(copy)
            })
    }

    private func reviewedToggle(_ onToggle: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { review.isReviewed }, set: { _ in onToggle() })) {
            Label("Reviewed", systemImage: review.isReviewed ? "checkmark.circle.fill" : "circle")
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help(review.isReviewed
              ? "You reviewed this version. Click to mark it as not reviewed (⌘↩)."
              : "Mark as reviewed and go to the next file to review (⌘↩)")
    }

    private func notesButton(_ menu: NotesMenu) -> some View {
        Menu {
            Button("Add Note on This File", action: menu.addFileNote)
                .disabled(!menu.canAddFileNote)
            Divider()
            Button("Copy This File's Notes as a Prompt" + (menu.fileUnsent > 0 ? " (\(menu.fileUnsent))" : ""), action: menu.copyFile)
                .disabled(menu.fileUnsent == 0)
            Button("Copy All Unsent Notes as a Prompt" + (menu.worktreeUnsent > 0 ? " (\(menu.worktreeUnsent))" : ""), action: menu.copyAll)
                .disabled(menu.worktreeUnsent == 0)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: menu.open > 0 ? "text.bubble.fill" : "text.bubble")
                if menu.open > 0 {
                    Text(menu.open, format: .number)
                        .monospacedDigit()
                }
            }
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(menu.open == 0
              ? "Notes for the agent: hover over a line and click its bubble, or add one on the whole file"
              : "Notes for the agent on this file: add one, or copy them as a prompt to paste where you talk to it")
        .accessibilityLabel("Notes")
        .accessibilityValue(menu.open == 1 ? "1 open note" : "\(menu.open) open notes")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Title row: only the path has to give way, everything else keeps its size.
            HStack(spacing: 8) {
                StatusGlyph(kind: change.kind)
                Text(change.path)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .layoutPriority(0)
                Spacer(minLength: 8)
                if let onToggleReviewed {
                    // Once the path is cut to nothing, the toggle drops its title: a header wider
                    // than the column would widen the window instead.
                    ViewThatFits(in: .horizontal) {
                        reviewedToggle(onToggleReviewed)
                            .labelStyle(.titleAndIcon)
                        reviewedToggle(onToggleReviewed)
                            .labelStyle(.iconOnly)
                    }
                    .layoutPriority(1)
                }
                HStack(spacing: 6) {
                    if let notesMenu {
                        notesButton(notesMenu)
                    }
                    Toggle(isOn: sideBySideBinding) {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .toggleStyle(.button)
                    .help(sideBySide
                          ? "Old and new side by side. Click for a single column (⌥⌘L)."
                          : "Show old and new side by side (⌥⌘L)")
                    .accessibilityLabel("Side by side")
                    Toggle(isOn: wrapBinding) {
                        Image(systemName: "arrow.turn.down.left")
                    }
                    .toggleStyle(.button)
                    .disabled(sideBySide)
                    .help(sideBySide
                          ? "Side by side always wraps long lines."
                          : model.settings.wrapDiffLines
                          ? "Long lines wrap. Click to scroll them horizontally instead (⌥⌘W)."
                          : "Long lines scroll horizontally. Click to wrap them (⌥⌘W).")
                    .accessibilityLabel("Wrap long lines")
                    CopyButton(help: "Copy the diff as a patch") { if let diff { Workspace.copy(diff.unifiedText) } }
                    .disabled(diff == nil || diff?.hunks.isEmpty == true)

                    Button {
                        Workspace.reveal(path: change.path, in: worktreePath)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal in Finder")
                    Button {
                        Workspace.open(path: change.path, in: worktreePath)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("Open with the default application")
                    .accessibilityLabel("Open with the default application")
                    .disabled(change.kind == .deleted)
                }
                .buttonStyle(.borderless)
                .fixedSize()
            }
            // Detail row: state tags, rename and mode notes, and the line counts.
            HStack(spacing: 8) {
                if change.isUntracked {
                    Tag("untracked")
                }
                if change.isStaged {
                    Tag("staged")
                }
                if change.kind == .deleted {
                    Tag("deleted")
                }
                if let attribution {
                    Label(attributionText(attribution), systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Changed at \(Format.time.string(from: attribution.at)) by this tool call")
                }
                if let old = change.oldPath {
                    Text("renamed from \(old)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(0)
                }
                if change.modeChanged {
                    Text("mode \(change.oldMode) → \(change.newMode)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Spacer(minLength: 8)
                if let onDiscardFile {
                    Button(action: onDiscardFile) {
                        Label(change.kind == .deleted ? "Bring Back…" : "Discard File…", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help(change.kind == .added ? "Discard this new file: move it to the Trash, after a snapshot"
                          : change.kind == .deleted ? "Bring this deleted file back as it is in the last commit, after a snapshot"
                          : "Discard all of this file's changes: put it back as it is in the last commit, after a snapshot")
                    .accessibilityLabel(change.kind == .deleted ? "Bring back file" : "Discard file")
                }
                if change.isBinary {
                    Text("binary")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    DeltaText(additions: change.additions, deletions: change.deletions)
                        .fixedSize()
                }
            }
            if let sinceReview {
                SinceReviewRow(info: sinceReview)
            }
            if !change.flags.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(change.flags.sorted { $0.severity > $1.severity }) { flag in
                        if let line = flag.line {
                            Button {
                                onJump(line)
                            } label: {
                                FlagLine(flag: flag, lineLabel: "line \(line)")
                            }
                            .buttonStyle(.plain)
                            .help("Jump to line \(line)")
                        } else {
                            FlagLine(flag: flag, lineLabel: nil)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private struct SinceReviewRow: View {
        let info: SinceReview

        private var when: String {
            Calendar.current.isDateInToday(info.reviewedAt)
                ? Format.time.string(from: info.reviewedAt)
                : Format.dateTime.string(from: info.reviewedAt)
        }

        var body: some View {
            // Drop words before truncating, so the time survives a narrow pane. Narrower than the
            // shortest words beside the picker, the picker takes a row of its own: a row wider
            // than the column would widen the window instead.
            ViewThatFits(in: .horizontal) {
                line(Text("Changed since your review at \(when)"), withPicker: true)
                line(Text("Changed since your \(when) review"), withPicker: true)
                line(Text("Changed since review"), withPicker: true)
                VStack(alignment: .leading, spacing: 4) {
                    line(ViewThatFits(in: .horizontal) {
                        Text("Changed since your review at \(when)")
                        Text("Changed since your \(when) review")
                        Text("Changed since review")
                    }, withPicker: false)
                    picker
                }
            }
            .font(.caption)
            .padding(.top, 1)
        }

        private func line(_ title: some View, withPicker: Bool) -> some View {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Color.accentColor)
                title
                    .lineLimit(1)
                    .help("You marked this file reviewed at \(when); it has changed since")
                if let shown = info.shown {
                    DeltaText(additions: shown.additions, deletions: shown.deletions)
                        .fixedSize()
                }
                if let reason = info.unavailableReason {
                    Text(reason)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if withPicker {
                    picker
                }
            }
        }

        @ViewBuilder
        private var picker: some View {
            if let selection = info.showingSinceReview {
                Picker("Diff to show", selection: selection) {
                    Text("Since Review").tag(true)
                    Text("Full Diff").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Since Review shows only what changed after you marked the file reviewed")
            }
        }
    }

    private struct Tag: View {
        let text: String
        init(_ text: String) { self.text = text }
        var body: some View {
            Text(text)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
    }

    private struct FlagLine: View {
        let flag: AttentionFlag
        let lineLabel: String?
        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: flag.rule.systemImage)
                    .foregroundStyle(flag.severity.color)
                    .frame(width: 14)
                Text(flag.message)
                if let lineLabel {
                    Text(lineLabel)
                        .foregroundStyle(Color.accentColor)
                        .underline()
                }
            }
            .font(.caption)
            .contentShape(Rectangle())
        }
    }
}

struct DiffContentView: View {
    let diff: FileDiff
    let decorations: DiffDecorations
    let wrap: Bool
    let sideBySide: Bool
    let fontSize: Double
    @Binding var showAll: Bool
    @Binding var targetLineID: Int?
    /// The most severe flag on each line of the new file, so those lines stand out.
    var flags: [Int: AttentionFlag] = [:]
    /// The branch checked out, to name a conflict's current side ("HEAD (main)").
    var currentBranch: String? = nil
    /// The file's notes, where notes apply.
    var notes: DiffNotes? = nil
    /// Where the note being written goes, kept by the diff's owner so its header can start one too.
    var draft: Binding<NoteDraft?> = .constant(nil)
    /// Its words. Only the composer reads them as it draws; this view reads them only to save.
    var draftText = NoteDraftText()
    /// Asks to throw a hunk away; nil where hunks can't be discarded.
    var discard: ((DiffHunk) -> Void)? = nil

    private static let initialLimit = 2500
    /// Where the notes above the diff are, to scroll a new whole-file note into view.
    private static let notesAboveID = "notes-above"
    /// Narrower than this, two columns are too cramped to read; show one instead.
    private static let minimumSplitWidth: CGFloat = 560
    /// The change overview beside the diff, for diffs longer than a screen or so.
    private static let overviewWidth: CGFloat = 12
    private static let overviewMinimumRows = 50

    /// What part of the diff is on screen, for the overview's box. Kept out of this view's
    /// state so that scrolling redraws only the box, not the diff.
    @State private var viewport = DiffViewport()

    private struct Visible {
        var hunks: [DiffHunk]
        var truncated: Bool
        var lineCount: Int
    }

    private var visible: Visible {
        guard !showAll, diff.lineCount > Self.initialLimit else {
            return Visible(hunks: diff.hunks, truncated: false, lineCount: diff.lineCount)
        }
        var budget = Self.initialLimit
        var result: [DiffHunk] = []
        for hunk in diff.hunks {
            if budget <= 0 { break }
            if hunk.lines.count <= budget {
                result.append(hunk)
                budget -= hunk.lines.count
            } else {
                var partial = hunk
                partial.lines = Array(hunk.lines.prefix(budget))
                result.append(partial)
                budget = 0
            }
        }
        return Visible(hunks: result, truncated: true, lineCount: Self.initialLimit)
    }

    private var numberWidth: CGFloat {
        let maxNumber = diff.hunks.last.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) } ?? 999
        let digits = max(3, String(maxNumber).count)
        return CGFloat(digits) * fontSize * 0.62 + 10
    }

    /// Width of the unwrapped layout, worked out from the widest line instead of by
    /// measuring every row, so even long diffs build only the rows on screen.
    private var unwrappedWidth: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let column = ("M" as NSString).size(withAttributes: [.font: font]).width
        return numberWidth * 2 + 8 + 12 + CGFloat(decorations.widestLineColumns) * column + 12 + 24
    }

    var body: some View {
        let visible = visible
        GeometryReader { geometry in
            let showsOverview = visible.lineCount + visible.hunks.count >= Self.overviewMinimumRows
            let width = geometry.size.width - (showsOverview ? Self.overviewWidth : 0)
            let split = sideBySide && width >= Self.minimumSplitWidth
            let horizontal = !split && !wrap
            ScrollViewReader { proxy in
                HStack(spacing: 0) {
                    ScrollView(horizontal ? [.vertical, .horizontal] : .vertical) {
                        Group {
                            // Each hunk's header stays at the top while its lines scroll under it.
                            if horizontal {
                                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                                    rows(visible: visible, wrap: false)
                                }
                                .frame(width: max(unwrappedWidth, width), alignment: .leading)
                            } else if split {
                                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                                    splitRows(visible: visible)
                                }
                            } else {
                                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                                    rows(visible: visible, wrap: true)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        // A two-axis scroll view centers content smaller than itself; fill the
                        // viewport so short diffs stay pinned to the top-leading corner.
                        .frame(minWidth: horizontal ? width : nil,
                               maxWidth: .infinity,
                               minHeight: horizontal ? geometry.size.height : nil,
                               alignment: .topLeading)
                    }
                    .onScrollGeometryChange(for: ClosedRange<Double>.self) { scroll in
                        let height = max(scroll.contentSize.height, 1)
                        let top = min(1, max(0, scroll.visibleRect.minY / height))
                        return top...max(top, min(1, scroll.visibleRect.maxY / height))
                    } action: { _, shown in
                        viewport.shown = shown
                    }
                    .onChange(of: targetLineID) { _, id in
                        guard let id, let key = key(forLine: id, in: visible.hunks, split: split) else { return }
                        withAnimation { proxy.scrollTo(key, anchor: .center) }
                    }
                    .onAppear {
                        if let id = targetLineID, let key = key(forLine: id, in: visible.hunks, split: split) {
                            proxy.scrollTo(key, anchor: .center)
                        }
                    }
                    .onChange(of: draft.wrappedValue) { old, new in
                        // A new note on the whole file opens above the diff, which may be out of view.
                        guard let new, new.lines == nil, new.editing == nil, old == nil || old?.lines != nil else { return }
                        withAnimation { proxy.scrollTo(Self.notesAboveID, anchor: .top) }
                    }
                    if showsOverview {
                        DiffOverviewStrip(overview: DiffOverview(hunks: visible.hunks, sideBySide: split,
                                                                 flaggedLines: overviewMarks),
                                          viewport: viewport) { row in
                            if let id = row.id { proxy.scrollTo(DiffRowKey(hunk: row.hunk, row: id), anchor: .center) }
                        }
                        .frame(width: Self.overviewWidth)
                    }
                }
            }
        }
    }

    /// The flag on a line of the new file; removed lines have none, since flags point at new lines.
    /// A line in a merge conflict is drawn as part of it instead.
    private func flag(for line: DiffLine?) -> AttentionFlag? {
        guard let line, line.kind != .deletion, let number = line.newNumber, placement(for: line) == nil else { return nil }
        return flags[number]
    }

    /// Where a line of the new file falls in a merge conflict, if it does.
    private func placement(for line: DiffLine?) -> MergeConflicts.Placement? {
        guard !decorations.conflicts.isEmpty, let line, line.kind != .deletion, let number = line.newNumber else { return nil }
        return decorations.conflicts.placement(ofLine: number)
    }

    /// Flagged lines, and where each conflict starts, for the strip beside a long diff.
    private var overviewMarks: [Int: Severity] {
        var marks = flags.mapValues(\.severity)
        for conflict in decorations.conflicts.conflicts { marks[conflict.opening] = .critical }
        return marks
    }

    /// The row showing a line: its own, or in two columns the pair it is in.
    private func key(forLine id: Int, in hunks: [DiffHunk], split: Bool) -> DiffRowKey? {
        guard let hunk = hunks.first(where: { $0.lines.contains { $0.id == id } }) else { return nil }
        guard split else { return DiffRowKey(hunk: hunk.id, row: id) }
        let row = SideBySide.rows(for: hunk).first { $0.left?.id == id || $0.right?.id == id }
        return row.map { DiffRowKey(hunk: hunk.id, row: $0.id) }
    }

    // Rows are keyed by their hunk as well as their line: line ids count up through the file,
    // so after the diff reloads a line id can belong to another hunk, and a lazy stack kept
    // drawing a row's old content when its id moved to another section.
    @ViewBuilder
    private func rows(visible: Visible, wrap: Bool) -> some View {
        notesAboveDiff
        let index = noteIndex(visible.hunks)
        ForEach(visible.hunks) { hunk in
            let onDiscard = discardAction(for: hunk)
            Section {
                ForEach(hunk.lines) { line in
                    DiffLineRow(line: line, wrap: wrap, fontSize: fontSize, numberWidth: numberWidth,
                                syntax: decorations.syntax[line.id], emphasis: decorations.emphasis[line.id],
                                isTarget: line.id == targetLineID, flag: flag(for: line),
                                conflict: placement(for: line), currentBranch: currentBranch,
                                note: index.mark(for: line), onNote: noteAction(for: line, in: hunk),
                                onDiscardHunk: onDiscard)
                        .id(DiffRowKey(hunk: hunk.id, row: line.id))
                    noteRows(after: [line.id], index: index, inset: numberWidth * 2 + 20)
                }
            } header: {
                HunkHeaderRow(hunk: hunk, fontSize: fontSize, onDiscard: onDiscard)
            }
        }
        truncationFooter(visible)
    }

    @ViewBuilder
    private func splitRows(visible: Visible) -> some View {
        notesAboveDiff
        let index = noteIndex(visible.hunks)
        ForEach(visible.hunks) { hunk in
            let onDiscard = discardAction(for: hunk)
            Section {
                ForEach(SideBySide.rows(for: hunk)) { row in
                    // Removed lines take notes on the left, the rest on the right.
                    let left = row.left?.kind == .deletion ? row.left : nil
                    let right = row.right?.kind == .deletion ? nil : row.right
                    SplitLineRow(row: row, decorations: decorations, fontSize: fontSize, numberWidth: numberWidth,
                                 isTarget: targetLineID != nil && (row.left?.id == targetLineID || row.right?.id == targetLineID),
                                 flag: flag(for: row.right), conflict: placement(for: row.right), currentBranch: currentBranch,
                                 leftNote: left.map(index.mark) ?? .none, rightNote: right.map(index.mark) ?? .none,
                                 onNoteLeft: left.flatMap { noteAction(for: $0, in: hunk) },
                                 onNoteRight: right.flatMap { noteAction(for: $0, in: hunk) },
                                 onDiscardHunk: onDiscard)
                        .id(DiffRowKey(hunk: hunk.id, row: row.id))
                    noteRows(after: [left?.id, right?.id].compactMap { $0 }, index: index, inset: numberWidth + 8)
                }
            } header: {
                HunkHeaderRow(hunk: hunk, fontSize: fontSize, onDiscard: onDiscard)
            }
        }
        truncationFooter(visible)
    }

    /// Asks to discard `hunk` whole: one cut short for display is still discarded as the
    /// confirmation shows it, all of it.
    private func discardAction(for hunk: DiffHunk) -> (() -> Void)? {
        guard let discard else { return nil }
        let whole = diff.hunks.first { $0.id == hunk.id } ?? hunk
        return { discard(whole) }
    }

    // MARK: Notes

    /// Which notes and gutter marks go with which lines, worked out once per drawing.
    private struct NoteIndex {
        /// Notes after a line, by its id: the line each one's range ends on.
        var after: [Int: [ReviewNote]] = [:]
        /// The line the new note being written follows.
        var draftAfter: Int?
        var noted: [ReviewNote.Side: Set<Int>] = [:]
        var draftSide: ReviewNote.Side?
        var draftLines: ClosedRange<Int>?

        func mark(for line: DiffLine) -> NoteMark {
            for side in [ReviewNote.Side.new, .old] {
                guard let number = ReviewNotes.number(of: line, on: side) else { continue }
                if draftSide == side, draftLines?.contains(number) == true { return .drafting }
                if noted[side]?.contains(number) == true { return .noted }
            }
            return .none
        }
    }

    private func noteIndex(_ hunks: [DiffHunk]) -> NoteIndex {
        guard let notes else { return NoteIndex() }
        let draft = draft.wrappedValue.flatMap { $0.editing == nil ? $0 : nil }
        var index = NoteIndex(noted: [.new: notes.notedLines(side: .new),
                                      .old: notes.showsOldSide ? notes.notedLines(side: .old) : []],
                              draftSide: draft?.side, draftLines: draft?.lines)
        guard !notes.notes.isEmpty || draft?.lines != nil else { return index }
        for hunk in hunks {
            for line in hunk.lines {
                for side in [ReviewNote.Side.new, .old] {
                    guard let number = ReviewNotes.number(of: line, on: side) else { continue }
                    let attached = notes.onLines(side: side, endingAt: number)
                    if !attached.isEmpty { index.after[line.id, default: []] += attached }
                    if let draft, draft.side == side, draft.hunk == hunk.id, draft.lines?.upperBound == number {
                        index.draftAfter = line.id
                    }
                }
            }
        }
        return index
    }

    /// Starts a note on `line`, or with Shift held stretches the one being written to it.
    private func noteAction(for line: DiffLine, in hunk: DiffHunk) -> (() -> Void)? {
        guard let notes else { return nil }
        let side: ReviewNote.Side = line.kind == .deletion ? .old : .new
        guard let number = ReviewNotes.number(of: line, on: side), side == .new || notes.showsOldSide else { return nil }
        return { [draft, draftText] in
            let current = draft.wrappedValue
            if NSEvent.modifierFlags.contains(.shift), var current, current.editing == nil, current.side == side,
               current.hunk == hunk.id, let lines = current.lines {
                current.lines = min(lines.lowerBound, number)...max(lines.upperBound, number)
                draft.wrappedValue = current
            } else {
                // A note you started keeps its words when you pick another line for it.
                let writingNew = current != nil && current?.editing == nil
                if !writingNew { draftText.text = "" }
                draft.wrappedValue = NoteDraft(side: side, lines: number...number, hunk: hunk.id)
            }
        }
    }

    /// Notes on the whole file, and notes whose lines are no longer in the diff.
    @ViewBuilder
    private var notesAboveDiff: some View {
        if let notes {
            let above = notes.aboveDiff
            let fileDraft = draft.wrappedValue.map { $0.lines == nil && $0.editing == nil } ?? false
            if !above.isEmpty || fileDraft {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(above) { noteView($0, notes: notes) }
                    if fileDraft { composer(notes) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .id(Self.notesAboveID)
            }
        }
    }

    @ViewBuilder
    private func noteRows(after lineIDs: [Int], index: NoteIndex, inset: CGFloat) -> some View {
        if let notes {
            let ids = lineIDs.count == 2 && lineIDs[0] == lineIDs[1] ? [lineIDs[0]] : lineIDs
            let attached = ids.flatMap { index.after[$0] ?? [] }
            let drafting = index.draftAfter.map(ids.contains) ?? false
            if !attached.isEmpty || drafting {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(attached) { noteView($0, notes: notes) }
                    if drafting { composer(notes) }
                }
                .padding(.leading, inset)
                .padding(.trailing, 12)
                .padding(.vertical, 5)
            }
        }
    }

    @ViewBuilder
    private func noteView(_ note: ReviewNote, notes: DiffNotes) -> some View {
        if draft.wrappedValue?.editing == note.id {
            composer(notes)
        } else {
            ReviewNoteCard(note: note, currentBlob: notes.currentBlob,
                           onEdit: {
                               draftText.text = note.text
                               draft.wrappedValue = NoteDraft(side: note.side, lines: note.lines, editing: note.id)
                           },
                           onDelete: { notes.delete(note.id) },
                           onResolve: { notes.setResolved(note.id, $0) })
        }
    }

    private func composer(_ notes: DiffNotes) -> some View {
        ReviewNoteComposer(
            draft: draft.wrappedValue ?? NoteDraft(),
            words: draftText,
            onSave: {
                guard let current = draft.wrappedValue else { return }
                let text = draftText.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = current.editing {
                    notes.edit(id, text)
                } else {
                    notes.add(current.side, current.lines, quote(for: current), text)
                }
                draft.wrappedValue = nil
                draftText.text = ""
            },
            onCancel: {
                draft.wrappedValue = nil
                draftText.text = ""
            })
    }

    /// The lines a new note covers, as they read now.
    private func quote(for draft: NoteDraft) -> [String] {
        guard let lines = draft.lines, let hunk = diff.hunks.first(where: { $0.id == draft.hunk }) else { return [] }
        return hunk.lines.filter { ReviewNotes.number(of: $0, on: draft.side).map(lines.contains) ?? false }.map(\.text)
    }

    @ViewBuilder
    private func truncationFooter(_ visible: Visible) -> some View {
        if visible.truncated {
            HStack {
                Spacer()
                Button("Show all \(diff.lineCount) lines") { showAll = true }
                    .help("This diff is long, so only its start is shown. Show the rest.")
                Spacer()
            }
            .padding()
        }
    }
}

/// A diff row's identity: its hunk and its line (or, in two columns, its pair).
struct DiffRowKey: Hashable {
    let hunk: Int
    let row: Int
}

/// What part of the diff is on screen, as fractions of its height.
@MainActor @Observable
final class DiffViewport {
    var shown: ClosedRange<Double>?
}

struct HunkHeaderRow: View {
    let hunk: DiffHunk
    let fontSize: Double
    /// Asks to throw the hunk away; nil where hunks can't be discarded.
    var onDiscard: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(hunk.header)
                .font(.system(size: max(9, fontSize - 1), design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDiscard {
                Button(action: onDiscard) {
                    Label("Discard…", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .font(.system(size: max(9, fontSize - 1)))
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("Throw this hunk away: its lines go back to how they are in the last commit, after a snapshot")
                .accessibilityLabel("Discard hunk")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.09))
        // Pinned at the top, it covers the lines scrolling under it.
        .background(.bar)
    }
}

/// The whole diff at a glance, beside it: a mark for each run of added (green) or removed (red)
/// lines, half and half for a pair side by side, a tick where each hunk starts, and a box around
/// what is on screen. Click or drag to go there.
struct DiffOverviewStrip: View {
    let overview: DiffOverview
    let viewport: DiffViewport
    let onJump: (DiffOverview.Row) -> Void

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let inset: CGFloat = 3
                let width = size.width - inset * 2
                for start in overview.hunkStarts {
                    context.fill(Path(CGRect(x: inset, y: start * size.height, width: width, height: 1)), with: .style(.tertiary))
                }
                for mark in overview.marks {
                    let rect = CGRect(x: inset, y: mark.start * size.height, width: width, height: max(2, mark.length * size.height))
                    switch mark.kind {
                    case .addition:
                        context.fill(Path(rect), with: .color(.green.opacity(0.85)))
                    case .deletion:
                        context.fill(Path(rect), with: .color(.red.opacity(0.85)))
                    case .change:
                        let halves = rect.divided(atDistance: width / 2, from: .minXEdge)
                        context.fill(Path(halves.slice), with: .color(.red.opacity(0.85)))
                        context.fill(Path(halves.remainder), with: .color(.green.opacity(0.85)))
                    }
                }
                // Flagged lines over the runs, full width and at least 3 pt, so a lone one shows.
                for flag in overview.flags {
                    let height = max(3, flag.length * size.height)
                    let rect = CGRect(x: 0, y: flag.start * size.height - (height - flag.length * size.height) / 2,
                                      width: size.width, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(flag.severity.color))
                }
            }
            .overlay(alignment: .topLeading) {
                ViewportBox(viewport: viewport, height: geometry.size.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                if let row = overview.row(at: drag.location.y / max(geometry.size.height, 1)) { onJump(row) }
            })
        }
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.25))
        .overlay(alignment: .leading) { Divider() }
        .help(overview.flags.isEmpty ? "Where this diff's changes are. Click or drag to go there."
              : "Where this diff's changes are, and in orange or red the lines that need a look. Click or drag to go there.")
        .accessibilityElement()
        .accessibilityLabel("Change overview")
        .accessibilityValue("\(overview.marks.count) runs of changed lines in \(overview.hunkStarts.count) hunks"
                            + (overview.flags.isEmpty ? "" : ", \(overview.flags.count) flagged"))
    }
}

/// The overview's box around what is on screen; its own view, so scrolling redraws only it.
private struct ViewportBox: View {
    let viewport: DiffViewport
    let height: CGFloat

    var body: some View {
        if let shown = viewport.shown, shown.upperBound - shown.lowerBound < 0.999 {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(.secondary, lineWidth: 1)
                .background(RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.06)))
                .frame(height: max(6, (shown.upperBound - shown.lowerBound) * height))
                .offset(y: shown.lowerBound * height)
                .padding(.horizontal, 1)
                .allowsHitTesting(false)
        }
    }
}

struct DiffLineRow: View {
    let line: DiffLine
    let wrap: Bool
    let fontSize: Double
    let numberWidth: CGFloat
    let syntax: [SyntaxSpan]?
    let emphasis: [Range<Int>]?
    let isTarget: Bool
    /// An attention flag on this line: it takes the flag's colour, with a stripe at its edge.
    var flag: AttentionFlag? = nil
    /// Where the line falls in a merge conflict: a side takes the side's colour, a marker
    /// becomes a labelled divider.
    var conflict: MergeConflicts.Placement? = nil
    var currentBranch: String? = nil
    /// Whether the line has a note, or is in one being written.
    var note: NoteMark = .none
    /// Starts a note on this line; nil where notes can't go.
    var onNote: (() -> Void)? = nil
    /// Asks to discard the line's hunk, from the gutter's context menu.
    var onDiscardHunk: (() -> Void)? = nil
    @State private var hovering = false

    private var place: String {
        line.kind == .deletion ? "removed line \(line.oldNumber ?? 0)" : "line \(line.newNumber ?? 0)"
    }

    private var marker: String {
        // Inside a conflict, + and − say nothing about who wrote a line.
        if conflict != nil { return " " }
        return switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        case .context: " "
        case .noNewline: "\\"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // The gutter's menu leaves the text's own, for copying a selection, alone.
            HStack(alignment: .top, spacing: 0) {
                Text(line.oldNumber.map(String.init) ?? "")
                    .frame(width: numberWidth, alignment: .trailing)
                    .foregroundStyle(.tertiary)
                    .overlay(alignment: .leading) {
                        if let onNote {
                            NoteGutterButton(mark: note, visible: hovering, place: place, action: onNote)
                        }
                    }
                Text(line.newNumber.map(String.init) ?? "")
                    .frame(width: numberWidth, alignment: .trailing)
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 8)
                Text(marker)
                    .frame(width: 12, alignment: .center)
                    .foregroundStyle(line.kind == .addition ? .green : line.kind == .deletion ? .red : .secondary)
            }
            .discardHunkMenu(onDiscardHunk)
            if let conflict, conflict.part.isMarker {
                ConflictStyle.label(conflict, currentBranch: currentBranch, fontSize: fontSize)
                    .padding(.trailing, 12)
                    .help(line.text)
            } else {
                Text(DiffLineStyle.text(line, syntax: syntax, emphasis: emphasis))
                    .lineLimit(wrap ? nil : 1)
                    .fixedSize(horizontal: !wrap, vertical: false)
                    .foregroundStyle(line.kind == .noNewline ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
                    .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                    .padding(.trailing, 12)
            }
        }
        .font(.system(size: fontSize, design: .monospaced))
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(conflict.map { ConflictStyle.background($0.part) } ?? DiffLineStyle.background(line.kind, flag: flag))
        .overlay(alignment: .leading) {
            if let conflict { ConflictStyle.stripe(conflict.part) } else { DiffLineStyle.flagStripe(flag) }
        }
        .overlay {
            if note == .drafting {
                Color.accentColor.opacity(0.14)
                    .allowsHitTesting(false)
            }
            if isTarget {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .onHover { inside in if onNote != nil { hovering = inside } }
        .flagHelp(flag)
    }
}

/// Colors shared by the single-column and side-by-side rows.
enum DiffLineStyle {
    static func background(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .addition: Color.green.opacity(0.13)
        case .deletion: Color.red.opacity(0.13)
        case .context, .noNewline: .clear
        }
    }

    /// A flagged line takes its flag's colour in place of the green, so it stands out in a run of
    /// added lines.
    static func background(_ kind: DiffLineKind, flag: AttentionFlag?) -> Color {
        flag.map { $0.severity.color.opacity(0.22) } ?? background(kind)
    }

    /// The flag's colour down a flagged line's leading edge.
    @ViewBuilder
    static func flagStripe(_ flag: AttentionFlag?) -> some View {
        if let flag {
            Rectangle()
                .fill(flag.severity.color)
                .frame(width: 3)
                .accessibilityLabel(flag.message)
        }
    }

    static func emphasis(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .addition: Color.green.opacity(0.32)
        case .deletion: Color.red.opacity(0.32)
        case .context, .noNewline: .clear
        }
    }

    static func text(_ line: DiffLine, syntax: [SyntaxSpan]?, emphasis: [Range<Int>]?) -> AttributedString {
        DiffText.attributed(DiffText.display(line.text), syntax: syntax, emphasis: emphasis,
                            emphasisColor: Self.emphasis(line.kind))
    }
}

/// One row of the side-by-side layout: old on the left, new on the right.
struct SplitLineRow: View {
    let row: SplitRow
    let decorations: DiffDecorations
    let fontSize: Double
    let numberWidth: CGFloat
    let isTarget: Bool
    /// An attention flag on the new side's line.
    var flag: AttentionFlag? = nil
    /// Where the new side's line falls in a merge conflict.
    var conflict: MergeConflicts.Placement? = nil
    var currentBranch: String? = nil
    var leftNote: NoteMark = .none
    var rightNote: NoteMark = .none
    /// Start a note on the removed line on the left, or the line on the right.
    var onNoteLeft: (() -> Void)? = nil
    var onNoteRight: (() -> Void)? = nil
    /// Asks to discard the row's hunk, from either gutter's context menu.
    var onDiscardHunk: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            SplitCell(line: row.left, number: row.left?.oldNumber,
                      syntax: row.left.flatMap { decorations.syntax[$0.id] },
                      emphasis: row.left.flatMap { decorations.emphasis[$0.id] },
                      numberWidth: numberWidth, note: leftNote, onNote: onNoteLeft, onDiscardHunk: onDiscardHunk)
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 1)
            SplitCell(line: row.right, number: row.right?.newNumber,
                      syntax: row.right.flatMap { decorations.syntax[$0.id] },
                      emphasis: row.right.flatMap { decorations.emphasis[$0.id] },
                      numberWidth: numberWidth, flag: flag, conflict: conflict, currentBranch: currentBranch,
                      note: rightNote, onNote: onNoteRight, onDiscardHunk: onDiscardHunk)
        }
        // Both cells take the taller one's height, so their backgrounds line up.
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: fontSize, design: .monospaced))
        .overlay {
            if isTarget {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
    }
}

private struct SplitCell: View {
    let line: DiffLine?
    let number: Int?
    let syntax: [SyntaxSpan]?
    let emphasis: [Range<Int>]?
    let numberWidth: CGFloat
    var flag: AttentionFlag? = nil
    var conflict: MergeConflicts.Placement? = nil
    var currentBranch: String? = nil
    var note: NoteMark = .none
    var onNote: (() -> Void)? = nil
    var onDiscardHunk: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .frame(width: numberWidth, alignment: .trailing)
                .foregroundStyle(.tertiary)
                .overlay(alignment: .leading) {
                    if let onNote, let line {
                        NoteGutterButton(mark: note, visible: hovering,
                                         place: line.kind == .deletion ? "removed line \(number ?? 0)" : "line \(number ?? 0)",
                                         action: onNote)
                    }
                }
                .padding(.trailing, 8)
                .discardHunkMenu(onDiscardHunk)
            if let conflict, conflict.part.isMarker, let line {
                ConflictStyle.label(conflict, currentBranch: currentBranch, fontSize: nil)
                    .padding(.trailing, 8)
                    .help(line.text)
            } else if let line {
                Text(DiffLineStyle.text(line, syntax: syntax, emphasis: emphasis))
                    .foregroundStyle(line.kind == .noNewline ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A missing side reads as a gap, not as unchanged text.
        .background(conflict.map { ConflictStyle.background($0.part) }
                     ?? line.map { DiffLineStyle.background($0.kind, flag: flag) } ?? Color.secondary.opacity(0.06))
        .overlay(alignment: .leading) {
            if let conflict { ConflictStyle.stripe(conflict.part) } else { DiffLineStyle.flagStripe(flag) }
        }
        .overlay {
            if note == .drafting {
                Color.accentColor.opacity(0.14)
                    .allowsHitTesting(false)
            }
        }
        .onHover { inside in if onNote != nil { hovering = inside } }
        .flagHelp(flag)
    }
}

/// How a merge conflict is drawn: the current side (what the branch had) in blue, the incoming
/// side in purple, the common ancestor in gray, and each marker as a labelled divider.
enum ConflictStyle {
    static func color(_ part: MergeConflicts.Part) -> Color {
        switch part {
        case .opening, .current: .blue
        case .baseMarker, .base: .gray
        case .divider, .incoming, .closing: .purple
        }
    }

    static func background(_ part: MergeConflicts.Part) -> Color {
        color(part).opacity(part.isMarker ? 0.26 : 0.12)
    }

    static func stripe(_ part: MergeConflicts.Part) -> some View {
        Rectangle()
            .fill(color(part))
            .frame(width: 3)
    }

    /// "Conflict 1 of 2 · Current: HEAD (main)", "Incoming: feature/euros". `fontSize` nil keeps
    /// the row's own.
    static func label(_ placement: MergeConflicts.Placement, currentBranch: String?, fontSize: Double?) -> some View {
        let conflict = placement.conflict
        let text: String = switch placement.part {
        case .opening: "Conflict \(conflict.number) of \(placement.total) · Current: \(name(conflict.current, currentBranch: currentBranch))"
        case .baseMarker: "Common ancestor" + (conflict.base.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? "")
        case .divider: "Incoming: " + (conflict.incoming.isEmpty ? "the other side" : conflict.incoming)
        case .closing: "End of conflict \(conflict.number)"
        case .current, .base, .incoming: ""
        }
        return Text(text)
            .font(fontSize.map { .system(size: $0, weight: .semibold) } ?? .body.weight(.semibold))
            .foregroundStyle(color(placement.part))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The current side's label, with the branch when it is "HEAD".
    private static func name(_ label: String, currentBranch: String?) -> String {
        guard label == "HEAD", let currentBranch else { return label.isEmpty ? "this branch" : label }
        return "HEAD (\(currentBranch))"
    }
}

extension View {
    /// A flagged line's tooltip is its flag's message; other lines have none, so a long diff does
    /// not carry a tooltip per row.
    @ViewBuilder
    func flagHelp(_ flag: AttentionFlag?) -> some View {
        if let flag { help(flag.message) } else { self }
    }
}
