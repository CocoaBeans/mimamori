import Foundation

/// A Claude Code session's title, from its transcript: the one you gave it (or the desktop app
/// did), else the one Claude Code wrote by itself. Both are lines Claude Code appends to the
/// transcript, `{"type":"custom-title","customTitle":…}` and `{"type":"ai-title","aiTitle":…}`,
/// and it writes them again every turn, so the newest sits near the end of a file that can run
/// to many megabytes. Only the end is read.
public enum ClaudeSessionTitle {
    /// How much of the transcript's end is read, at most. A title is written every turn, so a
    /// turn's worth of lines after it is all that can come between.
    public static let tailLength = 512 * 1024
    /// Titles are cut to this many characters for a one-line label.
    public static let maxLength = 80

    /// The title in the transcript at `url`, or nil when it has none or can't be read.
    public static func read(transcript url: URL, tailLength: Int = tailLength) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailLength) ? size - UInt64(tailLength) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return title(inTail: data, fromStart: start == 0)
    }

    /// The title in the end of a transcript: the newest one you gave it, else the newest
    /// Claude Code wrote. Unless it begins the file, its first line may be cut short, and is skipped.
    static func title(inTail data: Data, fromStart: Bool) -> String? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if !fromStart, !lines.isEmpty { lines.removeFirst() }
        var automatic: String?
        for line in lines.reversed() {
            // A cheap look first: most lines are messages, and some are long.
            guard line.count < 4096, let text = String(data: line, encoding: .utf8),
                  text.contains("-title\"") else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "custom-title":
                if let title = cleaned(object["customTitle"]) { return title }
            case "ai-title":
                if automatic == nil { automatic = cleaned(object["aiTitle"]) }
            default:
                break
            }
        }
        return automatic
    }

    private static func cleaned(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.count > maxLength ? String(line.prefix(maxLength - 1)) + "…" : line
    }
}
