import Foundation

/// One commit in a worktree's history, with how much it changed.
public struct CommitRecord: Identifiable, Hashable, Sendable {
    public var oid: String
    /// Parents, first parent first; empty for a root commit.
    public var parents: [String]
    public var subject: String
    public var author: String
    public var date: Date
    public var filesChanged: Int
    public var additions: Int
    public var deletions: Int

    public init(oid: String, parents: [String], subject: String, author: String, date: Date,
                filesChanged: Int = 0, additions: Int = 0, deletions: Int = 0) {
        self.oid = oid
        self.parents = parents
        self.subject = subject
        self.author = author
        self.date = date
        self.filesChanged = filesChanged
        self.additions = additions
        self.deletions = deletions
    }

    public var id: String { oid }
    public var shortOID: String { String(oid.prefix(7)) }
    /// A merge is shown, and measured, against its first parent.
    public var isMerge: Bool { parents.count > 1 }
}

/// A worktree's commits as the Commits list shows them.
public struct CommitHistory: Hashable, Sendable {
    /// The commit HEAD pointed at when this was read; nil before the first commit.
    public var head: String?
    /// What the branch is measured against ("main", or "origin/main" on main itself); nil without one.
    public var reference: String?
    /// Commits on HEAD that `reference` does not have, newest first.
    public var sinceBranchPoint: [CommitRecord]
    /// Older history, newest first, starting where `sinceBranchPoint` ends.
    public var earlier: [CommitRecord]
    /// Where `earlier` starts, for loading more of it.
    public var earlierFrom: String?
    /// More of `earlier` can be loaded.
    public var hasMore: Bool

    public init(head: String? = nil, reference: String? = nil, sinceBranchPoint: [CommitRecord] = [],
                earlier: [CommitRecord] = [], earlierFrom: String? = nil, hasMore: Bool = false) {
        self.head = head
        self.reference = reference
        self.sinceBranchPoint = sinceBranchPoint
        self.earlier = earlier
        self.earlierFrom = earlierFrom
        self.hasMore = hasMore
    }

    public var all: [CommitRecord] { sinceBranchPoint + earlier }

    public func commit(_ oid: String) -> CommitRecord? {
        sinceBranchPoint.first { $0.oid == oid } ?? earlier.first { $0.oid == oid }
    }
}

/// Reads `git log --format=<format> --shortstat`.
public enum CommitLogParser {
    /// Each commit starts with a record separator; its fields are split by unit separators.
    public static let format = "%x1e%H%x1f%P%x1f%an%x1f%ct%x1f%s"

    public static func parse(_ text: String) -> [CommitRecord] {
        text.split(separator: "\u{1e}").compactMap { record in
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let header = lines.first else { return nil }
            let fields = header.split(separator: "\u{1f}", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, fields[0].count >= 7 else { return nil }
            var commit = CommitRecord(
                oid: fields[0],
                parents: fields[1].split(separator: " ").map(String.init),
                subject: fields[4],
                author: fields[2],
                date: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0))
            for line in lines.dropFirst() {
                let stat = shortstat(String(line))
                commit.filesChanged += stat.files
                commit.additions += stat.additions
                commit.deletions += stat.deletions
            }
            return commit
        }
    }

    /// " 3 files changed, 148 insertions(+), 9 deletions(-)"; any part may be missing.
    static func shortstat(_ line: String) -> (files: Int, additions: Int, deletions: Int) {
        var result = (files: 0, additions: 0, deletions: 0)
        for part in line.split(separator: ",") {
            let words = part.split(separator: " ")
            guard let count = words.first.flatMap({ Int($0) }), let noun = words.dropFirst().first else { continue }
            if noun.hasPrefix("file") {
                result.files = count
            } else if noun.hasPrefix("insertion") {
                result.additions = count
            } else if noun.hasPrefix("deletion") {
                result.deletions = count
            }
        }
        return result
    }
}
