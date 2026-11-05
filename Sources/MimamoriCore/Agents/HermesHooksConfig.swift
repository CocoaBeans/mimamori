import Foundation

/// Text-level helpers for wiring Hermes Agent's shell hooks to Mimamori.
///
/// Hermes reads a `hooks:` block from `config.yaml` in its home (`~/.hermes`, or `$HERMES_HOME`)
/// and runs each command through `shlex.split` without a shell, so the hook is a small script
/// file. Because the config is hand-edited YAML full of comments, Mimamori only appends or
/// removes its own clearly delimited block, and never rewrites the rest of the file.
public enum HermesHooksConfig {
    public static let scriptRelativePath = "agent-hooks/mimamori.sh"
    public static let beginMarker = "# --- Mimamori hooks (added by Mimamori; remove this block to uninstall) ---"
    public static let endMarker = "# --- end Mimamori hooks ---"
    /// Where Hermes records the hooks you approved. It runs no hook that is missing from it.
    public static let allowlistFileName = "shell-hooks-allowlist.json"

    /// Subscribed events whose Mimamori hook is not in Hermes's allowlist yet (`{"approvals": [{event, command}]}`).
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
    public static func script(socketPath: String, home: String = HookCommand.defaultHome) -> String {
        """
        #!/bin/sh
        # Installed by Mimamori. Forwards Hermes hook events to Mimamori's local socket.
        # Never blocks: a one-second timeout, output discarded, exit status always 0.
        \(HookCommand.curl(socketPath: socketPath, address: "/event/hermes", timeout: 1, home: home)) >/dev/null 2>&1
        exit 0

        """
    }

    /// The YAML to add under `hooks:`; `scriptPath` is written as given (usually with `~`).
    public static func yamlEntries(scriptPath: String) -> String {
        let quoted = scriptPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return HermesHookParser.subscribedEvents.map { event in
            "  \(event):\n    - command: \"\(quoted)\"\n      timeout: 5\n"
        }.joined()
    }

    /// The complete block Mimamori appends when the file has no `hooks:` key of its own.
    public static func block(scriptPath: String) -> String {
        "\n\(beginMarker)\nhooks:\n\(yamlEntries(scriptPath: scriptPath))\(endMarker)\n"
    }

    public static func hasTopLevelHooksKey(_ yaml: String) -> Bool {
        yaml.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            line.hasPrefix("hooks:") && !isInsideMimamoriBlock(yaml, line: String(line))
        }
    }

    private static func isInsideMimamoriBlock(_ yaml: String, line: String) -> Bool {
        [(beginMarker, endMarker), (FormerName.hermesBeginMarker, FormerName.hermesEndMarker)].contains { begin, end in
            guard let begin = yaml.range(of: begin), let end = yaml.range(of: end) else { return false }
            return yaml[begin.upperBound..<end.lowerBound].contains(line)
        }
    }

    /// True when the config still has the hooks the app installed under its former name: its block, or its
    /// script merged by hand.
    public static func hasFormerHooks(in yaml: String) -> Bool {
        yaml.contains(FormerName.hermesBeginMarker) || yaml.contains(FormerName.hermesScriptRelativePath)
    }

    public static func isInstalled(in yaml: String) -> Bool {
        yaml.contains(scriptRelativePath)
    }

    /// Returns the config with Mimamori's block appended, or nil when the file already has a
    /// `hooks:` key (then the entries must be merged by hand).
    public static func install(into yaml: String, scriptPath: String) -> String? {
        let cleaned = uninstall(from: yaml)
        if hasTopLevelHooksKey(cleaned) { return nil }
        let trimmed = cleaned.hasSuffix("\n") || cleaned.isEmpty ? cleaned : cleaned + "\n"
        return trimmed + block(scriptPath: scriptPath)
    }

    /// Returns the config without Mimamori's delimited block, or the one it added under its former name
    /// (unchanged when neither is there).
    public static func uninstall(from yaml: String) -> String {
        removeBlock(from: removeBlock(from: yaml, begin: beginMarker, end: endMarker),
                    begin: FormerName.hermesBeginMarker, end: FormerName.hermesEndMarker)
    }

    private static func removeBlock(from yaml: String, begin beginMarker: String, end endMarker: String) -> String {
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
