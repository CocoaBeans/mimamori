import Foundation

/// One record from `git diff --raw -z`.
public struct RawDiffEntry: Sendable, Hashable {
    public var oldMode: String
    public var newMode: String
    public var oldOID: String
    public var newOID: String
    public var status: Character
    public var score: Int?
    public var path: String
    public var oldPath: String?

    public init(oldMode: String, newMode: String, oldOID: String, newOID: String, status: Character,
                score: Int? = nil, path: String, oldPath: String? = nil) {
        self.oldMode = oldMode
        self.newMode = newMode
        self.oldOID = oldOID
        self.newOID = newOID
        self.status = status
        self.score = score
        self.path = path
        self.oldPath = oldPath
    }

    public var isNullOld: Bool { oldOID.allSatisfy { $0 == "0" } }
    public var isNullNew: Bool { newOID.allSatisfy { $0 == "0" } }
}

public enum RawDiffParser {
    public static func parse(_ data: Data) -> [RawDiffEntry] {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var entries: [RawDiffEntry] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard token.hasPrefix(":") else { continue }
            // :<oldmode> <newmode> <oldoid> <newoid> <status>[score]
            let fields = token.dropFirst().split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count >= 5, let statusChar = fields[4].first else { continue }
            let score = Int(fields[4].dropFirst())
            var path = ""
            var oldPath: String? = nil
            if statusChar == "R" || statusChar == "C" {
                guard index + 1 < tokens.count else { break }
                oldPath = tokens[index]
                path = tokens[index + 1]
                index += 2
            } else {
                guard index < tokens.count else { break }
                path = tokens[index]
                index += 1
            }
            entries.append(RawDiffEntry(
                oldMode: String(fields[0]), newMode: String(fields[1]),
                oldOID: String(fields[2]), newOID: String(fields[3]),
                status: statusChar, score: score, path: path, oldPath: oldPath))
        }
        return entries
    }
}

/// One record from `git diff --numstat -z`.
public struct NumstatEntry: Sendable, Hashable {
    /// nil for binary files.
    public var additions: Int?
    public var deletions: Int?
    public var path: String
    public var oldPath: String?

    public init(additions: Int?, deletions: Int?, path: String, oldPath: String? = nil) {
        self.additions = additions
        self.deletions = deletions
        self.path = path
        self.oldPath = oldPath
    }

    public var isBinary: Bool { additions == nil && deletions == nil }
}

public enum NumstatParser {
    public static func parse(_ data: Data) -> [NumstatEntry] {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var entries: [NumstatEntry] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard !token.isEmpty else { continue }
            let parts = token.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let additions = parts[0] == "-" ? nil : Int(parts[0])
            let deletions = parts[1] == "-" ? nil : Int(parts[1])
            let inlinePath = parts.count == 3 ? String(parts[2]) : ""
            if inlinePath.isEmpty {
                // Rename: path field is empty and old/new paths follow as separate tokens.
                guard index + 1 < tokens.count else { break }
                let oldPath = tokens[index]
                let newPath = tokens[index + 1]
                index += 2
                entries.append(NumstatEntry(additions: additions, deletions: deletions, path: newPath, oldPath: oldPath))
            } else {
                entries.append(NumstatEntry(additions: additions, deletions: deletions, path: inlinePath))
            }
        }
        return entries
    }
}
