import Foundation
import SQLite3
import Testing
@testable import MimamoriCore

@Suite("Hermes turn leases")
struct HermesTurnTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A database shaped like Hermes's state.db, as far as Mimamori reads it.
    private func database(_ statements: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mimamori-hermes-turns-\(UUID().uuidString).db")
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        for statement in statements {
            try #require(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK, "\(statement)")
        }
        return url
    }

    private func execute(_ statement: String, in url: URL) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK, "\(statement)")
    }

    private let schema = [
        "PRAGMA journal_mode=WAL",
        "CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, started_at REAL NOT NULL, cwd TEXT, git_repo_root TEXT)",
        "CREATE TABLE session_turn_leases (conversation_id TEXT PRIMARY KEY, holder TEXT NOT NULL, acquired_at REAL NOT NULL, expires_at REAL NOT NULL)",
    ]

    /// Every holder's process started an hour before `now`, unless named here.
    private func running(_ url: URL, at date: Date? = nil, processes: [Int32: Date?] = [:]) -> [HermesTurn] {
        HermesTurns.running(in: url, now: date ?? now) { pid in processes[pid] ?? now.addingTimeInterval(-3600) }
    }

    @Test func readsATurnUnderWay() throws {
        let start = now.timeIntervalSince1970 - 600
        let url = try database(schema + [
            "INSERT INTO sessions VALUES ('20260903_173947_d73992', 'tui', 0, '/Users/x/Projects/backend', '/Users/x/Projects/backend')",
            "INSERT INTO session_turn_leases VALUES ('20260903_173947_d73992', 'pid=64469:turn=20260903_173947_d73992:c8fe7843:platform=tui', \(start), \(start + 900))",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let turns = running(url)
        #expect(turns == [HermesTurn(sessionID: "20260903_173947_d73992", pid: 64469, startedAt: Date(timeIntervalSince1970: start),
                                     expiresAt: Date(timeIntervalSince1970: start + 900), directory: "/Users/x/Projects/backend")])
        // Read-only: the database is left as it was.
        #expect(running(url) == turns)
    }

    @Test func anExpiredOrReleasedLeaseIsNoTurn() throws {
        let start = now.timeIntervalSince1970 - 600
        let url = try database(schema + [
            "INSERT INTO sessions VALUES ('live', 'tui', 0, '/p/live', NULL)",
            "INSERT INTO sessions VALUES ('lapsed', 'tui', 0, '/p/lapsed', NULL)",
            "INSERT INTO session_turn_leases VALUES ('live', 'pid=10:turn=a', \(start), \(start + 900))",
            // Its process stopped renewing it.
            "INSERT INTO session_turn_leases VALUES ('lapsed', 'pid=11:turn=b', \(start - 900), \(start))",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(running(url).map(\.sessionID) == ["live"])
        // Later, the live one lapses too.
        #expect(running(url, at: now.addingTimeInterval(600)).isEmpty)
        // The turn ended: Hermes released the lease.
        try execute("DELETE FROM session_turn_leases WHERE conversation_id = 'live'", in: url)
        #expect(running(url).isEmpty)
    }

    @Test func aLeaseWhoseProcessIsGoneIsNoTurn() throws {
        let start = now.timeIntervalSince1970 - 600
        let url = try database(schema + [
            "INSERT INTO session_turn_leases VALUES ('crashed', 'pid=20:turn=a', \(start), \(start + 900))",
            "INSERT INTO session_turn_leases VALUES ('reused', 'pid=21:turn=b', \(start), \(start + 900))",
            "INSERT INTO session_turn_leases VALUES ('kept', 'pid=22:turn=c', \(start), \(start + 900))",
            "INSERT INTO session_turn_leases VALUES ('nameless', 'turn=d', \(start), \(start + 900))",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        // 20 runs no more; 21 is a process started after the lease was taken.
        let turns = running(url, processes: [20: nil, 21: now.addingTimeInterval(-60)])
        #expect(Set(turns.map(\.sessionID)) == ["kept", "nameless"])
        // A holder that names no process is trusted until the lease lapses.
        #expect(turns.first { $0.sessionID == "nameless" }?.pid == nil)
    }

    @Test func aSessionWithNoDirectoryStillHasItsTurn() throws {
        let start = now.timeIntervalSince1970 - 60
        let url = try database(schema + [
            "INSERT INTO sessions VALUES ('repo-only', 'cli', 0, NULL, '/Users/x/Projects/frontend')",
            "INSERT INTO sessions VALUES ('nowhere', 'telegram', 0, '', NULL)",
            "INSERT INTO session_turn_leases VALUES ('repo-only', 'pid=30:turn=a', \(start), \(start + 900))",
            "INSERT INTO session_turn_leases VALUES ('nowhere', 'pid=31:turn=b', \(start), \(start + 900))",
            // Its session's row is not written yet.
            "INSERT INTO session_turn_leases VALUES ('unwritten', 'pid=32:turn=c', \(start), \(start + 900))",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let directories = Dictionary(uniqueKeysWithValues: running(url).map { ($0.sessionID, $0.directory) })
        let expected: [String: String?] = ["repo-only": "/Users/x/Projects/frontend", "nowhere": nil, "unwritten": nil]
        #expect(directories == expected)
    }

    @Test func anUnexpectedDatabaseReadsAsNoTurns() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("mimamori-missing-\(UUID().uuidString).db")
        #expect(running(missing).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        // A Hermes without leases.
        let older = try database(["CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT)", "INSERT INTO sessions VALUES ('s', '/p')"])
        defer { try? FileManager.default.removeItem(at: older) }
        #expect(running(older).isEmpty)
        // Leases, but sessions that record no directory: the turns all the same.
        let start = now.timeIntervalSince1970 - 60
        let partial = try database([
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT)",
            "CREATE TABLE session_turn_leases (conversation_id TEXT PRIMARY KEY, holder TEXT NOT NULL, acquired_at REAL NOT NULL, expires_at REAL NOT NULL)",
            "INSERT INTO session_turn_leases VALUES ('s', 'pid=40:turn=a', \(start), \(start + 900))",
        ])
        defer { try? FileManager.default.removeItem(at: partial) }
        #expect(running(partial).map(\.sessionID) == ["s"])
        #expect(running(partial).first?.directory == nil)
    }

    @Test func readsTheProcessFromTheHolder() {
        #expect(HermesTurns.pid(inHolder: "pid=64469:turn=20260903_173947_d73992:c8fe7843:platform=tui") == 64469)
        #expect(HermesTurns.pid(inHolder: "turn=x:pid=12") == 12)
        #expect(HermesTurns.pid(inHolder: "turn=x") == nil)
        #expect(HermesTurns.pid(inHolder: "pid=abc:turn=x") == nil)
        #expect(HermesTurns.pid(inHolder: "") == nil)
    }
}

@Suite("Turns joined midway")
struct TurnStartTests {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1000 + seconds) }

    private func event(_ name: HookEvent.Name, agent: AgentKind = .claudeCode, session: String = "s1", tool: String? = nil,
                       message: String? = nil, at seconds: TimeInterval) -> HookEvent {
        HookEvent(name: name, rawName: name.rawValue, agent: agent, sessionID: session, cwd: "/repo", toolName: tool,
                  toolUseID: tool.map { "\($0)-\(Int(seconds))" }, message: message, receivedAt: date(seconds))
    }

    private func turn(_ session: String = "h1", startedAt seconds: TimeInterval) -> HermesTurn {
        HermesTurn(sessionID: session, pid: 64469, startedAt: date(seconds), expiresAt: date(seconds + 300), directory: "/repo")
    }

    @Test func aHermesTurnUnderWayShowsUntilItsHooksTakeOver() throws {
        var machine = AgentStatusMachine()
        let adopted = machine.adopt(turn(startedAt: 0))
        #expect(adopted)
        var status = try #require(machine.status)
        #expect(status.agent == .hermes)
        #expect(status.sessionID == "h1")
        #expect(status.activity == .working(tool: nil, detail: nil))
        #expect(status.since == date(0))
        #expect(status.turnStartedAt == date(0))
        #expect(status.fromSessionRecord)
        let again = machine.adopt(turn(startedAt: 0))
        #expect(!again)

        // Its prompt hook, before the next model call, is the turn going on, not a new one.
        let notes = machine.apply(event(.userPromptSubmit, agent: .hermes, session: "h1", message: "fix the build", at: 600))
        #expect(!notes.contains { $0.kind == .turnStarted })
        status = try #require(machine.status)
        #expect(!status.fromSessionRecord)
        #expect(status.turnStartedAt == date(0))
        #expect(status.task == "fix the build")
        _ = machine.apply(event(.preToolUse, agent: .hermes, session: "h1", tool: "terminal", at: 601))
        #expect(machine.status?.activity == .working(tool: "terminal", detail: nil))
        #expect(machine.status?.toolCallsThisTurn == 1)
        // The lease no longer overrides the hooks.
        let overridden = machine.adopt(turn(startedAt: 0))
        #expect(!overridden)
        // The turn's summary counts from when it really began.
        let finished = machine.apply(event(.stop, agent: .hermes, session: "h1", at: 605))
        #expect(finished.first { $0.kind == .turnFinished }?.detail == "1 tool call in 10m 5s")
    }

    @Test func aNewTurnsLeaseReplacesTheLastWhileHooksAreSilent() throws {
        var machine = AgentStatusMachine()
        _ = machine.adopt(turn(startedAt: 0))
        let next = machine.adopt(turn(startedAt: 100))
        #expect(next)
        #expect(machine.status?.turnStartedAt == date(100))
        #expect(machine.status?.since == date(100))
        // Another session's lease takes the machine over.
        let other = machine.adopt(turn("h2", startedAt: 200))
        #expect(other)
        #expect(machine.status?.sessionID == "h2")
    }

    @Test func aLeaseOverridesHooksOnlyForASessionThatEndedBeforeTheTurn() throws {
        var machine = AgentStatusMachine()
        _ = machine.apply(event(.sessionEnd, agent: .hermes, session: "h1", at: 50))
        // A lease from before the end is left over from a turn that was cut short.
        let stale = machine.adopt(turn(startedAt: 40))
        #expect(!stale)
        #expect(machine.status?.activity == .idle)
        // One taken after it: the session was resumed.
        let resumed = machine.adopt(turn(startedAt: 60))
        #expect(resumed)
        #expect(machine.status?.activity == .working(tool: nil, detail: nil))
        #expect(machine.status?.fromSessionRecord == true)
        // A session its hooks say is ready keeps that.
        var ready = AgentStatusMachine()
        _ = ready.apply(event(.stop, agent: .hermes, session: "h1", at: 50))
        let overReady = ready.adopt(turn(startedAt: 60))
        #expect(!overReady)
        #expect(ready.status?.activity == .ready)
    }

    @Test func aHermesTurnCountsAsLiveWithoutAProcessHere() throws {
        var machine = AgentStatusMachine()
        _ = machine.adopt(turn(startedAt: 0))
        let status = try #require(machine.status)
        // A gateway's process sits in ~/.hermes, not in the worktree.
        let here = WorktreeAgents(statuses: [status], processes: [], established: [], now: date(3600), parent: { _ in 1 })
        #expect(here.live.map(\.key) == ["h1"])
    }

    @Test func backdatesOnlyATurnWhoseStartWasNotHeard() throws {
        var heard = AgentStatusMachine()
        _ = heard.apply(event(.userPromptSubmit, message: "task", at: 100))
        _ = heard.apply(event(.preToolUse, tool: "Bash", at: 101))
        let moved = heard.backdateTurn(to: date(50))
        #expect(!moved)
        #expect(heard.status?.turnStartedAt == date(100))

        // Mimamori started mid-turn: the first word is a tool call.
        var joined = AgentStatusMachine()
        _ = joined.apply(event(.preToolUse, tool: "Bash", at: 100))
        #expect(joined.status?.turnStartedAt == date(100))
        #expect(joined.status?.turnStartUnheard == true)
        let back = joined.backdateTurn(to: date(40))
        #expect(back)
        #expect(joined.status?.turnStartedAt == date(40))
        #expect(joined.status?.lastTurnStartedAt == date(40))
        // Only ever earlier.
        let later = joined.backdateTurn(to: date(60))
        #expect(!later)
        #expect(joined.status?.turnStartedAt == date(40))
        let same = joined.backdateTurn(to: date(40))
        #expect(!same)
        let earlier = joined.backdateTurn(to: date(30))
        #expect(earlier)
        #expect(joined.status?.turnStartedAt == date(30))
        // The turn's earlier steps were never heard; the ones heard stay its steps.
        #expect(joined.status?.turnToolCalls.map(\.toolName) == ["Bash"])
        let finished = joined.apply(event(.stop, at: 130))
        #expect(finished.first { $0.kind == .turnFinished }?.detail == "1 tool call in 1m 40s")
        // Once it ended there is no turn to move.
        let ended = joined.backdateTurn(to: date(0))
        #expect(!ended)
        #expect(joined.status?.lastTurnStartedAt == date(30))
    }

    @Test func neverBackdatesPastThePreviousTurnsEnd() throws {
        var machine = AgentStatusMachine()
        _ = machine.apply(event(.userPromptSubmit, message: "first", at: 0))
        _ = machine.apply(event(.stop, at: 10))
        #expect(machine.status?.lastTurnEndedAt == date(10))
        // The next turn's prompt went unheard.
        _ = machine.apply(event(.preToolUse, tool: "Edit", at: 30))
        #expect(machine.status?.turnStartUnheard == true)
        // A record from before the last turn ended speaks of that turn.
        let stale = machine.backdateTurn(to: date(5))
        #expect(!stale)
        #expect(machine.status?.turnStartedAt == date(30))
        let fresh = machine.backdateTurn(to: date(20))
        #expect(fresh)
        #expect(machine.status?.turnStartedAt == date(20))
        // Its prompt heard after all, the next turn starts afresh.
        _ = machine.apply(event(.stop, at: 40))
        _ = machine.apply(event(.userPromptSubmit, message: "second", at: 50))
        #expect(machine.status?.turnStartUnheard == false)
    }

    @Test func aHermesTurnFirstHeardFromItsPromptHookMayHaveBegunEarlier() throws {
        // Hermes's prompt hook fires before every model call: the first one heard may be mid-turn.
        var unheard = AgentStatusMachine()
        let notes = unheard.apply(event(.userPromptSubmit, agent: .hermes, session: "h1", message: "task", at: 100))
        #expect(notes.contains { $0.kind == .turnStarted })
        let moved = unheard.backdateTurn(to: date(10))
        #expect(moved)
        #expect(unheard.status?.turnStartedAt == date(10))

        // After the session's start was heard, its prompt starts the turn.
        var heard = AgentStatusMachine()
        _ = heard.apply(event(.sessionStart, agent: .hermes, session: "h1", at: 0))
        _ = heard.apply(event(.userPromptSubmit, agent: .hermes, session: "h1", message: "task", at: 100))
        let kept = heard.backdateTurn(to: date(10))
        #expect(!kept)
        #expect(heard.status?.turnStartedAt == date(100))

        // Claude Code's prompt hook is the turn's start.
        var claude = AgentStatusMachine()
        _ = claude.apply(event(.userPromptSubmit, message: "task", at: 100))
        let claudeMoved = claude.backdateTurn(to: date(10))
        #expect(!claudeMoved)
    }

    @Test func aDeclinedCallEndsTheTurn() throws {
        var machine = AgentStatusMachine()
        _ = machine.apply(event(.preToolUse, tool: "Bash", at: 100))
        _ = machine.apply(event(.permissionRequest, tool: "Bash", at: 101))
        let declined = machine.noteDeclined(at: date(110))
        #expect(declined)
        #expect(machine.status?.lastTurnEndedAt == date(110))
        #expect(machine.status?.turnStartUnheard == false)
    }
}
