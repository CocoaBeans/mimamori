import Foundation
import SQLite3

/// A Hermes turn under way, from the lease Hermes holds on its session while the turn runs.
public struct HermesTurn: Sendable, Hashable {
    public var sessionID: String
    /// The process running the turn, from the lease's holder (`pid=<pid>:turn=…`).
    public var pid: Int32?
    /// When the turn began: Hermes takes the lease as the turn's prompt arrives.
    public var startedAt: Date
    /// When the lease lapses; Hermes keeps moving it on while the turn runs.
    public var expiresAt: Date
    /// Where the session works (its `cwd`, else its `git_repo_root`); nil when Hermes has not recorded it.
    public var directory: String?

    public init(sessionID: String, pid: Int32?, startedAt: Date, expiresAt: Date, directory: String?) {
        self.sessionID = sessionID
        self.pid = pid
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.directory = directory
    }
}

/// Hermes's record of which turns are running: the leases in `state.db`'s `session_turn_leases`,
/// read-only. A lease names a session, the process running its turn and when the turn began, and
/// nothing of what the turn says or does. So when Mimamori starts in the middle of a turn, it
/// knows the turn is under way, and since when, before any hook reports.
public enum HermesTurns {
    /// The turns running according to `database` (Hermes's `state.db`), each with its session's
    /// directory. A lease past its expiry, or whose process has gone, belongs to a turn that is
    /// not running: Hermes renews it every few minutes while the turn runs, and a process that
    /// dies leaves it to lapse. Empty when the database or the table is missing.
    /// - Parameter processStart: when the process with a pid started, nil when none runs.
    public static func running(in database: URL, now: Date = Date(),
                               processStart: (Int32) -> Date? = ProcessInspector.startDate(of:)) -> [HermesTurn] {
        guard let db = HermesSessions.openReadOnly(database) else { return [] }
        defer { sqlite3_close(db) }
        let withDirectories = """
            SELECT l.conversation_id, l.holder, l.acquired_at, l.expires_at, s.cwd, s.git_repo_root
            FROM session_turn_leases l LEFT JOIN sessions s ON s.id = l.conversation_id WHERE l.expires_at > ?
            """
        // An older Hermes, without the sessions' directories, still says which turns run.
        let leasesOnly = "SELECT conversation_id, holder, acquired_at, expires_at, NULL, NULL FROM session_turn_leases WHERE expires_at > ?"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, withDirectories, -1, &statement, nil) != SQLITE_OK,
           sqlite3_prepare_v2(db, leasesOnly, -1, &statement, nil) != SQLITE_OK {
            return []
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
        var turns: [HermesTurn] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), !id.isEmpty else { continue }
            let turn = HermesTurn(sessionID: id, pid: text(statement, 1).flatMap(pid(inHolder:)),
                                  startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                                  expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                                  directory: [text(statement, 4), text(statement, 5)].compactMap { $0 }.first { $0.hasPrefix("/") })
            // A process started after the lease was taken has only inherited the pid.
            if let pid = turn.pid {
                guard let started = processStart(pid), started <= turn.startedAt.addingTimeInterval(1) else { continue }
            }
            turns.append(turn)
        }
        return turns
    }

    /// `pid=64469:turn=…` → 64469.
    static func pid(inHolder holder: String) -> Int32? {
        holder.split(separator: ":").first { $0.hasPrefix("pid=") }.flatMap { Int32($0.dropFirst(4)) }
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
