import SwiftUI
import VigilCore

struct DiffView: View {
    @Environment(AppModel.self) private var model
    let session: WorktreeSession
    let change: FileChange

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

    private var review: ReviewStatus { session.reviewStatus(of: change) }

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
                                   attribution: session.attributions[change.path],
                                   review: review, sinceReview: sinceReviewInfo,
                                   onToggleReviewed: { model.toggleReviewForSelection() }) { lineNumber in
                        jump(toNewLine: lineNumber)
                    }
                    Divider()
                }
                .background(.bar)
            }
            .task(id: "\(change.contentKey)|\(reviewedBlob ?? "")|\(wantsSinceReview)|\(model.settings.syntaxHighlighting)") {
                showAll = false
                targetLineID = nil
                await load()
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
                                fontSize: model.settings.diffFontSize, showAll: $showAll, targetLineID: $targetLineID)
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
            let full = try await session.diff(for: change)
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
                    Toggle(isOn: Binding(get: { review.isReviewed }, set: { _ in onToggleReviewed() })) {
                        Label("Reviewed", systemImage: review.isReviewed ? "checkmark.circle.fill" : "circle")
                    }
                    .toggleStyle(.button)
                    .labelStyle(.titleAndIcon)
                    .controlSize(.small)
                    .fixedSize()
                    .help(review.isReviewed
                          ? "You reviewed this version. Click to mark it as not reviewed (⌘↩)."
                          : "Mark as reviewed and go to the next file to review (⌘↩)")
                }
                HStack(spacing: 6) {
                    Toggle(isOn: sideBySideBinding) {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .toggleStyle(.button)
                    .help(sideBySide
                          ? "Old and new side by side. Click for a single column (⌥⌘L)."
                          : "Show old and new side by side (⌥⌘L)")
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
                    Button {
                        if let diff { Workspace.copy(diff.unifiedText) }
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy the diff as a patch")
                    .disabled(diff == nil || diff?.hunks.isEmpty == true)
                    Button {
                        Workspace.reveal(path: change.path, in: worktreePath)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Reveal in Finder")
                    Button {
                        Workspace.open(path: change.path, in: worktreePath)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("Open with the default application")
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
                    Label(attribution.label + (attribution.detail.map { " · \($0)" } ?? ""), systemImage: "sparkles")
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
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Color.accentColor)
                // Drop words before truncating, so the time survives a narrow pane.
                ViewThatFits(in: .horizontal) {
                    Text("Changed since your review at \(when)")
                    Text("Changed since your \(when) review")
                    Text("Changed since review")
                }
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
                if let selection = info.showingSinceReview {
                    Picker("Show", selection: selection) {
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
            .font(.caption)
            .padding(.top, 1)
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

    private static let initialLimit = 2500
    /// Narrower than this, two columns are too cramped to read; show one instead.
    private static let minimumSplitWidth: CGFloat = 560

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
            let split = sideBySide && geometry.size.width >= Self.minimumSplitWidth
            let horizontal = !split && !wrap
            ScrollViewReader { proxy in
                ScrollView(horizontal ? [.vertical, .horizontal] : .vertical) {
                    Group {
                        if horizontal {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                rows(visible: visible, wrap: false)
                            }
                            .frame(width: max(unwrappedWidth, geometry.size.width), alignment: .leading)
                        } else if split {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                splitRows(visible: visible)
                            }
                        } else {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                rows(visible: visible, wrap: true)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    // A two-axis scroll view centers content smaller than itself; fill the
                    // viewport so short diffs stay pinned to the top-leading corner.
                    .frame(minWidth: horizontal ? geometry.size.width : nil,
                           maxWidth: .infinity,
                           minHeight: horizontal ? geometry.size.height : nil,
                           alignment: .topLeading)
                }
                .onChange(of: targetLineID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
                .onAppear {
                    if let id = targetLineID { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder
    private func rows(visible: Visible, wrap: Bool) -> some View {
        ForEach(visible.hunks) { hunk in
            HunkHeaderRow(hunk: hunk, fontSize: fontSize)
            ForEach(hunk.lines) { line in
                DiffLineRow(line: line, wrap: wrap, fontSize: fontSize, numberWidth: numberWidth,
                            syntax: decorations.syntax[line.id], emphasis: decorations.emphasis[line.id],
                            isTarget: line.id == targetLineID)
                    .id(line.id)
            }
        }
        truncationFooter(visible)
    }

    @ViewBuilder
    private func splitRows(visible: Visible) -> some View {
        ForEach(visible.hunks) { hunk in
            HunkHeaderRow(hunk: hunk, fontSize: fontSize)
            ForEach(SideBySide.rows(for: hunk)) { row in
                SplitLineRow(row: row, decorations: decorations, fontSize: fontSize, numberWidth: numberWidth,
                             isTarget: targetLineID != nil && (row.left?.id == targetLineID || row.right?.id == targetLineID))
                    .id(row.id)
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
                Spacer()
            }
            .padding()
        }
    }
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
        .background(DiffLineStyle.background(line.kind))
        .overlay {
            if isTarget {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
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
                      numberWidth: numberWidth)
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
        .background(line.map { DiffLineStyle.background($0.kind) } ?? Color.secondary.opacity(0.06))
    }
}
