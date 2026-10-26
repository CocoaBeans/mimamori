import Foundation

/// Builds and edits the `hooks` section of a Claude Code settings file so that
/// every relevant event is forwarded to Vigil's socket. Pure functions on JSON
/// objects; the app owns file reading, backups and writing.
public enum ClaudeHooksConfig {
    /// Events Vigil wants, with the matcher to use (nil means the event takes none).
    /// A tool call ends in PostToolUse, PostToolUseFailure or (when denied) only PostToolBatch;
    /// a turn ends in Stop or StopFailure. Missing one leaves a status stuck.
    public static let events: [(name: String, matcher: String?)] = [
        ("SessionStart", nil), ("UserPromptSubmit", nil),
        ("PreToolUse", "*"), ("PostToolUse", "*"), ("PostToolUseFailure", "*"), ("PostToolBatch", nil),
        ("PermissionRequest", "*"), ("PermissionDenied", "*"),
        ("Notification", nil), ("Stop", nil), ("StopFailure", nil), ("SubagentStop", nil), ("SessionEnd", nil),
    ]

    /// Substring that identifies Vigil's own hook commands.
    public static let marker = "vigil.sock"

    /// The shell command a hook runs: forwards its stdin JSON to the socket and never fails.
    public static func command(socketPath: String) -> String {
        // $HOME keeps the settings file portable between machines and users.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let portable = socketPath.hasPrefix(home + "/") ? "$HOME" + socketPath.dropFirst(home.count) : socketPath
        return "curl -s -m 1 -H 'Expect:' -H 'Content-Type: application/json' --unix-socket \"\(portable)\" --data-binary @- http://vigil/event >/dev/null 2>&1 || true"
    }

    /// Returns a copy of `settings` with Vigil's hooks present for every event, leaving
    /// other hooks untouched. Idempotent.
    public static func install(into settings: [String: Any], command: String) -> [String: Any] {
        var result = uninstall(from: settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = hooks[event.name] as? [[String: Any]] ?? []
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
            if let matcher = event.matcher { entry["matcher"] = matcher }
            entries.append(entry)
            hooks[event.name] = entries
        }
        result["hooks"] = hooks
        return result
    }

    /// Returns a copy of `settings` without any Vigil hook commands.
    public static func uninstall(from settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard var hooks = result["hooks"] as? [String: Any] else { return result }
        for (eventName, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries = entries.compactMap { entry in
                var entry = entry
                let commands = (entry["hooks"] as? [[String: Any]] ?? []).filter { hook in
                    !((hook["command"] as? String)?.contains(marker) ?? false)
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

    /// True when an older Vigil installed `command` for some events but not for every event
    /// Vigil now listens to. Hooks pointing at another socket are left alone.
    public static func isOutdated(in settings: [String: Any], command: String) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any], !isInstalled(in: settings) else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
            }
        }
    }

    /// True when every event has a Vigil hook.
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
