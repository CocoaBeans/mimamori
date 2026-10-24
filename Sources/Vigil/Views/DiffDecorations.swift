import AppKit
import SwiftUI
import VigilCore

/// How a diff line's text is shown: tabs as four spaces. Highlighting and emphasis offsets
/// are computed on this text, so both have to agree on it.
enum DiffText {
    static func display(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: "    ")
    }

    /// The line with syntax colors, then word-level emphasis on top.
    static func attributed(_ text: String, syntax: [SyntaxSpan]?, emphasis: [Range<Int>]?, emphasisColor: Color) -> AttributedString {
        var attributed = AttributedString(text)
        let syntax = syntax ?? []
        let emphasis = emphasis ?? []
        guard !syntax.isEmpty || !emphasis.isEmpty else { return attributed }
        // One walk to find every character's index; spans then index straight into it.
        let characters = attributed.characters
        var indices: [AttributedString.Index] = []
        indices.reserveCapacity(text.count + 1)
        var index = characters.startIndex
        while index < characters.endIndex {
            indices.append(index)
            index = characters.index(after: index)
        }
        indices.append(characters.endIndex)
        let count = indices.count - 1
        for span in syntax where span.range.lowerBound >= 0 && span.range.upperBound <= count && !span.range.isEmpty {
            attributed[indices[span.range.lowerBound]..<indices[span.range.upperBound]].foregroundColor = SyntaxPalette.color(span.kind)
        }
        for range in emphasis where range.lowerBound >= 0 && range.upperBound <= count && !range.isEmpty {
            attributed[indices[range.lowerBound]..<indices[range.upperBound]].backgroundColor = emphasisColor
        }
        return attributed
    }
}

/// Everything drawn over a diff's text, by line id: syntax colors and word-level emphasis.
/// Computed once per loaded diff, off the main thread.
struct DiffDecorations: Sendable {
    var syntax: [Int: [SyntaxSpan]] = [:]
    var emphasis: [Int: [Range<Int>]] = [:]
    /// The widest line in monospaced columns, for laying out unwrapped lines without
    /// measuring every row.
    var widestLineColumns = 0

    static let empty = DiffDecorations()
    /// Past these sizes the diff is shown plain; working it out would cost more than it helps.
    static let maxHighlightedLines = 20_000
    static let maxEmphasisLines = 10_000

    static func compute(for diff: FileDiff, path: String, highlightSyntax: Bool) -> DiffDecorations {
        var result = DiffDecorations()
        result.widestLineColumns = diff.hunks.lazy.flatMap(\.lines).map { columns(of: $0.text) }.max() ?? 0
        if diff.lineCount <= maxEmphasisLines {
            result.emphasis = emphasis(for: diff.hunks)
        }
        if highlightSyntax, diff.lineCount <= maxHighlightedLines, let language = SyntaxLanguage.forPath(path) {
            result.syntax = syntax(for: diff.hunks, language: language)
        }
        return result
    }

    /// Columns a line takes in a monospaced font: tabs as four, wide characters as two.
    static func columns(of text: String) -> Int {
        text.reduce(0) { total, character in
            total + (character == "\t" ? 4 : character.isASCII ? 1 : 2)
        }
    }

    /// Each hunk is highlighted on its own, with one state per side: deletions continue the
    /// old file, additions the new one, and context lines belong to both.
    private static func syntax(for hunks: [DiffHunk], language: SyntaxLanguage) -> [Int: [SyntaxSpan]] {
        var result: [Int: [SyntaxSpan]] = [:]
        for hunk in hunks {
            var old = SyntaxHighlighter.State()
            var new = SyntaxHighlighter.State()
            for line in hunk.lines {
                let text = DiffText.display(line.text)
                let spans: [SyntaxSpan]
                switch line.kind {
                case .context:
                    spans = SyntaxHighlighter.highlight(text, language: language, state: &new)
                    old = new
                case .deletion:
                    spans = SyntaxHighlighter.highlight(text, language: language, state: &old)
                case .addition:
                    spans = SyntaxHighlighter.highlight(text, language: language, state: &new)
                case .noNewline:
                    continue
                }
                if !spans.isEmpty { result[line.id] = spans }
            }
        }
        return result
    }

    /// Character ranges to emphasise, for paired deletion and addition runs.
    private static func emphasis(for hunks: [DiffHunk]) -> [Int: [Range<Int>]] {
        var result: [Int: [Range<Int>]] = [:]
        for hunk in hunks {
            var deletions: [DiffLine] = []
            var additions: [DiffLine] = []
            func flush() {
                for index in 0..<min(deletions.count, additions.count) {
                    let old = DiffText.display(deletions[index].text)
                    let new = DiffText.display(additions[index].text)
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
}

/// Xcode-like colors for each kind of token, in light and dark.
enum SyntaxPalette {
    static func color(_ kind: SyntaxTokenKind) -> Color { colors[kind] ?? .primary }

    private static let colors: [SyntaxTokenKind: Color] = [
        .keyword: dynamic(light: 0x9B2393, dark: 0xFC5FA3),
        .string: dynamic(light: 0xC41A16, dark: 0xFC6A5D),
        .comment: dynamic(light: 0x5D6C79, dark: 0x7F8C98),
        .number: dynamic(light: 0x1C00CF, dark: 0xD0BF69),
        .type: dynamic(light: 0x0B4F79, dark: 0x5DD8FF),
        .attribute: dynamic(light: 0x815F03, dark: 0xFD8F3F),
        .key: dynamic(light: 0x326D74, dark: 0x67B7A4),
        .tag: dynamic(light: 0x0F68A0, dark: 0x41A1C0),
    ]

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let lightColor = color(light)
        let darkColor = color(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        })
    }
}
