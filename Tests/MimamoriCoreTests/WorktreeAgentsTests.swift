import Foundation
import Testing
@testable import MimamoriCore

@Suite("Several agents in one worktree")
struct WorktreeAgentsTests {
    private let now = Date(timeIntervalSince1970: 100_000)

    private func session(_ id: String?, _ agent: AgentKind = .claudeCode, _ activity: AgentActivity = .working(tool: nil, detail: nil),
                         minutesAgo: Double = 0, edits: [(String, Double)] = [], reads: [(String, Double)] = []) -> AgentStatus {
        let at = now.addingTimeInterval(-minutesAgo * 60)
        let calls = edits.map { path, ago in
            AgentToolCall(id: UUID().uuidString, toolName: "Edit", summary: path, filePath: path, startedAt: now.addingTimeInterval(-ago * 60))
        } + reads.map { path, ago in
            AgentToolCall(id: UUID().uuidString, toolName: "Read", summary: path, filePath: path, startedAt: now.addingTimeInterval(-ago * 60))
        }
        return AgentStatus(agent: agent, activity: activity, since: at, lastEventAt: at, sessionID: id,
                           recentToolCalls: calls.sorted { $0.startedAt < $1.startedAt })
    }

    private func process(_ pid: Int32, _ kind: AgentKind = .claudeCode, session: String? = nil, startedMinutesAgo: Double = 60) -> AgentProcess {
        AgentProcess(pid: pid, kind: kind, executable: "/usr/local/bin/\(kind.id)", workingDirectory: "/repo",
                     startedAt: now.addingTimeInterval(-startedMinutesAgo * 60), cpuLoad: 0,
                     claudeSession: session.map { ClaudeSessionRecord(pid: pid, sessionID: $0, status: "busy") })
    }

    private func agents(_ statuses: [AgentStatus], _ processes: [AgentProcess] = [], established: Set<Int32>? = nil,
                        parents: [Int32: Int32] = [:]) -> WorktreeAgents {
        WorktreeAgents(statuses: statuses, processes: processes, established: established ?? Set(processes.map(\.pid)), now: now,
                       parent: { parents[$0] ?? 1 })
    }

    @Test func oneSessionIsNotShared() {
        let result = agents([session("s1")], [process(10, session: "s1")])
        #expect(result.live.map(\.key) == ["s1"])
        #expect(result.claims["s1"] == [10])
        #expect(!result.isShared)
        #expect(result.collisions.isEmpty)
    }

    @Test func twoSessionsAreSharedTheOneWaitingOnYouFirst() {
        let result = agents([session("s1", minutesAgo: 1), session("s2", .codex, .needsPermission(tool: "Bash", detail: nil), minutesAgo: 2)])
        #expect(result.isShared)
        #expect(result.agentCount == 2)
        #expect(result.live.map(\.key) == ["s2", "s1"])
    }

    @Test func sessionsWithoutAnIDAreOnePerAgent() {
        #expect(AgentStatus.key(session: "s1", agent: .codex) == "s1")
        #expect(AgentStatus.key(session: nil, agent: .codex) == "agent:codex")
        #expect(AgentStatus.key(session: "", agent: .unnamed) == "agent:agent")
    }

    @Test func endedAndSilentSessionsDoNotCount() {
        let ended = session("s1", .claudeCode, .idle)
        let silent = session("s2", .codex, .ready, minutesAgo: 11)
        let result = agents([ended, silent, session("s3", .gemini)])
        #expect(result.live.map(\.key) == ["s3"])
        #expect(!result.isShared)
        // A silent session whose process still runs is still there.
        let running = agents([silent, session("s3", .gemini)], [process(20, .codex)])
        #expect(running.live.map(\.key) == ["s3", "s2"])
        #expect(running.claims["s2"] == [20])
    }

    @Test func aReaderBesideAWriterIsSharedButNoCollision() {
        let result = agents([session("s1", edits: [("/repo/a.swift", 1)]), session("s2", .codex, reads: [("/repo/a.swift", 1)])])
        #expect(result.isShared)
        #expect(result.collisions.isEmpty)
    }

    @Test func writersOnDifferentFilesDoNotCollide() {
        let result = agents([session("s1", edits: [("/repo/a.swift", 1)]), session("s2", .codex, edits: [("/repo/b.swift", 1)])])
        #expect(result.collisions.isEmpty)
    }

    @Test func writersOnTheSameFileCollide() throws {
        let result = agents([session("s1", edits: [("/repo/a.swift", 5), ("/repo/b.swift", 2)]),
                             session("s2", .codex, edits: [("/repo/a.swift", 1), ("/repo/c.swift", 1)])])
        let collision = try #require(result.collisions.first)
        #expect(result.collisions.count == 1)
        #expect(collision.path == "/repo/a.swift")
        #expect(collision.sessions == ["s1", "s2"])
        #expect(collision.agents == [.claudeCode, .codex])
        #expect(collision.lastEditAt == now.addingTimeInterval(-60))
    }

    @Test func editsTooLongAgoDoNotCollide() {
        // One edit is older than the window.
        #expect(agents([session("s1", edits: [("/repo/a.swift", 40)]), session("s2", .codex, edits: [("/repo/a.swift", 1)])]).collisions.isEmpty)
        // Both inside it, but neither recent.
        #expect(agents([session("s1", edits: [("/repo/a.swift", 25)]), session("s2", .codex, edits: [("/repo/a.swift", 15)])]).collisions.isEmpty)
    }

    @Test func aProcessNoSessionAccountsForCountsOnceItStays() {
        let hooks = session("s1")
        let own = process(10, session: "s1")
        let other = process(20, .codex)
        // Seen by one scan only: perhaps a passing helper.
        #expect(!agents([hooks], [own, other], established: [10]).isShared)
        let settled = agents([hooks], [own, other])
        #expect(settled.unclaimed.map(\.pid) == [20])
        #expect(settled.isShared)
        // Started by the agent already here: its helper, or a `claude -p` it runs.
        #expect(!agents([hooks], [own, other], parents: [20: 15, 15: 10]).isShared)
    }

    @Test func aChangeIsCreditedToTheSessionThatMadeIt() throws {
        let at = now.addingTimeInterval(-60)
        func calling(_ id: String, _ agent: AgentKind, _ tool: String, _ path: String?) -> AgentStatus {
            AgentStatus(agent: agent, activity: .working(tool: tool, detail: nil), since: at, lastEventAt: at, sessionID: id,
                        recentToolCalls: [AgentToolCall(id: id + "-call", toolName: tool, summary: path, filePath: path, startedAt: at)])
        }
        let claude = calling("s1", .claudeCode, "Edit", "/repo/a.swift")
        let codex = calling("s2", .codex, "Bash", nil)
        // The call that names the file wins, whoever else was busy.
        let named = try #require(WorktreeAgents.attribution(among: [codex, claude], path: "/repo/a.swift", at: at))
        #expect(named.agent == "Claude Code")
        #expect(named.tool == "Edit")
        // Another file: only Claude Code's edit and Codex's command could have made it; both change files.
        let shared = try #require(WorktreeAgents.attribution(among: [claude, codex], path: "/repo/b.swift", at: at))
        #expect(shared.agent == "Claude Code or Codex")
        #expect(shared.tool == "working")
        // With one session, its call is credited as before.
        #expect(WorktreeAgents.attribution(among: [codex], path: "/repo/b.swift", at: at)?.tool == "Bash")
        #expect(WorktreeAgents.attribution(among: [], path: "/repo/b.swift", at: at) == nil)
    }

    @Test func groupsOfAgentsReadNaturally() {
        #expect(WorktreeAgents.describe([.claudeCode, .codex]) == "Claude Code and Codex")
        #expect(WorktreeAgents.describe([.claudeCode, .codex, .gemini]) == "Claude Code, Codex and Gemini CLI")
        #expect(WorktreeAgents.describe([.claudeCode, .claudeCode]) == "Two Claude Code sessions")
        #expect(WorktreeAgents.describe([.cursor]) == "Cursor Agent")
    }

    @Test func claudeCodeProcessesBelongToTheirOwnSessions() {
        let first = process(10, session: "s1")
        let second = process(11, session: "s2")
        // Only one session has reported; the other process is a second agent all the same.
        let result = agents([session("s1")], [first, second])
        #expect(result.claims["s1"] == [10])
        #expect(result.unclaimed.map(\.pid) == [11])
        #expect(result.isShared)
        // Once its status comes from Claude Code's record, it is a session of its own.
        var recorded = session("s2", .claudeCode, .ready, minutesAgo: 30)
        recorded.fromSessionRecord = true
        let both = agents([session("s1"), recorded], [first, second])
        #expect(both.live.count == 2)
        #expect(both.unclaimed.isEmpty)
        // A recorded status whose process is gone does not count.
        #expect(agents([session("s1"), recorded], [first]).live.map(\.key) == ["s1"])
    }
}
