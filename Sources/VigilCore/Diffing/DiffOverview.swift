import Foundation

/// Where a diff's changes sit among its rows, for the overview strip beside it: runs of added
/// and removed lines as fractions of the whole, where each hunk starts, and which row lies at
/// any point down the strip, to jump to.
public struct DiffOverview: Equatable, Sendable {
    public enum Kind: Sendable, Equatable {
        case addition, deletion
        /// A side-by-side row with a line removed on the left and one added on the right.
        case change
    }

    public struct Mark: Equatable, Sendable {
        public var kind: Kind
        /// Where the run starts and how much of the diff it covers, each 0…1.
        public var start: Double
        public var length: Double
    }

    /// One row as the diff draws it: a hunk's header, or a line (in two columns, a pair).
    public struct Row: Equatable, Sendable {
        public var hunk: Int
        /// The line's id, as the diff's rows are identified; nil for a hunk's header.
        public var id: Int?
        public var kind: Kind?
    }

    public private(set) var rows: [Row] = []
    public private(set) var marks: [Mark] = []
    /// Where each hunk's header sits, 0…1.
    public private(set) var hunkStarts: [Double] = []

    /// `sideBySide` lays the rows out as the two-column diff does (`SideBySide.rows`).
    public init(hunks: [DiffHunk], sideBySide: Bool) {
        for hunk in hunks {
            rows.append(Row(hunk: hunk.id, id: nil, kind: nil))
            if sideBySide {
                for row in SideBySide.rows(for: hunk) {
                    let kind: Kind? = switch (row.left?.kind, row.right?.kind) {
                    case (.deletion?, .addition?): .change
                    case (.deletion?, _): .deletion
                    case (_, .addition?): .addition
                    default: nil
                    }
                    rows.append(Row(hunk: hunk.id, id: row.id, kind: kind))
                }
            } else {
                for line in hunk.lines {
                    let kind: Kind? = switch line.kind {
                    case .addition: .addition
                    case .deletion: .deletion
                    case .context, .noNewline: nil
                    }
                    rows.append(Row(hunk: hunk.id, id: line.id, kind: kind))
                }
            }
        }
        guard !rows.isEmpty else { return }
        let count = Double(rows.count)
        // One mark per run of rows of the same kind.
        var index = 0
        while index < rows.count {
            if rows[index].id == nil { hunkStarts.append(Double(index) / count) }
            guard let kind = rows[index].kind else {
                index += 1
                continue
            }
            var end = index + 1
            while end < rows.count, rows[end].kind == kind { end += 1 }
            marks.append(Mark(kind: kind, start: Double(index) / count, length: Double(end - index) / count))
            index = end
        }
    }

    /// The row `fraction` of the way down, or the first line after it when that is a header.
    public func row(at fraction: Double) -> Row? {
        guard !rows.isEmpty else { return nil }
        let index = min(rows.count - 1, max(0, Int(fraction * Double(rows.count))))
        return rows[index...].first { $0.id != nil } ?? rows[..<index].last { $0.id != nil }
    }
}
