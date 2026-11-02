import SwiftUI
import MimamoriCore

struct DiffView: View {
    @Environment(AppModel.self) private var model
    let session: WorktreeSession
    let change: FileChange
    /// Shows the change as one commit made it, against its parent, rather than in the working tree.
    var commit: CommitRecord? = nil

    @State private var diff: FileDiff?
    @State private var errorText: String?
    @State private var showAll = false
    @State private var targetLineID: Int?
    /// The file and reviewed version for which you chose the full diff over the since-review one.
    @State private var fullDiffKey: String?
    /// A reviewed blob found missing from the object store.
    @State private var missingReviewBlob: String?
    /// Whether `diff` holds the since-review diff.
    @State private var loadedSinceReview = false
    /// A line to jump to once the full diff has loaded.
    @State private var pendingJump: Int?
    /// Syntax colors and word emphasis for `diff`, worked out off the main thread.
    @State private var decorations = DiffDecorations.empty

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
                                   onToggleReviewed: commit == nil ? { model.toggleReviewForSelection() } : nil) { lineNumber in
                        jump(toNewLine: lineNumber)
                    }
                    Divider()
                }
                .background(.bar)
            }
            .task(id: "\(commit?.oid ?? "")|\(change.contentKey)|\(reviewedBlob ?? "")|\(wantsSinceReview)|\(model.settings.syntaxHighlighting)") {
                showAll = false
                targetLineID = nil
                await load()
                // MIMAMORI_DEBUG_FLAGS=diff-line:<n>: jump to new-file line n, as a flag's link does.
                if let flag = model.debugFlags.first(where: { $0.hasPrefix("diff-line:") }),
                   let number = Int(flag.dropFirst("diff-line:".count)) {
                    jump(toNewLine: number)
                }
            }
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
        } else if let diff {
            if diff.hunks.isEmpty {
                ContentUnavailableView("No Text Changes", systemImage: "doc", description: Text(emptyDiffDescription(diff)))
            } else {
                DiffContentView(diff: diff, decorations: decorations, wrap: model.settings.wrapDiffLines,
                                sideBySide: model.settings.diffLayout == .sideBySide,
                                fontSize: model.settings.diffFontSize, showAll: $showAll, targetLineID: $targetLineID,
                                flags: AttentionFlag.byLine(change.flags))
            }
        } else if let errorText {
            ContentUnavailableView("Could Not Load Diff", systemImage: "exclamationmark.triangle",
                                   description: Text(errorText))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
        if diff?.path != change.path { diff = nil }
        do {
            if wantsSinceReview, let blob = reviewedBlob {
                if let since = try await session.diffSinceReview(for: change, reviewedBlob: blob) {
                    loadedSinceReview = true
                    await show(since)
                    return
                }
                missingReviewBlob = blob
            }
            let full = if let commit {
                try await session.diff(for: change, in: commit)
            } else {
                try await session.diff(for: change)
            }
            loadedSinceReview = false
            await show(full)
            if full == nil { errorText = "git produced no diff for this file." }
            if let line = pendingJump {
                pendingJump = nil
                jump(toNewLine: line)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Shows a loaded diff together with its colors, so it never flashes plain first.
    private func show(_ loaded: FileDiff?) async {
        guard let loaded else {
            diff = nil
            decorations = .empty
            return
        }
        let path = change.path
        let highlight = model.settings.syntaxHighlighting
        let computed = await Task.detached(priority: .userInitiated) {
            DiffDecorations.compute(for: loaded, path: path, highlightSyntax: highlight)
        }.value
        guard !Task.isCancelled else { return }
        decorations = computed
        diff = loaded
    }
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
    let onJump: (Int) -> Void

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
                    Button {
                        if let diff { Workspace.copy(diff.unifiedText) }
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy the diff as a patch")
                    .accessibilityLabel("Copy the diff")
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

    private static let initialLimit = 2500
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
                    if showsOverview {
                        DiffOverviewStrip(overview: DiffOverview(hunks: visible.hunks, sideBySide: split,
                                                                 flaggedLines: flags.mapValues(\.severity)),
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
    private func flag(for line: DiffLine?) -> AttentionFlag? {
        guard let line, line.kind != .deletion, let number = line.newNumber else { return nil }
        return flags[number]
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
        ForEach(visible.hunks) { hunk in
            Section {
                ForEach(hunk.lines) { line in
                    DiffLineRow(line: line, wrap: wrap, fontSize: fontSize, numberWidth: numberWidth,
                                syntax: decorations.syntax[line.id], emphasis: decorations.emphasis[line.id],
                                isTarget: line.id == targetLineID, flag: flag(for: line))
                        .id(DiffRowKey(hunk: hunk.id, row: line.id))
                }
            } header: {
                HunkHeaderRow(hunk: hunk, fontSize: fontSize)
            }
        }
        truncationFooter(visible)
    }

    @ViewBuilder
    private func splitRows(visible: Visible) -> some View {
        ForEach(visible.hunks) { hunk in
            Section {
                ForEach(SideBySide.rows(for: hunk)) { row in
                    SplitLineRow(row: row, decorations: decorations, fontSize: fontSize, numberWidth: numberWidth,
                                 isTarget: targetLineID != nil && (row.left?.id == targetLineID || row.right?.id == targetLineID),
                                 flag: flag(for: row.right))
                        .id(DiffRowKey(hunk: hunk.id, row: row.id))
                }
            } header: {
                HunkHeaderRow(hunk: hunk, fontSize: fontSize)
            }
        }
        truncationFooter(visible)
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

    var body: some View {
        Text(hunk.header)
            .font(.system(size: max(9, fontSize - 1), design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        case .context: " "
        case .noNewline: "\\"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: numberWidth, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: numberWidth, alignment: .trailing)
                .foregroundStyle(.tertiary)
                .padding(.trailing, 8)
            Text(marker)
                .frame(width: 12, alignment: .center)
                .foregroundStyle(line.kind == .addition ? .green : line.kind == .deletion ? .red : .secondary)
            Text(DiffLineStyle.text(line, syntax: syntax, emphasis: emphasis))
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap, vertical: false)
                .foregroundStyle(line.kind == .noNewline ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                .padding(.trailing, 12)
        }
        .font(.system(size: fontSize, design: .monospaced))
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiffLineStyle.background(line.kind, flag: flag))
        .overlay(alignment: .leading) { DiffLineStyle.flagStripe(flag) }
        .overlay {
            if isTarget {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
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

    var body: some View {
        HStack(spacing: 0) {
            SplitCell(line: row.left, number: row.left?.oldNumber,
                      syntax: row.left.flatMap { decorations.syntax[$0.id] },
                      emphasis: row.left.flatMap { decorations.emphasis[$0.id] },
                      numberWidth: numberWidth)
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 1)
            SplitCell(line: row.right, number: row.right?.newNumber,
                      syntax: row.right.flatMap { decorations.syntax[$0.id] },
                      emphasis: row.right.flatMap { decorations.emphasis[$0.id] },
                      numberWidth: numberWidth, flag: flag)
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

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .frame(width: numberWidth, alignment: .trailing)
                .foregroundStyle(.tertiary)
                .padding(.trailing, 8)
            if let line {
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
        .background(line.map { DiffLineStyle.background($0.kind, flag: flag) } ?? Color.secondary.opacity(0.06))
        .overlay(alignment: .leading) { DiffLineStyle.flagStripe(flag) }
        .flagHelp(flag)
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
