import AppKit
import Darwin
import MimamoriCore

/// Stops agents' processes to put them to sleep, and opens a terminal to wake them.
enum AgentSleeper {
    /// How long an agent has to quit after it is asked to. Claude Code takes well under a second.
    static let stopTimeout: Duration = .seconds(5)

    /// Asks each process to quit (SIGTERM, as closing its terminal would) and waits for it to go.
    /// Returns the processes still running when time ran out. A process whose pid now belongs to
    /// something started later is left alone: the agent is already gone.
    static func stop(_ processes: [AgentProcess]) async -> [AgentProcess] {
        let ours = processes.filter(isStill)
        for process in ours { _ = kill(process.pid, SIGTERM) }
        let deadline = ContinuousClock.now + stopTimeout
        var running = ours
        while !running.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            running = running.filter(isStill)
        }
        return running
    }

    /// Whether `process` still runs, as the process the scan saw start.
    private static func isStill(_ process: AgentProcess) -> Bool {
        ProcessInspector.isRunning(process.pid, startedAt: process.startedAt)
    }

    /// Opens a terminal in the worktree that resumes the agent's session. The script goes to a
    /// folder of its own in the temporary folder and removes itself as it starts; the app that
    /// opens `.command` files runs it, Terminal unless you picked another.
    static func wake(_ sleeper: SleepingAgent) throws {
        guard let script = AgentResume.wakeScript(for: sleeper) else {
            throw WakeError("Mimamori doesn't know how to resume \(sleeper.agent.displayName).")
        }
        guard FileManager.default.fileExists(atPath: sleeper.worktree) else {
            throw WakeError("The worktree \(sleeper.worktree) is gone.")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mimamori Wake", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Wake \(sleeper.agent.displayName).command")
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        guard NSWorkspace.shared.open(file) else {
            try? FileManager.default.removeItem(at: folder)
            throw WakeError("No app opened the script that resumes \(sleeper.agent.displayName).")
        }
    }

    struct WakeError: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
