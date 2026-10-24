import Foundation

/// The activity feed on disk, so it outlives a restart: one JSON entry per line, appended as
/// entries arrive and compacted when it grows. Writes happen on a private serial queue;
/// `flush()` waits for them, for use when the app quits.
public final class ActivityLog: @unchecked Sendable {
    public let url: URL
    public var retention: TimeInterval {
        get { queue.sync { _retention } }
        set { queue.sync { _retention = newValue } }
    }
    public let maxEntries: Int

    private let queue = DispatchQueue(label: "dev.vigil.activity-log")
    private var _retention: TimeInterval
    /// Lines in the file, so compaction can be triggered without reading it.
    private var lineCount = 0

    public init(url: URL, retention: TimeInterval, maxEntries: Int = 10_000) {
        self.url = url
        self._retention = retention
        self.maxEntries = maxEntries
    }

    /// Entries from disk, oldest first, without those past the retention window or the cap.
    /// Rewrites the file when anything was dropped or could not be read.
    public func load(now: Date = Date()) -> [ActivityEntry] {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else {
                lineCount = 0
                return []
            }
            let decoder = Self.decoder
            var entries: [ActivityEntry] = []
            var lines = 0
            for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                lines += 1
                // A line cut short by a crash, or damaged by hand, is skipped.
                if let entry = try? decoder.decode(ActivityEntry.self, from: Data(line)) {
                    entries.append(entry)
                }
            }
            let kept = prune(entries, now: now)
            if kept.count != lines {
                write(kept)
            } else {
                lineCount = lines
            }
            return kept
        }
    }

    /// Adds entries to the end of the file, in the order given (oldest first).
    public func append(_ entries: [ActivityEntry]) {
        guard !entries.isEmpty else { return }
        queue.async { [self] in
            let encoder = Self.encoder
            var data = Data()
            for entry in entries {
                guard let line = try? encoder.encode(entry) else { continue }
                data.append(line)
                data.append(UInt8(ascii: "\n"))
            }
            appendData(data)
            lineCount += entries.count
            // Compact once the file holds half again as many entries as are kept.
            if lineCount > maxEntries + maxEntries / 2 {
                compact()
            }
        }
    }

    /// Replaces the whole file, oldest first. An empty list clears it.
    public func replaceAll(with entries: [ActivityEntry]) {
        queue.async { [self] in write(entries) }
    }

    /// Waits for pending writes.
    public func flush() {
        queue.sync {}
    }

    // MARK: Internals (on the queue)

    private func prune(_ entries: [ActivityEntry], now: Date) -> [ActivityEntry] {
        let cutoff = now.addingTimeInterval(-_retention)
        let recent = entries.filter { $0.date >= cutoff }
        return recent.count > maxEntries ? Array(recent.suffix(maxEntries)) : recent
    }

    private func compact() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = Self.decoder
        let entries = data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(ActivityEntry.self, from: Data($0))
        }
        write(prune(entries, now: Date()))
    }

    private func write(_ entries: [ActivityEntry]) {
        let encoder = Self.encoder
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        lineCount = entries.count
    }

    private func appendData(_ data: Data) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
