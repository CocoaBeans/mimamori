import Foundation

/// Spots a Claude Code shell command while it runs, which is how an approval shows before the
/// command ends: Claude Code sends no hook between "Allow" and the command finishing, so a long
/// build or test run would otherwise look as if it still waited on you.
///
/// Claude Code runs each command as `<shell> -c '… eval '<command>' < /dev/null && pwd -P >| …'`,
/// with every `'` in the command written as `'"'"'`.
public enum ClaudeCommandProbe {
    static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "fish"]

    /// The text a command whose first line is `firstLine` leaves in its shell's script.
    public static func needle(forFirstLine firstLine: String) -> String {
        "eval '" + firstLine.replacingOccurrences(of: "'", with: #"'"'"'"#)
    }

    /// Whether `arguments` are those of a shell running the command `needle` stands for.
    public static func isRunning(_ needle: String, arguments: [String]) -> Bool {
        guard let flag = arguments.firstIndex(of: "-c"), flag + 1 < arguments.count else { return false }
        return arguments[(flag + 1)...].contains { $0.contains(needle) }
    }

    /// Which of `commands` (a command's first line → when it asked for permission) have a shell
    /// running them that started after it asked.
    public static func running(_ commands: [String: Date]) -> Set<String> {
        guard let earliest = commands.values.min() else { return [] }
        let wanted = commands.map { (line: $0.key, needle: needle(forFirstLine: $0.key), since: $0.value.addingTimeInterval(-1)) }
        var found = Set<String>()
        for pid in ProcessInspector.allPIDs() {
            guard let path = ProcessInspector.executablePath(of: pid),
                  shells.contains((path as NSString).lastPathComponent),
                  let started = ProcessInspector.startDate(of: pid),
                  started >= earliest.addingTimeInterval(-1) else { continue }
            let arguments = ProcessInspector.arguments(of: pid)
            for item in wanted where started >= item.since && !found.contains(item.line) && isRunning(item.needle, arguments: arguments) {
                found.insert(item.line)
            }
            if found.count == wanted.count { break }
        }
        return found
    }
}
