import Foundation
import SQLite3

/// Hermes's own record of where each session works. Its hooks report the gateway's directory
/// (`~/.hermes`) as `cwd`, so without this a session shows nowhere until a tool touches a path
/// in a watched worktree, which with a slow model can be minutes into the turn. Hermes keeps
/// each session's working directory in `state.db`; this reads it, read-only.
public enum HermesSessions {
    /// The directory session `id` works in, according to `database` (Hermes's `state.db`).
    /// Nil when the database, the session or the column is missing: the session's row is
    /// written at the start of its first turn, after its first events may have arrived.
    public static func directory(forSession id: String, in database: URL) -> String? {
        guard let db = openReadOnly(database) else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT cwd, git_repo_root FROM sessions WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))  // SQLITE_TRANSIENT
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        for column: Int32 in 0..<2 {
            if let text = sqlite3_column_text(statement, column) {
                let path = String(cString: text)
                if path.hasPrefix("/") { return path }
            }
        }
        return nil
    }

    /// Opens Hermes's database read-only, waiting a moment for a busy writer; nil when it is
    /// missing or will not open. The caller closes it.
    static func openReadOnly(_ database: URL) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 200)
        return db
    }
}
