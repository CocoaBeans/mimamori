import Foundation

public enum SyntaxTokenKind: String, Sendable, Hashable, CaseIterable {
    case keyword, string, comment, number, type, attribute, key, tag
}

/// A colored run within one line, in `Character` offsets.
public struct SyntaxSpan: Sendable, Hashable {
    public var range: Range<Int>
    public var kind: SyntaxTokenKind

    public init(range: Range<Int>, kind: SyntaxTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// A line-at-a-time highlighter. It carries block comments and multi-line strings from one
/// line to the next through `State`, which is all a diff (a few runs of lines) needs.
public enum SyntaxHighlighter {
    public struct State: Sendable, Hashable {
        enum Mode: Sendable, Hashable {
            case normal
            case comment(close: [Character])
            case string(close: [Character])
            case tag
            case fence
        }

        var mode: Mode = .normal
        public init() {}
    }

    /// Longer lines (minified files) are left plain.
    public static let maxLineLength = 2000

    public static func highlight(_ line: String, language: SyntaxLanguage, state: inout State) -> [SyntaxSpan] {
        let characters = Array(line)
        guard characters.count <= maxLineLength else { return [] }
        var scanner = LineScanner(c: characters, lang: language, mode: state.mode)
        scanner.run()
        state.mode = scanner.mode
        return scanner.spans
    }

    /// Highlights consecutive lines of one file.
    public static func highlight(lines: [String], language: SyntaxLanguage) -> [[SyntaxSpan]] {
        var state = State()
        return lines.map { highlight($0, language: language, state: &state) }
    }
}

private struct LineScanner {
    let c: [Character]
    let lang: SyntaxLanguage
    var mode: SyntaxHighlighter.State.Mode
    var spans: [SyntaxSpan] = []
    var i = 0

    init(c: [Character], lang: SyntaxLanguage, mode: SyntaxHighlighter.State.Mode) {
        self.c = c
        self.lang = lang
        self.mode = mode
    }

    var n: Int { c.count }

    // MARK: Entry

    mutating func run() {
        // Finish whatever the previous line left open.
        switch mode {
        case .comment(let close):
            guard let end = find(close, from: 0) else { add(0, n, .comment); return }
            add(0, end + close.count, .comment)
            i = end + close.count
            mode = .normal
        case .string(let close):
            guard let end = stringEnd(closing: close, from: 0) else { add(0, n, .string); return }
            add(0, end, .string)
            i = end
            mode = .normal
        case .normal, .tag, .fence:
            break
        }
        switch lang.family {
        case .code, .json, .css: scanCode()
        case .yaml: scanYAML()
        case .keyValue: scanKeyValue()
        case .markup: scanMarkup()
        case .markdown: scanMarkdown()
        }
    }

    // MARK: Code

    mutating func scanCode() {
        if lang.directives, let first = firstNonSpace(from: i), c[first] == "#" {
            let end = identifierEnd(from: first + 1)
            add(first, end, .attribute)
            let directive = String(c[(first + 1)..<end])
            i = end
            if directive == "include" || directive == "import", let open = firstNonSpace(from: i), c[open] == "<" {
                let close = index(of: ">", from: open + 1).map { $0 + 1 } ?? n
                add(open, close, .string)
                i = close
            }
        }
        while i < n {
            let ch = c[i]
            if ch.isWhitespace { i += 1; continue }

            if let token = lang.lineComments.first(where: { matches($0, at: i) }), commentAllowed(token) {
                add(i, n, .comment)
                return
            }
            if !lang.blockOpen.isEmpty, matches(lang.blockOpen, at: i) {
                let from = i + lang.blockOpen.count
                if let end = find(lang.blockClose, from: from) {
                    add(i, end + lang.blockClose.count, .comment)
                    i = end + lang.blockClose.count
                } else {
                    add(i, n, .comment)
                    mode = .comment(close: lang.blockClose)
                    return
                }
                continue
            }
            if let delimiter = lang.multilineStrings.first(where: { matches($0, at: i) }) {
                if let end = stringEnd(closing: delimiter, from: i + delimiter.count) {
                    add(i, end, .string)
                    i = end
                } else {
                    add(i, n, .string)
                    mode = .string(close: delimiter)
                    return
                }
                continue
            }
            if lang.quotes.contains(ch) {
                if lang.lifetimes, ch == "'", isLifetime(at: i) {
                    let end = identifierEnd(from: i + 1)
                    add(i, end, .attribute)
                    i = end
                    continue
                }
                let end = stringEnd(closing: [ch], from: i + 1) ?? n
                let isKey = lang.family == .json && nextNonSpaceCharacter(from: end) == ":"
                add(i, end, isKey ? .key : .string)
                i = end
                continue
            }
            if lang.attributePrefixes.contains(ch), i + 1 < n, isIdentifierStart(c[i + 1]) {
                let end = identifierEnd(from: i + 1)
                add(i, end, .attribute)
                i = end
                continue
            }
            if lang.bracketAttributes, ch == "#", i + 1 < n, c[i + 1] == "[" || (c[i + 1] == "!" && i + 2 < n && c[i + 2] == "[") {
                let end = index(of: "]", from: i).map { $0 + 1 } ?? n
                add(i, end, .attribute)
                i = end
                continue
            }
            if let prefix = lang.variablePrefix, ch == prefix, let end = variableEnd(from: i + 1) {
                add(i, end, .attribute)
                i = end
                continue
            }
            if lang.family == .css {
                if ch == "#", let end = hexColorEnd(from: i + 1) {
                    add(i, end, .number)
                    i = end
                    continue
                }
                if ch == "!", i + 1 < n, isIdentifierStart(c[i + 1]) {
                    let end = identifierEnd(from: i + 1)
                    add(i, end, .keyword)
                    i = end
                    continue
                }
            }
            if lang.highlightsNumbers, isNumberStart(at: i) {
                let end = numberEnd(from: i)
                add(i, end, .number)
                i = end
                continue
            }
            if isIdentifierStart(ch) {
                let end = identifierEnd(from: i)
                classifyWord(from: i, to: end)
                i = end
                continue
            }
            i += 1
        }
    }

    mutating func classifyWord(from start: Int, to end: Int) {
        let word = String(c[start..<end])
        let lookup = lang.caseInsensitive ? word.lowercased() : word
        if lang.keywords.contains(lookup) {
            add(start, end, .keyword)
        } else if lang.family == .css, nextNonSpaceCharacter(from: end) == ":" {
            add(start, end, .key)
        } else if lang.types.contains(lookup) || (lang.capitalizedAreTypes && isTypeName(word)) {
            add(start, end, .type)
        }
    }

    private func isTypeName(_ word: String) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        // ALL_CAPS reads as a constant, not a type.
        return word.contains { $0.isLowercase }
    }

    // MARK: YAML and key = value

    mutating func scanYAML() {
        guard let first = firstNonSpace(from: 0) else { return }
        if first == 0, matches(Array("---"), at: 0) || matches(Array("..."), at: 0) {
            add(0, min(3, n), .keyword)
            i = 3
            scanCode()
            return
        }
        var start = first
        if c[start] == "-", start + 1 < n, c[start + 1] == " " {
            start = firstNonSpace(from: start + 1) ?? n
        }
        if let colon = yamlKeyEnd(from: start) {
            add(start, colon, .key)
            i = colon + 1
        } else {
            i = start
        }
        scanCode()
    }

    /// The `:` ending a mapping key that starts at `start`, if this line has one.
    private func yamlKeyEnd(from start: Int) -> Int? {
        guard start < n, c[start] != "#", c[start] != "{", c[start] != "[" else { return nil }
        var k = start
        if c[k] == "\"" || c[k] == "'" {
            k = stringEnd(closing: [c[k]], from: k + 1) ?? n
        }
        while k < n {
            let ch = c[k]
            if ch == ":", k + 1 == n || c[k + 1] == " " { return k > start ? k : nil }
            if ch == "#", k > start, c[k - 1] == " " { return nil }
            k += 1
        }
        return nil
    }

    mutating func scanKeyValue() {
        guard let first = firstNonSpace(from: 0) else { return }
        if c[first] == "#" || c[first] == ";" {
            add(first, n, .comment)
            return
        }
        if c[first] == "[" {
            let end = index(of: "]", from: first).map { $0 + 1 } ?? n
            add(first, end, .type)
            i = end
            scanCode()
            return
        }
        var keyStart = first
        if matches(Array("export "), at: first) {
            add(first, first + 6, .keyword)
            keyStart = firstNonSpace(from: first + 7) ?? n
        }
        if let equals = index(of: "=", from: keyStart),
           !c[keyStart..<equals].contains(where: { $0 == "\"" || $0 == "'" || $0 == "[" || $0 == "{" }) {
            var keyEnd = equals
            while keyEnd > keyStart, c[keyEnd - 1].isWhitespace { keyEnd -= 1 }
            add(keyStart, keyEnd, .key)
            i = equals + 1
        } else {
            i = keyStart
        }
        scanCode()
    }

    // MARK: Markup

    mutating func scanMarkup() {
        while i < n {
            if mode == .tag {
                scanInsideTag()
                continue
            }
            if matches(Array("<!--"), at: i) {
                let close = Array("-->")
                if let end = find(close, from: i + 4) {
                    add(i, end + 3, .comment)
                    i = end + 3
                } else {
                    add(i, n, .comment)
                    mode = .comment(close: close)
                    return
                }
                continue
            }
            if c[i] == "<", i + 1 < n, c[i + 1].isLetter || "/!?".contains(c[i + 1]) {
                var j = i + 1
                if "/!?".contains(c[j]) { j += 1 }
                let end = run(from: j) { $0.isLetter || $0.isNumber || ":-_.".contains($0) }
                add(i, end, .tag)
                i = end
                mode = .tag
                continue
            }
            if c[i] == "&", let semicolon = index(of: ";", from: i + 1), semicolon - i <= 10,
               c[(i + 1)..<semicolon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "#" }) {
                add(i, semicolon + 1, .attribute)
                i = semicolon + 1
                continue
            }
            i += 1
        }
    }

    private mutating func scanInsideTag() {
        let ch = c[i]
        if ch.isWhitespace {
            i += 1
        } else if ch == ">" {
            add(i, i + 1, .tag)
            i += 1
            mode = .normal
        } else if (ch == "/" || ch == "?"), i + 1 < n, c[i + 1] == ">" {
            add(i, i + 2, .tag)
            i += 2
            mode = .normal
        } else if ch == "\"" || ch == "'" {
            let end = stringEnd(closing: [ch], from: i + 1, escapes: false) ?? n
            add(i, end, .string)
            i = end
        } else if ch.isLetter || ch == "_" || ch == ":" || ch == "@" {
            let end = run(from: i) { $0.isLetter || $0.isNumber || "-:._@".contains($0) }
            add(i, end, .attribute)
            i = end
        } else {
            i += 1
        }
    }

    // MARK: Markdown

    mutating func scanMarkdown() {
        let first = firstNonSpace(from: 0)
        let isFence = first.map { matches(Array("```"), at: $0) || matches(Array("~~~"), at: $0) } ?? false
        if mode == .fence {
            if let first, isFence {
                add(first, n, .attribute)
                mode = .normal
            }
            return  // Code inside a fence is left plain: its language is unknown here.
        }
        guard let first else { return }
        if isFence {
            add(first, n, .attribute)
            mode = .fence
            return
        }
        if c[first] == "#" {
            add(first, n, .keyword)
            return
        }
        if c[first] == ">" {
            add(first, n, .comment)
            return
        }
        i = first
        if "-*+".contains(c[first]), first + 1 < n, c[first + 1] == " " {
            add(first, first + 1, .keyword)
            i = first + 2
        } else if c[first].isNumber {
            let end = run(from: first) { $0.isNumber }
            if end < n, c[end] == "." || c[end] == ")" {
                add(first, end + 1, .keyword)
                i = end + 1
            }
        }
        while i < n {
            if c[i] == "`", let end = index(of: "`", from: i + 1) {
                add(i, end + 1, .string)
                i = end + 1
            } else if c[i] == "]", i + 1 < n, c[i + 1] == "(", let end = index(of: ")", from: i + 2) {
                add(i + 1, end + 1, .attribute)
                i = end + 1
            } else {
                i += 1
            }
        }
    }

    // MARK: Pieces

    private mutating func add(_ start: Int, _ end: Int, _ kind: SyntaxTokenKind) {
        let end = min(end, n)
        if end > start { spans.append(SyntaxSpan(range: start..<end, kind: kind)) }
    }

    private func matches(_ token: [Character], at index: Int) -> Bool {
        guard !token.isEmpty, index >= 0, index + token.count <= n else { return false }
        for k in 0..<token.count where c[index + k] != token[k] { return false }
        return true
    }

    private func find(_ token: [Character], from start: Int) -> Int? {
        var j = start
        while j + token.count <= n {
            if matches(token, at: j) { return j }
            j += 1
        }
        return nil
    }

    private func index(of character: Character, from start: Int) -> Int? {
        var j = start
        while j < n {
            if c[j] == character { return j }
            j += 1
        }
        return nil
    }

    private func run(from start: Int, while predicate: (Character) -> Bool) -> Int {
        var j = start
        while j < n, predicate(c[j]) { j += 1 }
        return j
    }

    private func firstNonSpace(from start: Int) -> Int? {
        var j = start
        while j < n, c[j].isWhitespace { j += 1 }
        return j < n ? j : nil
    }

    private func nextNonSpaceCharacter(from start: Int) -> Character? {
        firstNonSpace(from: start).map { c[$0] }
    }

    /// The index just past the closing delimiter, or nil when the line ends first.
    private func stringEnd(closing: [Character], from start: Int, escapes: Bool = true) -> Int? {
        var j = start
        while j < n {
            if escapes, c[j] == "\\" {
                j += 2
                continue
            }
            if matches(closing, at: j) { return j + closing.count }
            j += 1
        }
        return nil
    }

    private func commentAllowed(_ token: [Character]) -> Bool {
        guard lang.hashCommentNeedsSpace, token == ["#"] else { return true }
        return i == 0 || c[i - 1].isWhitespace
    }

    private func isIdentifierStart(_ ch: Character) -> Bool {
        ch.isLetter || ch == "_" || lang.identifierExtras.contains(ch)
    }

    private func isIdentifierPart(_ ch: Character) -> Bool {
        isIdentifierStart(ch) || ch.isNumber
    }

    private func identifierEnd(from start: Int) -> Int {
        var end = run(from: start, while: isIdentifierPart)
        // Ruby's `defined?` and `save!`.
        if lang.name == "Ruby", end < n, c[end] == "?" || c[end] == "!" { end += 1 }
        return end
    }

    private func isAsciiDigit(_ ch: Character) -> Bool { ch.isASCII && ch.isNumber }

    private func isNumberStart(at index: Int) -> Bool {
        let ch = c[index]
        let previousIsWord = index > 0 && (isIdentifierPart(c[index - 1]) || c[index - 1] == ".")
        if isAsciiDigit(ch) { return !previousIsWord }
        if ch == ".", index + 1 < n, isAsciiDigit(c[index + 1]) { return !previousIsWord }
        return false
    }

    private func numberEnd(from start: Int) -> Int {
        let hex = matches(["0", "x"], at: start) || matches(["0", "X"], at: start)
        var j = start
        while j < n {
            let ch = c[j]
            if ch.isLetter || isAsciiDigit(ch) || ch == "_" {
                j += 1
            } else if ch == ".", j + 1 < n, isAsciiDigit(c[j + 1]) {
                j += 1
            } else if !hex, ch == "+" || ch == "-", j > start, c[j - 1] == "e" || c[j - 1] == "E" {
                j += 1
            } else {
                break
            }
        }
        return j
    }

    private func isLifetime(at index: Int) -> Bool {
        guard index + 1 < n, isIdentifierStart(c[index + 1]) else { return false }
        return !(index + 2 < n && c[index + 2] == "'")
    }

    private func variableEnd(from start: Int) -> Int? {
        guard start < n else { return nil }
        let next = c[start]
        if next == "{" || next == "(" {
            let close: Character = next == "{" ? "}" : ")"
            return index(of: close, from: start).map { $0 + 1 } ?? n
        }
        if isIdentifierStart(next) || isAsciiDigit(next) {
            return run(from: start) { $0.isLetter || $0.isNumber || $0 == "_" }
        }
        if "@#?*!$-".contains(next) { return start + 1 }
        return nil
    }

    private func hexColorEnd(from start: Int) -> Int? {
        let end = run(from: start) { $0.isHexDigit }
        let length = end - start
        guard [3, 4, 6, 8].contains(length), end == n || !isIdentifierPart(c[end]) else { return nil }
        return end
    }
}
