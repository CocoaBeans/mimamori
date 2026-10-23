import SwiftUI
import VigilCore

struct DiffView: View {
    @Environment(AppModel.self) private var model
    let session: WorktreeSession
    let change: FileChange

    @State private var diff: FileDiff?
    @State private var errorText: String?
    @State private var showAll = false

    var body: some View {
        VStack(spacing: 0) {
            DiffHeaderView(change: change, diff: diff, worktreePath: session.id)
            Divider()
            body2
        }
        .task(id: change.contentKey) {
            showAll = false
            await load()
        }
    }

    @ViewBuilder
    private var body2: some View {
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
                                fontSize: model.settings.diffFontSize, showAll: $showAll)
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
                    Text("untracked")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if change.isStaged {
                    Text("staged")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if !change.isBinary {
                    DeltaText(additions: change.additions, deletions: change.deletions)
                }
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
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(change.flags.sorted { $0.severity > $1.severity }) { flag in
                        HStack(spacing: 6) {
                            Image(systemName: flag.rule.systemImage)
                                .foregroundStyle(flag.severity.color)
                                .frame(width: 14)
                            Text(flag.message)
                            if let line = flag.line {
                                Text("line \(line)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

struct DiffContentView: View {
    let diff: FileDiff
    let wrap: Bool
    let fontSize: Double
    @Binding var showAll: Bool

    private static let initialLimit = 2500

    private var visibleHunks: (hunks: [DiffHunk], truncated: Bool) {
        guard !showAll, diff.lineCount > Self.initialLimit else { return (diff.hunks, false) }
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
        return (result, true)
    }

    private var numberWidth: CGFloat {
        let maxNumber = diff.hunks.last.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) } ?? 999
        let digits = max(3, String(maxNumber).count)
        return CGFloat(digits) * fontSize * 0.62 + 10
    }

    var body: some View {
        let visible = visibleHunks
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visible.hunks) { hunk in
                    HunkHeaderRow(hunk: hunk, fontSize: fontSize)
                    ForEach(hunk.lines) { line in
                        DiffLineRow(line: line, wrap: wrap, fontSize: fontSize, numberWidth: numberWidth)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
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

    private var background: Color {
        switch line.kind {
        case .addition: Color.green.opacity(0.13)
        case .deletion: Color.red.opacity(0.13)
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

    private var text: String {
        line.text.replacingOccurrences(of: "\t", with: "    ")
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
            Text(verbatim: text)
                .lineLimit(wrap ? nil : 1)
                .truncationMode(.tail)
                .foregroundStyle(line.kind == .noNewline ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .font(.system(size: fontSize, design: .monospaced))
        .padding(.vertical, 1)
        .background(background)
    }
}
