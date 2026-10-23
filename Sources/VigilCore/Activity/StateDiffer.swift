import Foundation

public struct CommitSummary: Sendable, Hashable, Codable {
    public var oid: String
    public var subject: String
    public init(oid: String, subject: String) {
        self.oid = oid
        self.subject = subject
    }
}

/// Turns two consecutive worktree states into feed entries.
///
/// File events are derived from the HEAD-relative change set so the feed does
/// not depend on which baseline the user is looking at.
public enum StateDiffer {
    public static func events(
        previous: WorktreeState?,
        current: WorktreeState,
        worktreePath: String,
        commits: [CommitSummary],
        now: Date = Date()
    ) -> [ActivityEntry] {
        guard let previous else { return [] }
        var entries: [ActivityEntry] = []

        let headMoved = previous.branch.headOID != current.branch.headOID
        if previous.branch.branch != current.branch.branch {
            let title: String
            if let branch = current.branch.branch {
                title = "Switched to \(branch)"
            } else if let short = current.branch.shortHead {
                title = "Detached HEAD at \(short)"
            } else {
                title = "Branch changed"
            }
            entries.append(ActivityEntry(date: now, worktreePath: worktreePath, kind: .branchChanged, title: title,
                                         detail: previous.branch.branch.map { "was \($0)" }))
        }
        if headMoved {
            if !commits.isEmpty {
                for commit in commits.reversed() {
                    entries.append(ActivityEntry(date: now, worktreePath: worktreePath, kind: .committed,
                                                 title: commit.subject, detail: String(commit.oid.prefix(7))))
                }
            } else if previous.branch.branch == current.branch.branch {
                let from = previous.branch.shortHead ?? "none"
                let to = current.branch.shortHead ?? "none"
                entries.append(ActivityEntry(date: now, worktreePath: worktreePath, kind: .headMoved,
                                             title: "HEAD moved", detail: "\(from) to \(to)"))
            }
        }

        let before = Dictionary(previous.headChanges.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let after = Dictionary(current.headChanges.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        for change in current.headChanges {
            let old = before[change.path]
            if let old {
                guard old.newOID != change.newOID || old.kind != change.kind || old.oldOID != change.oldOID else { continue }
            }
            let kind: ActivityKind
            var title = change.path
            switch change.kind {
            case .added:
                kind = old == nil ? .created : .modified
            case .deleted:
                guard old?.kind != .deleted else { continue }
                kind = .deleted
            case .renamed, .copied:
                kind = old == nil ? .renamed : .modified
                if kind == .renamed, let from = change.oldPath { title = "\(from) renamed to \(change.path)" }
            default:
                kind = .modified
            }
            entries.append(ActivityEntry(date: now, worktreePath: worktreePath, kind: kind, path: change.path, title: title,
                                         additions: change.additions, deletions: change.deletions))
        }

        if !headMoved {
            for change in previous.headChanges where after[change.path] == nil {
                entries.append(ActivityEntry(date: now, worktreePath: worktreePath, kind: .reverted, path: change.path,
                                             title: change.path, detail: "back to HEAD"))
            }
        }

        if previous.baseline.baseline == current.baseline.baseline {
            let beforeFlags = Dictionary(previous.changes.map { ($0.path, Set($0.flags.map(\.rule))) }, uniquingKeysWith: { a, _ in a })
            for change in current.changes {
                let known = beforeFlags[change.path] ?? []
                for flag in change.flags where flag.severity >= .warning && !known.contains(flag.rule) {
                    entries.append(ActivityEntry(date: now, worktreePath: worktreePath, kind: .flagged, path: change.path,
                                                 title: "\(flag.rule.title): \(change.fileName)", detail: flag.message,
                                                 severity: flag.severity))
                }
            }
        }

        return entries
    }
}
