import Foundation

/// An agent put to sleep: its process was stopped between turns and its session kept, so it can
/// carry on where it left off. An agent's process holds hundreds of megabytes while it waits for
/// a prompt; asleep it holds nothing.
public struct SleepingAgent: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var agent: AgentKind
    public var sessionID: String
    public var worktree: String
    /// The prompt behind its last turn.
    public var task: String?
    public var sleptAt: Date

    public init(id: UUID = UUID(), agent: AgentKind, sessionID: String, worktree: String, task: String? = nil,
                sleptAt: Date = Date()) {
        self.id = id
        self.agent = agent
        self.sessionID = sessionID
        self.worktree = worktree
        self.task = task
        self.sleptAt = sleptAt
    }

    /// The command that resumes the session, run in the worktree.
    public var resumeCommand: String? { AgentResume.command(for: agent, session: sessionID) }

    /// Whether the session is running again, resumed somewhere other than Wake: a process
    /// started on it since it slept, or it reported something other than its end since.
    public func isAwake(statuses: [AgentStatus], processes: [AgentProcess]) -> Bool {
        if processes.contains(where: { $0.claudeSession?.sessionID == sessionID && $0.startedAt > sleptAt }) { return true }
        return statuses.contains { $0.sessionID == sessionID && $0.lastEventAt > sleptAt && $0.activity != .idle }
    }
}

/// How each agent Mimamori can put to sleep is started again on a session.
public enum AgentResume {
    /// The words that start `agent` again on `session`, or nil for an agent Mimamori cannot resume.
    public static func arguments(for agent: AgentKind, session: String) -> [String]? {
        switch agent.id {
        case AgentKind.claudeCode.id: ["claude", "--resume", session]
        case AgentKind.codex.id: ["codex", "resume", session]
        default: nil
        }
    }

    public static func canResume(_ agent: AgentKind) -> Bool { arguments(for: agent, session: "-") != nil }

    /// The command as you would type it into a shell.
    public static func command(for agent: AgentKind, session: String) -> String? {
        arguments(for: agent, session: session).map { $0.map(ShellWords.quote).joined(separator: " ") }
    }

    /// A script for Terminal that removes itself as it starts, resumes the session in the
    /// worktree, and leaves a shell there once the agent quits.
    public static func wakeScript(for sleeper: SleepingAgent) -> String? {
        guard let command = sleeper.resumeCommand else { return nil }
        let folder = ShellWords.quote(sleeper.worktree)
        let greeting = ShellWords.quote("Mimamori: waking \(sleeper.agent.displayName) in \(sleeper.worktree)")
        return """
        #!/bin/sh
        # Written by Mimamori to wake \(sleeper.agent.displayName). It removes itself as it starts.
        rm -f -- "$0"; rmdir -- "${0%/*}" 2>/dev/null
        cd -- \(folder) || exit 1
        printf '%s\\n' \(greeting)
        \(command)
        exec "${SHELL:-/bin/zsh}" -l

        """
    }
}

/// Quoting for words put into a shell command.
public enum ShellWords {
    private static let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@%+,")

    /// The word as it is when it needs no quotes, else in single quotes.
    public static func quote(_ word: String) -> String {
        if !word.isEmpty, word.allSatisfy({ plain.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// One agent in a worktree, as putting the worktree to sleep would find it.
public struct SleepCandidate: Sendable, Hashable {
    public var agent: AgentKind
    public var sessionID: String?
    /// What its hooks or Claude Code's record of the session last said; nil when only its process is seen.
    public var activity: AgentActivity?
    /// Its processes in the worktree, which sleep stops.
    public var processes: [AgentProcess]
    public var task: String?

    public init(agent: AgentKind, sessionID: String?, activity: AgentActivity?, processes: [AgentProcess], task: String? = nil) {
        self.agent = agent
        self.sessionID = sessionID
        self.activity = activity
        self.processes = processes
        self.task = task
    }
}

/// Whether a worktree's agents can be put to sleep, and why not.
public enum AgentSleep {
    public enum Verdict: Sendable, Hashable {
        case allowed
        case refused(String)

        public var isAllowed: Bool { self == .allowed }

        public var reason: String? {
            if case .refused(let reason) = self { reason } else { nil }
        }
    }

    /// Every agent here must be between turns, in a session Mimamori knows how to resume, with a
    /// process to stop. One that can't sleep keeps the others awake: half a worktree asleep
    /// would leave the other half working on files no one is watching for it.
    public static func check(_ candidates: [SleepCandidate]) -> Verdict {
        guard !candidates.isEmpty else { return .refused("No agent is running here.") }
        for candidate in candidates {
            let name = candidate.agent.displayName
            guard AgentResume.canResume(candidate.agent) else {
                return .refused("Mimamori can't resume \(name), so it can't put it to sleep.")
            }
            guard candidate.sessionID?.isEmpty == false else {
                return .refused("\(name) hasn't said which session it runs. Connect its hooks in Settings › Agents.")
            }
            if let activity = candidate.activity {
                if activity.isMidTurn {
                    return .refused("\(name) is in the middle of a turn. Wait until it's ready for your next prompt.")
                }
            } else if candidate.processes.contains(where: \.isBusy) {
                return .refused("\(name) seems busy. Wait until it's ready for your next prompt.")
            }
            guard !candidate.processes.isEmpty else {
                return .refused("\(name) has no process here to stop.")
            }
        }
        return .allowed
    }

    /// Whether two looks at a worktree found the same agents in the same processes, so what you
    /// agreed to put to sleep is still what is there.
    public static func same(_ a: [SleepCandidate], _ b: [SleepCandidate]) -> Bool {
        func shape(_ candidates: [SleepCandidate]) -> Set<String> {
            Set(candidates.map { candidate in
                let pids = candidate.processes.map(\.pid).sorted().map(String.init).joined(separator: ",")
                return "\(candidate.agent.id)|\(candidate.sessionID ?? "")|\(pids)"
            })
        }
        return shape(a) == shape(b)
    }
}
