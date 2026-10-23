import Foundation

/// One tracked entry from `git status --porcelain=v2`.
public struct StatusEntry: Sendable, Hashable {
    public var path: String
    public var originalPath: String?
    /// 'X' column: state of the index relative to HEAD. '.' means unchanged.
    public var indexStatus: Character
    /// 'Y' column: state of the working tree relative to the index.
    public var worktreeStatus: Character
    public var isUnmerged: Bool

    public init(path: String, originalPath: String? = nil, indexStatus: Character, worktreeStatus: Character, isUnmerged: Bool = false) {
        self.path = path
        self.originalPath = originalPath
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
        self.isUnmerged = isUnmerged
    }

    public var isStaged: Bool { !isUnmerged && indexStatus != "." }
    public var hasWorktreeChanges: Bool { worktreeStatus != "." }
}

public struct PorcelainStatus: Sendable, Hashable {
    public var headOID: String?
    public var branch: String?
    public var upstream: String?
    public var ahead: Int?
    public var behind: Int?
    public var entries: [StatusEntry] = []
    /// Untracked files, or directories with a trailing slash when collapsed.
    public var untracked: [String] = []
    public var ignored: [String] = []

    public init() {}

    public var branchInfo: BranchInfo {
        BranchInfo(headOID: headOID, branch: branch, upstream: upstream, ahead: ahead, behind: behind)
    }

    public func isUntracked(_ path: String) -> Bool {
        for item in untracked {
            if item.hasSuffix("/") {
                if path.hasPrefix(item) { return true }
            } else if item == path {
                return true
            }
        }
        return false
    }

    public func entry(for path: String) -> StatusEntry? {
        entries.first { $0.path == path }
    }
}

public enum PorcelainStatusParser {
    public static func parse(_ data: Data) -> PorcelainStatus {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var status = PorcelainStatus()
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard let first = token.first else { continue }
            switch first {
            case "#":
                parseHeader(token, into: &status)
            case "1":
                // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                let parts = token.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9, parts[1].count == 2 else { continue }
                let xy = Array(parts[1])
                status.entries.append(StatusEntry(path: String(parts[8]), indexStatus: xy[0], worktreeStatus: xy[1]))
            case "2":
                // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path> NUL <origPath>
                let parts = token.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count == 10, parts[1].count == 2 else { continue }
                let xy = Array(parts[1])
                var original: String? = nil
                if index < tokens.count {
                    original = tokens[index]
                    index += 1
                }
                status.entries.append(StatusEntry(path: String(parts[9]), originalPath: original, indexStatus: xy[0], worktreeStatus: xy[1]))
            case "u":
                // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
                let parts = token.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11, parts[1].count == 2 else { continue }
                let xy = Array(parts[1])
                status.entries.append(StatusEntry(path: String(parts[10]), indexStatus: xy[0], worktreeStatus: xy[1], isUnmerged: true))
            case "?":
                status.untracked.append(String(token.dropFirst(2)))
            case "!":
                status.ignored.append(String(token.dropFirst(2)))
            default:
                continue
            }
        }
        return status
    }

    private static func parseHeader(_ line: String, into status: inout PorcelainStatus) {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return }
        let value = String(parts[2])
        switch parts[1] {
        case "branch.oid":
            status.headOID = value == "(initial)" ? nil : value
        case "branch.head":
            status.branch = value == "(detached)" ? nil : value
        case "branch.upstream":
            status.upstream = value
        case "branch.ab":
            // "+1 -2"
            for piece in value.split(separator: " ") {
                if piece.hasPrefix("+") { status.ahead = Int(piece.dropFirst()) }
                if piece.hasPrefix("-") { status.behind = Int(piece.dropFirst()) }
            }
        default:
            break
        }
    }
}

public enum WorktreeListParser {
    /// Parses `git worktree list --porcelain`.
    public static func parse(_ text: String) -> [WorktreeInfo] {
        var result: [WorktreeInfo] = []
        var current: WorktreeInfo? = nil
        func flush() {
            if let info = current { result.append(info) }
            current = nil
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("worktree ") {
                flush()
                current = WorktreeInfo(path: String(line.dropFirst("worktree ".count)), isMain: result.isEmpty)
            } else if line.hasPrefix("HEAD ") {
                current?.headOID = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                current?.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line == "detached" {
                current?.isDetached = true
            } else if line == "bare" {
                current?.isBare = true
            } else if line.hasPrefix("locked") {
                current?.isLocked = true
            } else if line.hasPrefix("prunable") {
                current?.isPrunable = true
            }
        }
        flush()
        return result
    }
}
