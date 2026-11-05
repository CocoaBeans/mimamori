import Foundation

/// The copies Mimamori saves of an agent's settings file before it changes it, beside the file
/// as `<file>.<time>.mimamori-backup`. Only the newest few are kept, plus the first copy it ever
/// took, `<file>.mimamori-original`, which is never pruned.
public enum HookBackups {
    public static let kept = 5

    /// Newest first.
    public static func list(of file: URL) -> [URL] {
        let directory = file.deletingLastPathComponent()
        let prefix = file.lastPathComponent + "."
        let suffix = ".mimamori-backup"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let stamped = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) && $0.count > prefix.count + suffix.count }
        let keyed = stamped.map { name in (name, sortKey(String(name.dropFirst(prefix.count).dropLast(suffix.count)))) }
        return keyed.sorted { $0.1.stamp != $1.1.stamp ? $0.1.stamp > $1.1.stamp : $0.1.count > $1.1.count }
            .map { directory.appendingPathComponent($0.0) }
    }

    /// The first copy Mimamori took of `file`.
    public static func originalURL(of file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".mimamori-original")
    }

    /// The name for a backup taken at `date`. A second one in the same second gets `-2`, and so on.
    public static func backupURL(of file: URL, at date: Date, attempt: Int = 1) -> URL {
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        let name = file.lastPathComponent + "." + stamp + (attempt > 1 ? "-\(attempt)" : "") + ".mimamori-backup"
        return file.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Deletes all but the newest `kept`. The original is not in the list, so it stays.
    public static func prune(_ file: URL) {
        for old in list(of: file).dropFirst(kept) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    /// "2026-11-08T04-02-00Z-2" sorts as the time, then the 2. The time's text sorts in order.
    private static func sortKey(_ stamp: String) -> (stamp: String, count: Int) {
        guard let zone = stamp.lastIndex(of: "Z") else { return (stamp, 1) }
        let rest = stamp[stamp.index(after: zone)...]
        guard rest.hasPrefix("-"), let count = Int(rest.dropFirst()) else { return (stamp, 1) }
        return (String(stamp[...zone]), count)
    }
}
