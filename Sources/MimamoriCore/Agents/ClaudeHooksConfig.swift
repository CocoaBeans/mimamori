import Foundation

/// Builds and edits the `hooks` section of a Claude Code settings file so that
/// every relevant event is forwarded to Mimamori's socket. Pure functions on JSON
/// objects; the app owns file reading, backups and writing.
public enum ClaudeHooksConfig {
    /// Events Mimamori wants, with the matcher to use (nil means the event takes none).
    /// A tool call ends in PostToolUse, PostToolUseFailure or (when denied) only PostToolBatch;
    /// a turn ends in Stop or StopFailure. Missing one leaves a status stuck.
    public static let events: [(name: String, matcher: String?)] = [
        ("SessionStart", nil), ("UserPromptSubmit", nil),
        ("PreToolUse", "*"), ("PostToolUse", "*"), ("PostToolUseFailure", "*"), ("PostToolBatch", nil),
        ("PermissionRequest", "*"), ("PermissionDenied", "*"),
        ("Notification", nil), ("Stop", nil), ("StopFailure", nil), ("SubagentStop", nil), ("SessionEnd", nil),
    ]

    /// Substring that identifies Mimamori's own hook commands.
    public static let marker = "mimamori.sock"

    /// The shell command a hook runs: forwards its stdin JSON to the socket and never fails.
    public static func command(socketPath: String) -> String {
        // $HOME keeps the settings file portable between machines and users.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let portable = socketPath.hasPrefix(home + "/") ? "$HOME" + socketPath.dropFirst(home.count) : socketPath
        return "curl -s -m 1 -H 'Expect:' -H 'Content-Type: application/json' --unix-socket \"\(portable)\" --data-binary @- http://mimamori/event >/dev/null 2>&1 || true"
    }

    /// The command for PermissionRequest: like `command`, but it waits for Mimamori's answer and
    /// prints it, which Claude Code takes as the decision. Claude Code shows its own prompt at the
    /// same time and takes whichever answer comes first; with no answer, or Mimamori not running,
    /// it prints nothing and the prompt decides.
    public static func permissionCommand(socketPath: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let portable = socketPath.hasPrefix(home + "/") ? "$HOME" + socketPath.dropFirst(home.count) : socketPath
        return "curl -s -m 595 -H 'Expect:' -H 'Content-Type: application/json' --unix-socket \"\(portable)\" --data-binary @- http://mimamori/permission 2>/dev/null || true"
    }

    /// The address only the waiting PermissionRequest command posts to.
    static let permissionAddress = "mimamori/permission"
    /// Seconds Claude Code gives the waiting command: past curl's own limit.
    static let permissionTimeout = 600

    /// Returns a copy of `settings` with Mimamori's hooks present for every event, leaving
    /// other hooks untouched. Idempotent. With `permissionCommand`, PermissionRequest runs it, so
    /// you can answer permission requests in Mimamori.
    public static func install(into settings: [String: Any], command: String, permissionCommand: String? = nil) -> [String: Any] {
        var result = uninstall(from: settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = hooks[event.name] as? [[String: Any]] ?? []
            let waits = event.name == "PermissionRequest" && permissionCommand != nil
            var entry: [String: Any] = ["hooks": [["type": "command", "command": waits ? permissionCommand! : command,
                                                   "timeout": waits ? permissionTimeout : 5]]]
            if let matcher = event.matcher { entry["matcher"] = matcher }
            entries.append(entry)
            hooks[event.name] = entries
        }
        result["hooks"] = hooks
        return result
    }

    /// True for a hook command this app installed, under its current name or its former one.
    static func isOurs(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.contains(marker) || command.contains(FormerName.claudeHookMarker)
    }

    /// True when the settings still have hooks the app installed under its former name.
    public static func hasFormerHooks(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(FormerName.claudeHookMarker) ?? false }
            }
        }
    }

    /// Returns a copy of `settings` without any Mimamori hook commands, including those it
    /// installed under its former name.
    public static func uninstall(from settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard var hooks = result["hooks"] as? [String: Any] else { return result }
        for (eventName, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries = entries.compactMap { entry in
                var entry = entry
                let commands = (entry["hooks"] as? [[String: Any]] ?? []).filter { hook in
                    !isOurs(hook["command"] as? String)
                }
                if commands.isEmpty { return nil }
                entry["hooks"] = commands
                return entry
            }
            if entries.isEmpty { hooks.removeValue(forKey: eventName) } else { hooks[eventName] = entries }
        }
        if hooks.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = hooks }
        return result
    }

    /// True when an older Mimamori installed `command` for some events but not for every event
    /// Mimamori now listens to, or, given `permissionCommand`, installed them all before
    /// PermissionRequest waited for an answer. Hooks pointing at another socket are left alone.
    public static func isOutdated(in settings: [String: Any], command: String, permissionCommand: String? = nil) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        let ours = hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
            }
        }
        guard ours else { return false }
        if !isInstalled(in: settings) { return true }
        guard permissionCommand != nil else { return false }
        return !answersPermissions(in: settings)
    }

    /// True when PermissionRequest runs the command that waits for Mimamori's answer.
    public static func answersPermissions(in settings: [String: Any]) -> Bool {
        let entries = (settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? []
        return entries.contains { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains {
                guard let command = $0["command"] as? String else { return false }
                return command.contains(marker) && command.contains(permissionAddress)
            }
        }
    }

    /// True when every event has a Mimamori hook.
    public static func isInstalled(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            let entries = hooks[event.name] as? [[String: Any]] ?? []
            return entries.contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) ?? false }
            }
        }
    }
}
