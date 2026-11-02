import AppKit
import MimamoriCore

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

    /// Brings the agent's app to the front, or beeps when there is none to find.
    static func bringForward(_ presence: AgentPresence) {
        guard let app = app(for: presence) else {
            NSSound.beep()
            return
        }
        app.activate()
    }

    @MainActor static func canGo(to presence: AgentPresence) -> Bool {
        !presence.processIDs.isEmpty || recentlyFound(like: presence.kind)
    }

    /// Whether an app for `kind` was running when last looked for. Lists of agents ask on every
    /// redraw, and going through every running app each time costs more than the answer's worth;
    /// a few seconds old is fresh enough for whether to show a button.
    @MainActor private static var found: [String: (at: Date, running: Bool)] = [:]

    @MainActor private static func recentlyFound(like kind: AgentKind) -> Bool {
        if let known = found[kind.id], Date().timeIntervalSince(known.at) < 5 { return known.running }
        let running = appNamed(like: kind) != nil
        found[kind.id] = (Date(), running)
        return running
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
