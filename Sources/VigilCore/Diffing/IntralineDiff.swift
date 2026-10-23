import Foundation

/// Finds which parts of a changed line actually differ, so a diff view can
/// emphasise the edited words instead of the whole line.
public enum IntralineDiff {
    /// Character-offset ranges that changed on each side, or nil when the lines
    /// are too different for highlighting to help.
    public static func changedRanges(old: String, new: String, maxTokens: Int = 240) -> (old: [Range<Int>], new: [Range<Int>])? {
        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)
        guard !oldTokens.isEmpty, !newTokens.isEmpty, oldTokens.count <= maxTokens, newTokens.count <= maxTokens else {
            return nil
        }

        // Intern token text so the LCS compares integers.
        var ids: [String: Int] = [:]
        func id(_ text: String) -> Int {
            if let existing = ids[text] { return existing }
            let next = ids.count
            ids[text] = next
            return next
        }
        let a = oldTokens.map { id($0.text) }
        let b = newTokens.map { id($0.text) }
        let n = a.count, m = b.count

        var table = [Int](repeating: 0, count: (n + 1) * (m + 1))
        @inline(__always) func at(_ i: Int, _ j: Int) -> Int { table[i * (m + 1) + j] }
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * (m + 1) + j] = a[i] == b[j] ? at(i + 1, j + 1) + 1 : max(at(i + 1, j), at(i, j + 1))
            }
        }

        var oldChanged: [Range<Int>] = []
        var newChanged: [Range<Int>] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                i += 1; j += 1
            } else if at(i + 1, j) >= at(i, j + 1) {
                oldChanged.append(oldTokens[i].range); i += 1
            } else {
                newChanged.append(newTokens[j].range); j += 1
            }
        }
        while i < n { oldChanged.append(oldTokens[i].range); i += 1 }
        while j < m { newChanged.append(newTokens[j].range); j += 1 }

        let mergedOld = merge(oldChanged)
        let mergedNew = merge(newChanged)
        guard !mergedOld.isEmpty || !mergedNew.isEmpty else { return nil }

        // When almost everything changed, highlighting is noise.
        let oldCount = mergedOld.reduce(0) { $0 + $1.count }
        let newCount = mergedNew.reduce(0) { $0 + $1.count }
        if oldCount * 4 > old.count * 3 && newCount * 4 > new.count * 3 { return nil }
        return (mergedOld, mergedNew)
    }

    struct Token {
        let range: Range<Int>
        let text: String
    }

    /// Splits into words, whitespace runs and single punctuation characters.
    static func tokenize(_ string: String) -> [Token] {
        let characters = Array(string)
        var tokens: [Token] = []
        var start = 0
        var currentClass: Int? = nil

        func classify(_ character: Character) -> Int {
            if character.isLetter || character.isNumber || character == "_" { return 0 }
            if character.isWhitespace { return 1 }
            return 2
        }
        func close(at end: Int) {
            guard currentClass != nil, end > start else { return }
            tokens.append(Token(range: start..<end, text: String(characters[start..<end])))
        }

        for (index, character) in characters.enumerated() {
            let kind = classify(character)
            if let current = currentClass, current == kind, kind != 2 { continue }
            close(at: index)
            start = index
            currentClass = kind
        }
        close(at: characters.count)
        return tokens
    }

    /// Joins touching or near-touching ranges (gap of one character) into one.
    static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

public extension FileDiff {
    /// The diff as unified patch text, suitable for the clipboard or `git apply`.
    var unifiedText: String {
        var lines = headerLines
        if !lines.contains(where: { $0.hasPrefix("--- ") }) && !isBinary && !hunks.isEmpty {
            lines.append(oldPath.map { "--- a/\($0)" } ?? "--- /dev/null")
            lines.append(newPath.map { "+++ b/\($0)" } ?? "+++ /dev/null")
        }
        for hunk in hunks {
            lines.append(hunk.header)
            for line in hunk.lines {
                switch line.kind {
                case .context: lines.append(" " + line.text)
                case .addition: lines.append("+" + line.text)
                case .deletion: lines.append("-" + line.text)
                case .noNewline: lines.append("\\ No newline at end of file")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
