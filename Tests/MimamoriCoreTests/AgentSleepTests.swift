import Foundation
import Testing
@testable import MimamoriCore

@Suite("Putting agents to sleep")
struct AgentSleepTests {
    private let now = Date(timeIntervalSince1970: 100_000)

    private func process(_ pid: Int32, _ kind: AgentKind = .claudeCode, session: String? = nil, cpu: Double = 0,
                         startedMinutesAgo: Double = 60) -> AgentProcess {
        AgentProcess(pid: pid, kind: kind, executable: "/usr/local/bin/\(kind.id)", workingDirectory: "/repo",
                     startedAt: now.addingTimeInterval(-startedMinutesAgo * 60), cpuLoad: cpu,
                     claudeSession: session.map { ClaudeSessionRecord(pid: pid, sessionID: $0, status: "idle") })
    }

    private func candidate(_ agent: AgentKind = .claudeCode, session: String? = "s1", _ activity: AgentActivity? = .ready,
                           pids: [Int32] = [10], cpu: Double = 0) -> SleepCandidate {
        SleepCandidate(agent: agent, sessionID: session, activity: activity, processes: pids.map { process($0, agent, cpu: cpu) })
    }

    // MARK: Whether it may sleep

    @Test func readyAgentMaySleep() {
        #expect(AgentSleep.check([candidate()]) == .allowed)
        #expect(AgentSleep.check([candidate(.codex, session: "c1")]) == .allowed)
    }

    @Test func endedSessionWithItsProcessMaySleep() {
        #expect(AgentSleep.check([candidate(.claudeCode, .idle)]) == .allowed)
    }

    @Test func nothingToSleep() {
        #expect(AgentSleep.check([]).reason == "No agent is running here.")
    }

    @Test(arguments: [AgentActivity.working(tool: "Bash", detail: nil), .needsPermission(tool: "Bash", detail: nil),
                      .askedQuestion(detail: nil)])
    func midTurnAgentStaysAwake(_ activity: AgentActivity) {
        let verdict = AgentSleep.check([candidate(.claudeCode, activity)])
        #expect(verdict.reason?.contains("middle of a turn") == true)
    }

    @Test func busyProcessWithNoStatusStaysAwake() {
        #expect(AgentSleep.check([candidate(.claudeCode, nil, cpu: 0.5)]).reason?.contains("seems busy") == true)
        #expect(AgentSleep.check([candidate(.claudeCode, nil, cpu: 0)]) == .allowed)
    }

    @Test func agentMimamoriCannotResumeStaysAwake() {
        let verdict = AgentSleep.check([candidate(.aider, session: "a1")])
        #expect(verdict.reason == "Mimamori can't resume Aider, so it can't put it to sleep.")
    }

    @Test func agentWithNoSessionStaysAwake() {
        #expect(AgentSleep.check([candidate(session: nil)]).reason?.contains("hasn't said which session") == true)
        #expect(AgentSleep.check([candidate(session: "")]).reason?.contains("hasn't said which session") == true)
    }

    @Test func agentWithNoProcessStaysAwake() {
        #expect(AgentSleep.check([candidate(pids: [])]).reason == "Claude Code has no process here to stop.")
    }

    @Test func oneAgentThatCannotSleepKeepsTheOthersAwake() {
        let verdict = AgentSleep.check([candidate(), candidate(.codex, session: "c1", .working(tool: nil, detail: nil), pids: [11])])
        #expect(verdict.reason == "Codex is in the middle of a turn. Wait until it's ready for your next prompt.")
    }

    @Test func sameAgentsInTheSameProcesses() {
        let first = [candidate(pids: [10, 12]), candidate(.codex, session: "c1", pids: [11])]
        #expect(AgentSleep.same(first, first.reversed()))
        #expect(AgentSleep.same(first, [candidate(pids: [12, 10]), candidate(.codex, session: "c1", pids: [11])]))
        #expect(!AgentSleep.same(first, [candidate(pids: [10, 12])]))
        #expect(!AgentSleep.same(first, [candidate(session: "s2", pids: [10, 12]), candidate(.codex, session: "c1", pids: [11])]))
        #expect(!AgentSleep.same(first, [candidate(pids: [10, 13]), candidate(.codex, session: "c1", pids: [11])]))
    }

    // MARK: Resuming

    @Test func resumeCommands() {
        #expect(AgentResume.command(for: .claudeCode, session: "0b1c-2d") == "claude --resume 0b1c-2d")
        #expect(AgentResume.command(for: .codex, session: "019a-77") == "codex resume 019a-77")
        #expect(AgentResume.command(for: .gemini, session: "g1") == nil)
        #expect(AgentResume.canResume(.claudeCode))
        #expect(!AgentResume.canResume(.hermes))
    }

    @Test func oddSessionIdsAreQuoted() {
        #expect(AgentResume.command(for: .claudeCode, session: "a b") == "claude --resume 'a b'")
        #expect(AgentResume.command(for: .claudeCode, session: "x'; rm -rf ~") == "claude --resume 'x'\\''; rm -rf ~'")
    }

    @Test func shellQuoting() {
        #expect(ShellWords.quote("plain-word_1.2/x") == "plain-word_1.2/x")
        #expect(ShellWords.quote("") == "''")
        #expect(ShellWords.quote("/Users/me/My Project") == "'/Users/me/My Project'")
        #expect(ShellWords.quote("it's") == "'it'\\''s'")
        #expect(ShellWords.quote("$HOME") == "'$HOME'")
    }

    @Test func wakeScriptResumesInTheWorktreeAndLeavesAShell() throws {
        let sleeper = SleepingAgent(agent: .claudeCode, sessionID: "s1", worktree: "/Users/me/My App", sleptAt: now)
        let script = try #require(AgentResume.wakeScript(for: sleeper))
        let lines = script.split(separator: "\n").map(String.init)
        #expect(lines.first == "#!/bin/sh")
        #expect(lines.contains("cd -- '/Users/me/My App' || exit 1"))
        #expect(lines.contains("claude --resume s1"))
        #expect(lines.last == "exec \"${SHELL:-/bin/zsh}\" -l")
        // It removes itself before anything else runs.
        #expect(lines[2].hasPrefix("rm -f -- \"$0\""))
        #expect(AgentResume.wakeScript(for: SleepingAgent(agent: .aider, sessionID: "a", worktree: "/r")) == nil)
    }

    @Test func wakeScriptRunsInAShell() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wake-\(UUID().uuidString)/it's here")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let sleeper = SleepingAgent(agent: .claudeCode, sessionID: "s1", worktree: folder.path, sleptAt: now)
        var script = try #require(AgentResume.wakeScript(for: sleeper))
        // Stand-ins for the agent and the shell left behind: print where they ran.
        script = script.replacingOccurrences(of: "claude --resume s1", with: "printf 'agent in %s\\n' \"$PWD\"")
            .replacingOccurrences(of: "exec \"${SHELL:-/bin/zsh}\" -l", with: "echo shell")
        let file = folder.deletingLastPathComponent().appendingPathComponent("scripts/Wake.command")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: file, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [file.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(printed.contains("agent in \(folder.resolvingSymlinksInPath().path)") || printed.contains("agent in \(folder.path)"))
        #expect(printed.hasSuffix("shell\n"))
        // The script and its folder are gone.
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    // MARK: Waking elsewhere

    @Test func sleeperWakesWhenItsSessionReportsAgain() {
        let sleeper = SleepingAgent(agent: .claudeCode, sessionID: "s1", worktree: "/repo", sleptAt: now)
        func status(_ session: String, _ activity: AgentActivity, minutesFromSleep: Double) -> AgentStatus {
            let at = now.addingTimeInterval(minutesFromSleep * 60)
            return AgentStatus(agent: .claudeCode, activity: activity, since: at, lastEventAt: at, sessionID: session)
        }
        // What it said before it slept, and its own end as it stopped, don't wake it.
        #expect(!sleeper.isAwake(statuses: [status("s1", .ready, minutesFromSleep: -1)], processes: []))
        #expect(!sleeper.isAwake(statuses: [status("s1", .idle, minutesFromSleep: 0.1)], processes: []))
        #expect(!sleeper.isAwake(statuses: [status("s2", .ready, minutesFromSleep: 5)], processes: []))
        #expect(sleeper.isAwake(statuses: [status("s1", .ready, minutesFromSleep: 5)], processes: []))
    }

    @Test func sleeperWakesWhenAProcessStartsOnItsSession() {
        let sleeper = SleepingAgent(agent: .claudeCode, sessionID: "s1", worktree: "/repo", sleptAt: now)
        #expect(!sleeper.isAwake(statuses: [], processes: [process(10, session: "s1", startedMinutesAgo: 60)]))
        #expect(!sleeper.isAwake(statuses: [], processes: [process(10, session: "s2", startedMinutesAgo: -5)]))
        #expect(sleeper.isAwake(statuses: [], processes: [process(10, session: "s1", startedMinutesAgo: -5)]))
    }

    @Test func runningProcessIsTheOneThatStarted() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let pid = process.processIdentifier
        let started = try #require(ProcessInspector.startDate(of: pid))
        #expect(ProcessInspector.isRunning(pid, startedAt: started))
        // The same pid, started at another time, is another process.
        #expect(!ProcessInspector.isRunning(pid, startedAt: started.addingTimeInterval(-60)))
        process.terminate()
        process.waitUntilExit()
        #expect(!ProcessInspector.isRunning(pid, startedAt: started))
    }

    @Test func sleepingAgentRoundTrips() throws {
        let sleeper = SleepingAgent(agent: .codex, sessionID: "c1", worktree: "/repo", task: "Fix the build", sleptAt: now)
        let decoded = try JSONDecoder().decode(SleepingAgent.self, from: JSONEncoder().encode(sleeper))
        #expect(decoded == sleeper)
    }
}
