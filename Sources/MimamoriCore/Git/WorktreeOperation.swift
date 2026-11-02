import Foundation

/// A git operation a worktree is in the middle of: a merge, rebase, cherry-pick or revert that
/// stopped (usually on a conflict), or a bisect. An agent left mid-rebase is worth knowing about
/// before anything else in the worktree.
public struct WorktreeOperation: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case merge, rebase, applyingPatches, cherryPick, revert, bisect
    }

    public var kind: Kind
    /// What is coming in: the branch merged, or the commit picked, reverted, or (in a rebase)
    /// being replayed when it stopped.
    public var incoming: String?
    /// A rebase's branch, and what it is being replayed onto.
    public var branch: String?
    public var onto: String?
    /// Where a rebase or a run of patches has got to.
    public var step: Int?
    public var total: Int?
    /// Files git left unmerged.
    public var conflicted: Int

    public init(kind: Kind, incoming: String? = nil, branch: String? = nil, onto: String? = nil,
                step: Int? = nil, total: Int? = nil, conflicted: Int = 0) {
        self.kind = kind
        self.incoming = incoming
        self.branch = branch
        self.onto = onto
        self.step = step
        self.total = total
        self.conflicted = conflicted
    }

    /// "Merging feature/euros into main", "Rebasing feature/login onto main".
    public func title(currentBranch: String?) -> String {
        switch kind {
        case .merge:
            let into = currentBranch.map { " into \($0)" } ?? ""
            return incoming.map { "Merging \($0)\(into)" } ?? "Merging\(into)"
        case .rebase:
            let what = branch ?? currentBranch
            let onto = onto.map { " onto \($0)" } ?? ""
            return what.map { "Rebasing \($0)\(onto)" } ?? "Rebasing\(onto)"
        case .applyingPatches: return "Applying patches"
        case .cherryPick: return incoming.map { "Cherry-picking \($0)" } ?? "Cherry-picking"
        case .revert: return incoming.map { "Reverting \($0)" } ?? "Reverting"
        case .bisect: return "Bisecting"
        }
    }

    /// "Merging", "Rebasing": the operation in a word or two.
    public var verb: String {
        switch kind {
        case .merge: "Merging"
        case .rebase: "Rebasing"
        case .applyingPatches: "Applying patches"
        case .cherryPick: "Cherry-picking"
        case .revert: "Reverting"
        case .bisect: "Bisecting"
        }
    }

    /// "3 of 7", for a rebase or a run of patches.
    public var progress: String? {
        guard let step, let total, total > 1 else { return nil }
        return "\(step) of \(total)"
    }

    /// What it is waiting for: conflicts to resolve, or a commit or continue once they are.
    public var detail: String? {
        if conflicted > 0 { return conflicted == 1 ? "1 file conflicted" : "\(conflicted) files conflicted" }
        switch kind {
        case .merge, .cherryPick, .revert: return "Conflicts resolved: waiting to be committed"
        case .rebase, .applyingPatches: return "Stopped: waiting to continue"
        case .bisect: return nil
        }
    }

    /// The SF Symbol for the kind of operation.
    public var symbolName: String {
        switch kind {
        case .merge: "arrow.triangle.merge"
        case .rebase: "arrow.triangle.branch"
        case .applyingPatches: "doc.on.doc"
        case .cherryPick: "arrow.turn.up.right"
        case .revert: "arrow.uturn.backward"
        case .bisect: "scope"
        }
    }
}

/// Reads an operation in progress from the files git leaves in a worktree's git directory. Names
/// that need git to look up (the commit a rebase replays onto, a commit's subject) come back as
/// object ids, for `WorktreeInspector` to resolve.
public enum WorktreeOperationReader {
    public struct Found: Sendable, Hashable {
        public var operation: WorktreeOperation
        /// Object ids to replace with names: what a rebase replays onto, and the commit coming in.
        public var ontoOID: String?
        public var incomingOID: String?
    }

    public static func read(gitDir: URL) -> Found? {
        func text(_ name: String) -> String? {
            (try? String(contentsOf: gitDir.appendingPathComponent(name), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func number(_ name: String) -> Int? { text(name).flatMap { Int($0) } }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: gitDir.appendingPathComponent(name).path) }

        // A rebase that stopped (its picks are cherry-picks, so it comes first).
        if exists("rebase-merge") {
            let done = text("rebase-merge/done")?.split(separator: "\n").last.map(String.init)
            let stopped = text("rebase-merge/stopped-sha") ?? done.flatMap(pickedOID)
            return Found(operation: WorktreeOperation(kind: .rebase, branch: text("rebase-merge/head-name").flatMap(branchName),
                                                      step: number("rebase-merge/msgnum"), total: number("rebase-merge/end")),
                         ontoOID: text("rebase-merge/onto"), incomingOID: stopped)
        }
        if exists("rebase-apply") {
            let patches = exists("rebase-apply/applying")
            return Found(operation: WorktreeOperation(kind: patches ? .applyingPatches : .rebase,
                                                      branch: text("rebase-apply/head-name").flatMap(branchName),
                                                      step: number("rebase-apply/next"), total: number("rebase-apply/last")),
                         ontoOID: patches ? nil : text("rebase-apply/onto"), incomingOID: nil)
        }
        if let merging = text("MERGE_HEAD")?.split(separator: "\n").first.map(String.init) {
            let name = text("MERGE_MSG").flatMap(mergedName)
            return Found(operation: WorktreeOperation(kind: .merge, incoming: name), ontoOID: nil,
                         incomingOID: name == nil ? merging : nil)
        }
        if let picked = text("CHERRY_PICK_HEAD") {
            return Found(operation: WorktreeOperation(kind: .cherryPick), ontoOID: nil, incomingOID: picked)
        }
        if let reverted = text("REVERT_HEAD") {
            return Found(operation: WorktreeOperation(kind: .revert), ontoOID: nil, incomingOID: reverted)
        }
        if exists("BISECT_LOG") {
            return Found(operation: WorktreeOperation(kind: .bisect), ontoOID: nil, incomingOID: nil)
        }
        return nil
    }

    /// "refs/heads/feature/login" → "feature/login"; a detached rebase has no branch.
    static func branchName(_ headName: String) -> String? {
        guard headName.hasPrefix("refs/") else { return nil }
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where headName.hasPrefix(prefix) {
            return String(headName.dropFirst(prefix.count))
        }
        return headName
    }

    /// The name in MERGE_MSG's first line: "Merge branch 'feature/euros'", "Merge branch 'a' into
    /// b", "Merge remote-tracking branch 'origin/x'", "Merge tag 'v2.0'", "Merge commit '1a2b3c'".
    static func mergedName(_ message: String) -> String? {
        guard let first = message.split(separator: "\n", maxSplits: 1).first, first.hasPrefix("Merge "),
              let open = first.firstIndex(of: "'"),
              let close = first[first.index(after: open)...].firstIndex(of: "'") else { return nil }
        let name = String(first[first.index(after: open)..<close])
        return name.isEmpty ? nil : name
    }

    /// The commit in a rebase todo line: "pick 1a2b3c4 Subject" → "1a2b3c4".
    static func pickedOID(_ line: String) -> String? {
        let words = line.split(separator: " ", maxSplits: 2)
        guard words.count >= 2, ["pick", "p", "edit", "e", "reword", "r", "squash", "s", "fixup", "f"].contains(String(words[0])) else { return nil }
        return String(words[1])
    }
}
