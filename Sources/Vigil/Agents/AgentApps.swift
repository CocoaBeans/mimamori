import AppKit
import VigilCore

/// Finds the app an agent runs in, so "Go to agent" can bring it forward.
enum AgentApps {
    /// The app hosting one of the agent's processes (Terminal, iTerm, VS Code, the Claude app),
    /// or for an agent with no process in the worktree (a gateway) a running app named after it.
    static func app(for presence: AgentPresence) -> NSRunningApplication? {
        for pid in presence.processIDs {
            if let app = owningApp(of: pid) { return app }
        }
        return appNamed(like: presence.kind)
    }

    static func canGo(to presence: AgentPresence) -> Bool {
        !presence.processIDs.isEmpty || appNamed(like: presence.kind) != nil
    }

    /// Walks up from a process to the first ancestor that is a regular app.
    static func owningApp(of pid: Int32) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<40 {
            guard current > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            guard let parent = ProcessInspector.parentPID(of: current), parent != current else { return nil }
            current = parent
        }
        return nil
    }

    /// "Hermes" for Hermes, "Claude" for Claude Code.
    static func appNamed(like kind: AgentKind) -> NSRunningApplication? {
        let full = kind.displayName.lowercased()
        let first = full.split(separator: " ").first.map(String.init) ?? full
        return NSWorkspace.shared.runningApplications.first { app in
            guard app.activationPolicy == .regular, let name = app.localizedName?.lowercased() else { return false }
            return name == full || name == first
        }
    }
}
