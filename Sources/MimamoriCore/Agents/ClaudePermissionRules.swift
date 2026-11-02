import Foundation

/// The `ask` rules in Claude Code's settings: tool calls you want to be asked about every time.
/// Mimamori never allows one by itself, so it reads them to know which requests must wait for you.
///
/// Rules look like `Bash(git push *--force*)`, where `*` matches anything, `Bash(npm test:*)`, the
/// older prefix form, or a bare tool name such as `WebFetch`. A shell command is matched part by
/// part (`cd repo && git push --force` matches through its second part). A rule for another tool
/// with a specifier (`Edit(src/**)`) is taken to match any call of that tool: Mimamori does not
/// read those specifiers, so it errs towards waiting for you.
public struct ClaudePermissionRules: Sendable, Equatable {
    public var ask: [String]

    public init(ask: [String]) {
        self.ask = ask
    }

    /// The `permissions.ask` rules in a settings file's JSON.
    public static func askRules(in settings: [String: Any]) -> [String] {
        (settings["permissions"] as? [String: Any])?["ask"] as? [String] ?? []
    }

    /// The first ask rule a tool call matches, if any.
    public func matchingAskRule(tool: String, command: String?) -> String? {
        ask.first { Self.rule($0, matches: tool, command: command) }
    }

    static func rule(_ rule: String, matches tool: String, command: String?) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else { return trimmed == tool }
        guard String(trimmed[..<open]) == tool else { return false }
        let specifier = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        guard tool == "Bash" else { return true }
        guard let command, !specifier.isEmpty else { return true }
        let parts = [command] + Self.parts(of: command)
        return parts.contains { Self.pattern(specifier, matches: $0) }
    }

    /// The commands a compound shell command runs: split at `&&`, `||`, `;`, `|` and new lines.
    static func parts(of command: String) -> [String] {
        command.replacingOccurrences(of: "&&", with: "\n").replacingOccurrences(of: "||", with: "\n")
            .split(whereSeparator: { $0 == ";" || $0 == "|" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func pattern(_ pattern: String, matches command: String) -> Bool {
        if pattern.hasSuffix(":*") { return command.hasPrefix(String(pattern.dropLast(2))) }
        let regex = "^" + pattern.components(separatedBy: "*").map(NSRegularExpression.escapedPattern(for:)).joined(separator: ".*") + "$"
        guard let expression = try? NSRegularExpression(pattern: regex, options: [.dotMatchesLineSeparators]) else { return false }
        return expression.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }
}
