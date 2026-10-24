import Foundation

/// One row of a side-by-side diff: the old line on the left, the new one on the right,
/// either of which may be missing.
public struct SplitRow: Identifiable, Sendable, Hashable {
    public let left: DiffLine?
    public let right: DiffLine?

    /// The right line's id when there is one, so a jump to a new-file line finds its row.
    public var id: Int { right?.id ?? left?.id ?? -1 }
}

public enum SideBySide {
    /// Lays out a hunk in two columns. Context lines sit on both sides; a run of deletions
    /// pairs up, row by row, with the additions that follow it, and whichever run is longer
    /// leaves the other side blank.
    public static func rows(for hunk: DiffHunk) -> [SplitRow] {
        var rows: [SplitRow] = []
        var deletions: [DiffLine] = []
        var additions: [DiffLine] = []
        var lastChange: DiffLineKind = .context

        func flush() {
            for index in 0..<max(deletions.count, additions.count) {
                rows.append(SplitRow(left: index < deletions.count ? deletions[index] : nil,
                                     right: index < additions.count ? additions[index] : nil))
            }
            deletions.removeAll()
            additions.removeAll()
        }

        for line in hunk.lines {
            switch line.kind {
            case .context:
                flush()
                rows.append(SplitRow(left: line, right: line))
                lastChange = .context
            case .deletion:
                if !additions.isEmpty { flush() }
                deletions.append(line)
                lastChange = .deletion
            case .addition:
                additions.append(line)
                lastChange = .addition
            case .noNewline:
                // "No newline at end of file" belongs to the side of the line before it.
                flush()
                switch lastChange {
                case .deletion: rows.append(SplitRow(left: line, right: nil))
                case .addition: rows.append(SplitRow(left: nil, right: line))
                default: rows.append(SplitRow(left: line, right: line))
                }
            }
        }
        flush()
        return rows
    }
}
