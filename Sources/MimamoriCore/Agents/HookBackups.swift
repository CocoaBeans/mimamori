import Foundation

/// The copies Mimamori saves of an agent's settings file before it changes it, beside the file
/// as `<file>.<time>.mimamori-backup`. Only the newest few are kept.
public enum HookBackups {
    public static let kept = 5

    /// Newest first: the times in their names sort as text.
    public static func list(of file: URL) -> [URL] {
        let directory = file.deletingLastPathComponent()
        let prefix = file.lastPathComponent + "."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".mimamori-backup") }
            .sorted(by: >)
            .map { directory.appendingPathComponent($0) }
    }

    /// Deletes all but the newest `kept`.
    public static func prune(_ file: URL) {
        for old in list(of: file).dropFirst(kept) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
