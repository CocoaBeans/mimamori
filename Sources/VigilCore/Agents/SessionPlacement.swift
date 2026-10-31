import Foundation

/// Decides which worktree an agent session is working in when its events do not say plainly.
///
/// Claude Code reports the session's directory as `cwd`, which settles it. Gateway agents such
/// as Hermes report their own process directory instead, so the paths a tool touches have to
/// stand in. Those differ in weight: changing a file or running a command somewhere is firm
/// evidence the session works there, while reading a file elsewhere is not. A read only places
/// a session that has nothing firmer yet. The directory the agent records for the session (see
/// `HermesSessions`) places it before any tool runs, and gives way to a change made elsewhere.
public struct SessionPlacement: Sendable {
    public struct Decision: Equatable, Sendable {
        public var worktree: String?
        /// The worktree the session was placed in before this event, when it has moved.
        public var movedFrom: String?
    }

    private struct Entry: Sendable {
        var worktree: String
        var firm: Bool
    }

    private var bySession: [String: Entry] = [:]

    public init() {}

    /// - Parameters:
    ///   - cwdMatch: the worktree containing the event's working directory.
    ///   - pathMatch: the worktree containing a path the tool touches or mentions.
    ///   - changesFiles: whether the tool changes files or runs commands.
    ///   - homeMatch: the worktree containing the directory the agent records for the session;
    ///     looked up only when nothing firmer places it.
    public mutating func place(session: String?, cwdMatch: String?, pathMatch: String?, changesFiles: Bool,
                               homeMatch: @autoclosure () -> String? = nil) -> Decision {
        let previous = session.flatMap { bySession[$0] }
        let chosen: Entry?
        if let firm = cwdMatch ?? (changesFiles ? pathMatch : nil) {
            chosen = Entry(worktree: firm, firm: true)
        } else if let previous, previous.firm {
            chosen = previous
        } else if session != nil, let home = homeMatch() {
            chosen = Entry(worktree: home, firm: true)
        } else if let pathMatch {
            chosen = Entry(worktree: pathMatch, firm: false)
        } else {
            chosen = previous
        }
        guard let chosen else { return Decision(worktree: nil, movedFrom: nil) }
        if let session { bySession[session] = chosen }
        let moved = previous.map(\.worktree).flatMap { $0 == chosen.worktree ? nil : $0 }
        return Decision(worktree: chosen.worktree, movedFrom: moved)
    }
}
