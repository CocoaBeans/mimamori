import Foundation

public enum DiffLineKind: String, Sendable, Codable, Hashable {
    case context, addition, deletion, noNewline
}

public struct DiffLine: Sendable, Hashable, Identifiable {
    /// Sequential within the file diff; stable for SwiftUI identity.
    public let id: Int
    public let kind: DiffLineKind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?

    public init(id: Int, kind: DiffLineKind, text: String, oldNumber: Int?, newNumber: Int?) {
        self.id = id
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

public struct DiffHunk: Sendable, Hashable, Identifiable {
    public let id: Int
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]

    public init(id: Int, header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine] = []) {
        self.id = id
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }

    public var additions: Int { lines.lazy.filter { $0.kind == .addition }.count }
    public var deletions: Int { lines.lazy.filter { $0.kind == .deletion }.count }
}

public struct FileDiff: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var oldPath: String?
    public var newPath: String?
    public var hunks: [DiffHunk]
    public var isBinary: Bool
    public var isNewFile: Bool
    public var isDeletedFile: Bool
    public var isRename: Bool
    public var oldMode: String?
    public var newMode: String?
    public var similarity: Int?
    public var headerLines: [String]

    public init(oldPath: String? = nil, newPath: String? = nil, hunks: [DiffHunk] = [], isBinary: Bool = false,
                isNewFile: Bool = false, isDeletedFile: Bool = false, isRename: Bool = false,
                oldMode: String? = nil, newMode: String? = nil, similarity: Int? = nil, headerLines: [String] = []) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.hunks = hunks
        self.isBinary = isBinary
        self.isNewFile = isNewFile
        self.isDeletedFile = isDeletedFile
        self.isRename = isRename
        self.oldMode = oldMode
        self.newMode = newMode
        self.similarity = similarity
        self.headerLines = headerLines
    }

    public var path: String { newPath ?? oldPath ?? "" }
    public var additions: Int { hunks.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.deletions } }
    public var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }
    public var addedLines: [DiffLine] { hunks.flatMap { $0.lines.filter { $0.kind == .addition } } }
}

/// Parses unified diffs as produced by `git diff -p`.
public enum DiffParser {
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff? = nil
        var hunk: DiffHunk? = nil
        var gitHeader = ""
        var lineID = 0
        var oldNumber = 0
        var newNumber = 0
        var remainingOld = 0
        var remainingNew = 0

        func finishHunk() {
            if let finished = hunk { current?.hunks.append(finished) }
            hunk = nil
        }
        func finishFile() {
            finishHunk()
            if var file = current {
                if file.oldPath == nil && file.newPath == nil, let (old, new) = Self.pathsFromGitHeader(gitHeader) {
                    file.oldPath = file.isNewFile ? nil : old
                    file.newPath = file.isDeletedFile ? nil : new
                }
                files.append(file)
            }
            current = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("diff --git ") {
                finishFile()
                current = FileDiff(headerLines: [line])
                gitHeader = String(line.dropFirst("diff --git ".count))
                lineID = 0
                continue
            }
            guard current != nil else { continue }

            if hunk != nil, remainingOld <= 0, remainingNew <= 0, !line.hasPrefix("\\") {
                finishHunk()
            }

            if hunk == nil {
                if line.hasPrefix("@@") {
                    guard let parsed = Self.parseHunkHeader(line) else { continue }
                    hunk = DiffHunk(id: current!.hunks.count, header: line,
                                    oldStart: parsed.oldStart, oldCount: parsed.oldCount,
                                    newStart: parsed.newStart, newCount: parsed.newCount)
                    oldNumber = parsed.oldStart
                    newNumber = parsed.newStart
                    remainingOld = parsed.oldCount
                    remainingNew = parsed.newCount
                    // Make the paths concrete now if the header did not.
                    if current!.oldPath == nil && current!.newPath == nil, let (old, new) = Self.pathsFromGitHeader(gitHeader) {
                        current!.oldPath = current!.isNewFile ? nil : old
                        current!.newPath = current!.isDeletedFile ? nil : new
                    }
                } else {
                    Self.applyHeaderLine(line, to: &current!)
                }
                continue
            }

            // Inside a hunk.
            let kind: DiffLineKind
            var body = line
            switch line.first {
            case "+":
                kind = .addition
                body.removeFirst()
            case "-":
                kind = .deletion
                body.removeFirst()
            case " ":
                kind = .context
                body.removeFirst()
            case "\\":
                kind = .noNewline
            case nil:
                kind = .context  // some tools strip the trailing space of empty context lines
            default:
                kind = .context
            }
            if body.hasSuffix("\r") { body.removeLast() }

            let diffLine: DiffLine
            switch kind {
            case .context:
                diffLine = DiffLine(id: lineID, kind: kind, text: body, oldNumber: oldNumber, newNumber: newNumber)
                oldNumber += 1; newNumber += 1
                remainingOld -= 1; remainingNew -= 1
            case .addition:
                diffLine = DiffLine(id: lineID, kind: kind, text: body, oldNumber: nil, newNumber: newNumber)
                newNumber += 1
                remainingNew -= 1
            case .deletion:
                diffLine = DiffLine(id: lineID, kind: kind, text: body, oldNumber: oldNumber, newNumber: nil)
                oldNumber += 1
                remainingOld -= 1
            case .noNewline:
                diffLine = DiffLine(id: lineID, kind: kind, text: "No newline at end of file", oldNumber: nil, newNumber: nil)
            }
            lineID += 1
            hunk?.lines.append(diffLine)
        }
        finishFile()
        return files
    }

    // MARK: Header handling

    private static func applyHeaderLine(_ line: String, to file: inout FileDiff) {
        file.headerLines.append(line)
        if line.hasPrefix("--- ") {
            file.oldPath = stripPrefix(unquote(String(line.dropFirst(4))), "a/")
        } else if line.hasPrefix("+++ ") {
            file.newPath = stripPrefix(unquote(String(line.dropFirst(4))), "b/")
        } else if line.hasPrefix("rename from ") {
            file.isRename = true
            file.oldPath = unquote(String(line.dropFirst("rename from ".count)))
        } else if line.hasPrefix("rename to ") {
            file.isRename = true
            file.newPath = unquote(String(line.dropFirst("rename to ".count)))
        } else if line.hasPrefix("copy from ") {
            file.oldPath = unquote(String(line.dropFirst("copy from ".count)))
        } else if line.hasPrefix("copy to ") {
            file.newPath = unquote(String(line.dropFirst("copy to ".count)))
        } else if line.hasPrefix("new file mode ") {
            file.isNewFile = true
            file.newMode = String(line.dropFirst("new file mode ".count))
        } else if line.hasPrefix("deleted file mode ") {
            file.isDeletedFile = true
            file.oldMode = String(line.dropFirst("deleted file mode ".count))
        } else if line.hasPrefix("old mode ") {
            file.oldMode = String(line.dropFirst("old mode ".count))
        } else if line.hasPrefix("new mode ") {
            file.newMode = String(line.dropFirst("new mode ".count))
        } else if line.hasPrefix("similarity index ") {
            file.similarity = Int(line.dropFirst("similarity index ".count).dropLast())
        } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
            file.isBinary = true
        }
    }

    private static func stripPrefix(_ value: String?, _ prefix: String) -> String? {
        guard let value else { return nil }
        if value == "/dev/null" { return nil }
        // Timestamps are not emitted by git, but tolerate "path\tdate".
        let trimmed = value.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? value
        return trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
    }

    /// Splits `a/old b/new`. Works for paths with spaces when old and new match,
    /// which is every case except renames (and renames carry explicit header lines).
    static func pathsFromGitHeader(_ header: String) -> (String, String)? {
        if header.hasPrefix("\"") {
            // Quoted form: "a/x y" "b/x y"
            let parts = splitQuotedPair(header)
            if let parts { return (stripPrefix(parts.0, "a/") ?? parts.0, stripPrefix(parts.1, "b/") ?? parts.1) }
        }
        guard header.hasPrefix("a/") else { return nil }
        let body = header.dropFirst(2)
        // Prefer the split where both halves are identical.
        var searchRange = body.startIndex..<body.endIndex
        var fallback: (String, String)? = nil
        var matches = 0
        while let range = body.range(of: " b/", range: searchRange) {
            let old = String(body[body.startIndex..<range.lowerBound])
            let new = String(body[range.upperBound...])
            matches += 1
            if old == new { return (old, new) }
            fallback = (old, new)
            searchRange = range.upperBound..<body.endIndex
        }
        return matches == 1 ? fallback : nil
    }

    private static func splitQuotedPair(_ text: String) -> (String, String)? {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in text {
            if escaped {
                current.append("\\")
                current.append(character)
                escaped = false
                continue
            }
            if inQuotes && character == "\\" { escaped = true; continue }
            if character == "\"" {
                if inQuotes {
                    parts.append(unquote("\"" + current + "\"") ?? current)
                    current = ""
                }
                inQuotes.toggle()
                continue
            }
            if inQuotes { current.append(character) }
        }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        // @@ -oldStart[,oldCount] +newStart[,newCount] @@ ...
        guard line.hasPrefix("@@ ") else { return nil }
        let afterPrefix = line.dropFirst(3)
        guard let closing = afterPrefix.range(of: " @@") else { return nil }
        let ranges = afterPrefix[..<closing.lowerBound].split(separator: " ")
        guard ranges.count == 2, ranges[0].hasPrefix("-"), ranges[1].hasPrefix("+") else { return nil }
        func parse(_ piece: Substring) -> (Int, Int)? {
            let numbers = piece.dropFirst().split(separator: ",")
            guard let start = Int(numbers[0]) else { return nil }
            let count = numbers.count > 1 ? Int(numbers[1]) ?? 1 : 1
            return (start, count)
        }
        guard let old = parse(ranges[0]), let new = parse(ranges[1]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }

    // MARK: C-style quoting

    /// Undoes git's C-style path quoting (`"a\303\251.txt"`). Returns the input when not quoted.
    public static func unquote(_ value: String) -> String? {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return value }
        var bytes: [UInt8] = []
        let inner = Array(value.utf8.dropFirst().dropLast())
        var index = 0
        while index < inner.count {
            let byte = inner[index]
            if byte != UInt8(ascii: "\\") {
                bytes.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < inner.count else { break }
            let escape = inner[index]
            switch escape {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "a"): bytes.append(0x07)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "v"): bytes.append(0x0B)
            case UInt8(ascii: "\\"): bytes.append(UInt8(ascii: "\\"))
            case UInt8(ascii: "\""): bytes.append(UInt8(ascii: "\""))
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value: UInt32 = 0
                var digits = 0
                while index < inner.count, digits < 3, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(inner[index]) {
                    value = value * 8 + UInt32(inner[index] - UInt8(ascii: "0"))
                    index += 1
                    digits += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
                continue
            default:
                bytes.append(escape)
            }
            index += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
