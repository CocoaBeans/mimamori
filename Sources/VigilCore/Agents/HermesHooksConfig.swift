import Foundation

/// Text-level helpers for wiring Hermes Agent's shell hooks to Vigil.
///
/// Hermes reads a `hooks:` block from `~/.hermes/config.yaml` and runs each command
/// through `shlex.split` without a shell, so the hook is a small script file. Because the
/// config is hand-edited YAML full of comments, Vigil only appends or removes its own
/// clearly delimited block, and never rewrites the rest of the file.
public enum HermesHooksConfig {
    public static let scriptRelativePath = "agent-hooks/vigil.sh"
    public static let beginMarker = "# --- Vigil hooks (added by Vigil; remove this block to uninstall) ---"
    public static let endMarker = "# --- end Vigil hooks ---"
    /// Where Hermes records the hooks you approved. It runs no hook that is missing from it.
    public static let allowlistFileName = "shell-hooks-allowlist.json"

    /// Subscribed events whose Vigil hook is not in Hermes's allowlist yet (`{"approvals": [{event, command}]}`).
    /// Hermes's gateway has no terminal to ask from, so it skips these until you approve them.
    public static func unapprovedEvents(allowlistJSON: Data?, scriptPath: String) -> [String] {
        var approved = Set<String>()
        if let allowlistJSON,
           let object = try? JSONSerialization.jsonObject(with: allowlistJSON) as? [String: Any],
           let approvals = object["approvals"] as? [[String: Any]] {
            for entry in approvals where entry["command"] as? String == scriptPath {
                if let event = entry["event"] as? String { approved.insert(event) }
            }
        }
        return HermesHookParser.subscribedEvents.filter { !approved.contains($0) }
    }

    /// The script Hermes runs for every subscribed event. Exits 0 whatever happens, so it can
    /// never block a tool call, and prints nothing, which Hermes treats as a no-op response.
    public static func script(socketPath: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let portable = socketPath.hasPrefix(home + "/") ? "$HOME" + socketPath.dropFirst(home.count) : socketPath
        return """
        #!/bin/sh
        # Installed by Vigil. Forwards Hermes hook events to Vigil's local socket.
        # Never blocks: a one-second timeout, output discarded, exit status always 0.
        curl -s -m 1 -H 'Expect:' -H 'Content-Type: application/json' \\
          --unix-socket "\(portable)" \\
          --data-binary @- http://vigil/event/hermes >/dev/null 2>&1
        exit 0

        """
    }

    /// The YAML to add under `hooks:`; `scriptPath` is written as given (usually with `~`).
    public static func yamlEntries(scriptPath: String) -> String {
        HermesHookParser.subscribedEvents.map { event in
            "  \(event):\n    - command: \"\(scriptPath)\"\n      timeout: 5\n"
        }.joined()
    }

    /// The complete block Vigil appends when the file has no `hooks:` key of its own.
    public static func block(scriptPath: String) -> String {
        "\n\(beginMarker)\nhooks:\n\(yamlEntries(scriptPath: scriptPath))\(endMarker)\n"
    }

    public static func hasTopLevelHooksKey(_ yaml: String) -> Bool {
        yaml.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            line.hasPrefix("hooks:") && !isInsideVigilBlock(yaml, line: String(line))
        }
    }

    private static func isInsideVigilBlock(_ yaml: String, line: String) -> Bool {
        guard let begin = yaml.range(of: beginMarker), let end = yaml.range(of: endMarker) else { return false }
        return yaml[begin.upperBound..<end.lowerBound].contains(line)
    }

    public static func isInstalled(in yaml: String) -> Bool {
        yaml.contains(scriptRelativePath)
    }

    /// Returns the config with Vigil's block appended, or nil when the file already has a
    /// `hooks:` key (then the entries must be merged by hand).
    public static func install(into yaml: String, scriptPath: String) -> String? {
        let cleaned = uninstall(from: yaml)
        if hasTopLevelHooksKey(cleaned) { return nil }
        let trimmed = cleaned.hasSuffix("\n") || cleaned.isEmpty ? cleaned : cleaned + "\n"
        return trimmed + block(scriptPath: scriptPath)
    }

    /// Returns the config without Vigil's delimited block (unchanged when absent).
    public static func uninstall(from yaml: String) -> String {
        guard let begin = yaml.range(of: beginMarker), let end = yaml.range(of: endMarker) else { return yaml }
        var result = yaml
        var removal = begin.lowerBound..<end.upperBound
        // Swallow the newline that follows the end marker and the blank line before the block.
        if result[removal.upperBound...].hasPrefix("\n") { removal = removal.lowerBound..<result.index(after: removal.upperBound) }
        if removal.lowerBound > result.startIndex, result[result.index(before: removal.lowerBound)] == "\n",
           removal.lowerBound > result.index(after: result.startIndex),
           result[result.index(removal.lowerBound, offsetBy: -2)] == "\n" {
            removal = result.index(before: removal.lowerBound)..<removal.upperBound
        }
        result.removeSubrange(removal)
        return result
    }
}
