import Foundation

/// Review notes as one prompt for an agent: a plain block per note, in a fixed shape so it reads
/// the same to every agent, each with the lines it was written on.
public enum ReviewNotePrompt {
    /// Quoted lines per note, at most; more is marked with "…".
    public static let quoteLimit = 12

    /// The prompt for `notes`, about the changes on `branch`, in the order given.
    public static func format(_ notes: [ReviewNote], branch: String) -> String {
        let count = notes.count == 1 ? "1 note" : "\(notes.count) notes"
        let opening = "Review notes on your changes on \(branch) (\(count)), written in Mimamori, the review app "
            + "watching this worktree. Address each one, then say what you changed."
        return ([opening] + notes.map(block)).joined(separator: "\n\n") + "\n"
    }

    static func block(_ note: ReviewNote) -> String {
        var lines = ["File: \(note.path)"]
        if let range = note.lines {
            let side = note.side == .old ? "Removed lines" : "Lines"
            lines.append(range.count == 1 ? "\(side.dropLast()): \(range.lowerBound)" : "\(side): \(range.lowerBound)-\(range.upperBound)")
        } else {
            lines.append("Scope: file")
        }
        if !note.quote.isEmpty {
            lines.append("Code:")
            lines += note.quote.prefix(quoteLimit).map { "    " + $0 }
            if note.quote.count > quoteLimit { lines.append("    …") }
        }
        lines.append("User comment: \"\(escape(note.text))\"")
        return lines.joined(separator: "\n")
    }

    /// The note's text on one line, safe inside double quotes.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
