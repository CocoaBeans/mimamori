import Foundation

/// Whether the agents in a worktree let Mimamori write to it. Mid-turn, an agent goes on editing
/// files as it last read them, so a write then is refused; between turns it only needs telling.
/// `WorktreeInspector` asks this before every discard and restore, whatever the view showed.
public enum WriteGate: Sendable, Hashable {
    case clear
    /// Allowed, with a word of warning.
    case caution(String)
    /// Not while it lasts.
    case refused(String)

    /// An agent in the worktree, as much of it as the gate needs.
    public struct Agent: Sendable, Hashable {
        public enum Source: Sendable, Hashable {
            /// Its hooks report each turn, so what it is doing is known.
            case hooks
            /// Seen only as a running process, so whether it is mid-turn is not.
            case process
        }

        /// As people know it, such as "Claude Code".
        public var name: String
        public var source: Source
        /// What its hooks last reported. A process's is not known and not read.
        public var activity: AgentActivity

        public init(name: String, source: Source, activity: AgentActivity = .idle) {
            self.name = name
            self.source = source
            self.activity = activity
        }
    }

    /// The gate for `agents`, in any order: one mid-turn refuses, whatever the others are doing.
    public init(_ agents: [Agent]) {
        for agent in agents where agent.source == .hooks {
            switch agent.activity {
            case .working:
                self = .refused("\(agent.name) is in the middle of a turn in this worktree. Mimamori won't write to it until the turn ends.")
                return
            case .needsPermission, .askedQuestion:
                self = .refused("\(agent.name) is waiting on you in the middle of a turn, and goes on editing once you answer. Mimamori won't write to this worktree until the turn ends.")
                return
            case .ready, .idle:
                continue
            }
        }
        // An ended session's process may still run, and a process says nothing about turns.
        if let running = agents.first(where: { $0.source == .process || $0.activity == .idle }) {
            self = .caution("\(running.name) is running in this worktree, and Mimamori can't tell whether it's in the middle of a turn. Make sure it isn't editing this file.")
        } else if let ready = agents.first(where: { $0.activity == .ready }) {
            self = .caution("\(ready.name) is between turns here. It won't know about this unless you tell it.")
        } else {
            self = .clear
        }
    }

    public var refusal: String? {
        if case .refused(let reason) = self { return reason }
        return nil
    }
}
