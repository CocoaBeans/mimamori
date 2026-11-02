import Foundation
import MimamoriCore

extension AppModel {
    /// What Copy Diagnostics puts on the clipboard for a bug report: see `HookDiagnostics`.
    func diagnostics() -> HookDiagnostics {
        let hub = agentHub
        var report = HookDiagnostics()
        report.app = "Mimamori \(BuildInfo.summary)"
        #if arch(arm64)
        let chip = "Apple silicon"
        #else
        let chip = "Intel"
        #endif
        // "Version 26.4.1 (Build 25E253)" from the system; "macOS 26.4.1 (Build 25E253)" here.
        let version = ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: "")
        report.system = "macOS \(version), \(chip)"
        report.socketPath = hub.socketPath
        report.listening = hub.isListening
        report.socketError = hub.socketError
        report.eventsReceived = hub.eventsReceived
        report.eventsUnplaced = hub.eventsUnmatched
        report.lastEventAt = hub.lastEventAt

        let claudeFile = HookInstaller.settingsURL.path
        let fromEnvironment = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] != nil ? ", found through CLAUDE_CONFIG_DIR" : ""
        var hooks = [("Claude Code", (HookInstaller.isInstalled() ? "installed in " : "not installed in ") + claudeFile + fromEnvironment)]
        switch HermesHookInstaller.state() {
        case .notPresent: hooks.append(("Hermes", "Hermes not found"))
        case .notInstalled: hooks.append(("Hermes", "not installed"))
        case .manualMergeNeeded: hooks.append(("Hermes", "not installed; config.yaml has a hooks: block of its own"))
        case .installed:
            let waiting = HermesHookInstaller.unapprovedEvents().count
            hooks.append(("Hermes", waiting == 0 ? "installed and approved" : "installed, \(waiting) waiting for approval in Hermes"))
        }
        report.hooks = hooks
        report.detection = settings.agentScanEnabled ? "on, every \(Int(settings.agentScanIntervalSeconds)) s" : "off"
        report.watched = "\(repositories.count) \(repositories.count == 1 ? "repository" : "repositories"), "
            + "\(sessions.count) \(sessions.count == 1 ? "worktree" : "worktrees")"
        report.contacts = hub.contacts.values.sorted { $0.lastEventAt > $1.lastEventAt }.map {
            .init(agent: $0.agent.displayName, events: $0.events, lastEventAt: $0.lastEventAt,
                  lastEvent: $0.lastEvent, lastWorktree: $0.lastWorktree)
        }
        report.recent = hub.hookLog
        return report
    }

    func copyDiagnostics() {
        Workspace.copy(diagnostics().text())
        Log.hooks.notice("Copied diagnostics to the clipboard")
    }
}
