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

    var body: some View {
        VStack(spacing: 0) {
            DiffHeaderView(change: change, diff: diff, worktreePath: session.id) { lineNumber in
                jump(toNewLine: lineNumber)
            }
            Divider()
            content
        }
        .task(id: change.contentKey) {
            showAll = false
            targetLineID = nil
            await load()
        }
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
                ContentUnavailableView("No Text Changes", systemImage: "doc",
                                       description: Text(diff.isBinary ? "Binary content changed." : "Only metadata (such as file mode) changed."))
            } else {
                DiffContentView(diff: diff, wrap: model.settings.wrapDiffLines,
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
    }

    private func load() async {
        errorText = nil
        if diff?.path != change.path { diff = nil }
        do {
            diff = try await session.diff(for: change)
            if diff == nil { errorText = "git produced no diff for this file." }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct DiffHeaderView: View {
    let change: FileChange
    let diff: FileDiff?
    let worktreePath: String
    let onJump: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusGlyph(kind: change.kind)
                Text(change.path)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if change.isUntracked {
                    Tag("untracked")
                }
                if change.isStaged {
                    Tag("staged")
                }
                Spacer()
                if !change.isBinary {
                    DeltaText(additions: change.additions, deletions: change.deletions)
                }
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
            if let old = change.oldPath {
                Text("renamed from \(old)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if change.modeChanged {
                Text("mode \(change.oldMode) → \(change.newMode)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
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

    private struct Tag: View {
        let text: String
        init(_ text: String) { self.text = text }
        var body: some View {
            Text(text)
                .font(.caption2.weight(.medium))
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
    let wrap: Bool
    let fontSize: Double
    @Binding var showAll: Bool
    @Binding var targetLineID: Int?

    private static let initialLimit = 2500
    /// Above this many lines the horizontal (no-wrap) layout falls back to wrapping,
    /// because it needs a non-lazy stack to measure the widest line.
    private static let horizontalLimit = 4000

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

    /// Character ranges to emphasise, keyed by line id, for paired deletion/addition runs.
    private static func highlights(for hunks: [DiffHunk]) -> [Int: [Range<Int>]] {
        var result: [Int: [Range<Int>]] = [:]
        for hunk in hunks {
            var deletions: [DiffLine] = []
            var additions: [DiffLine] = []
            func flush() {
                let pairs = min(deletions.count, additions.count)
                for index in 0..<pairs {
                    let old = DiffLineRow.displayText(deletions[index].text)
                    let new = DiffLineRow.displayText(additions[index].text)
                    if let ranges = IntralineDiff.changedRanges(old: old, new: new) {
                        if !ranges.old.isEmpty { result[deletions[index].id] = ranges.old }
                        if !ranges.new.isEmpty { result[additions[index].id] = ranges.new }
                    }
                }
                deletions.removeAll()
                additions.removeAll()
            }
            for line in hunk.lines {
                switch line.kind {
                case .deletion:
                    if !additions.isEmpty { flush() }
                    deletions.append(line)
                case .addition:
                    additions.append(line)
                case .context:
                    flush()
                case .noNewline:
                    continue
                }
            }
            flush()
        }
        return result
    }

    var body: some View {
        let visible = visible
        let highlights = Self.highlights(for: visible.hunks)
        let horizontal = !wrap && visible.lineCount <= Self.horizontalLimit
        ScrollViewReader { proxy in
            ScrollView(horizontal ? [.vertical, .horizontal] : .vertical) {
                Group {
                    if horizontal {
                        VStack(alignment: .leading, spacing: 0) {
                            rows(visible: visible, highlights: highlights, wrap: false)
                        }
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            rows(visible: visible, highlights: highlights, wrap: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
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

    @ViewBuilder
    private func rows(visible: Visible, highlights: [Int: [Range<Int>]], wrap: Bool) -> some View {
        ForEach(visible.hunks) { hunk in
            HunkHeaderRow(hunk: hunk, fontSize: fontSize)
            ForEach(hunk.lines) { line in
                DiffLineRow(line: line, wrap: wrap, fontSize: fontSize, numberWidth: numberWidth,
                            highlights: highlights[line.id], isTarget: line.id == targetLineID)
                    .id(line.id)
            }
        }
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
    let highlights: [Range<Int>]?
    let isTarget: Bool

    static func displayText(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: "    ")
    }

    private var background: Color {
        switch line.kind {
        case .addition: Color.green.opacity(0.13)
        case .deletion: Color.red.opacity(0.13)
        case .context, .noNewline: .clear
        }
    }

    private var emphasis: Color {
        switch line.kind {
        case .addition: Color.green.opacity(0.32)
        case .deletion: Color.red.opacity(0.32)
        case .context, .noNewline: .clear
        }
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        case .context: " "
        case .noNewline: "\\"
        }
    }

    private var attributedText: AttributedString {
        let text = Self.displayText(line.text)
        var attributed = AttributedString(text)
        guard let highlights, !highlights.isEmpty else { return attributed }
        let characters = attributed.characters
        let count = characters.count
        for range in highlights where range.lowerBound >= 0 && range.upperBound <= count && !range.isEmpty {
            let start = characters.index(characters.startIndex, offsetBy: range.lowerBound)
            let end = characters.index(start, offsetBy: range.count)
            attributed[start..<end].backgroundColor = emphasis
        }
        return attributed
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
            Text(attributedText)
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
        .background(background)
        .overlay {
            if isTarget {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
    }
}
