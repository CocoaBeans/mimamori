import Foundation

/// What a fresh worktree listing changes in the sessions watching a repository's worktrees.
public struct WorktreeReconciliation: Equatable, Sendable {
    /// Worktrees whose sessions stop: they are gone from the listing, or hidden.
    public var stop: Set<String>
    /// Listed worktrees that already have a session, which takes their new details.
    public var update: [WorktreeInfo]
    /// Listed worktrees that need a session.
    public var create: [WorktreeInfo]

    /// - Parameters:
    ///   - listed: the repository's worktrees as git just listed them.
    ///   - hidden: worktrees you hid, which have no session.
    ///   - sessions: each running session's worktree, and the repository it belongs to.
    ///   - repository: the repository that was listed.
    public init(listed: [WorktreeInfo], hidden: Set<String>, sessions: [String: UUID], repository: UUID) {
        let kept = Set(listed.map(\.path)).subtracting(hidden)
        stop = Set(sessions.filter { $0.value == repository && !kept.contains($0.key) }.keys)
        let shown = listed.filter { !hidden.contains($0.path) }
        update = shown.filter { sessions[$0.path] != nil }
        create = shown.filter { sessions[$0.path] == nil }
    }
}

/// Decides whether a worktree listing is still wanted once git returns it. Listing takes a
/// moment, and meanwhile the repository can be removed, or listed again by a newer request that
/// finishes first. Take a ticket before asking git and present it with the listing.
public struct WorktreeListings: Sendable {
    private var lastTicket = 0
    private var applied: [UUID: Int] = [:]
    private var removed: Set<UUID> = []

    public init() {}

    /// A ticket for a listing about to be asked for. Later tickets are larger.
    public mutating func begin() -> Int {
        lastTicket += 1
        return lastTicket
    }

    /// Whether to apply a listing, or git's failure to list, for `repository`. Not when the
    /// repository was removed, nor when a listing asked for later has already been applied.
    public mutating func accepts(_ ticket: Int, for repository: UUID) -> Bool {
        guard !removed.contains(repository), ticket > applied[repository, default: 0] else { return false }
        applied[repository] = ticket
        return true
    }

    /// The repository is no longer watched: listings still on their way are refused.
    public mutating func remove(_ repository: UUID) {
        removed.insert(repository)
        applied[repository] = nil
    }
}
