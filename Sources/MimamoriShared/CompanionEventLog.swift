import Foundation

/// What the iPhone companion did in the background, kept on the phone so you can see it there: the
/// keep-alive starting and stopping, audio interruptions, the connection, the Live Activity. When
/// the Live Activity says it hasn't been updated lately, this says why, or at least when the app
/// stopped running.
///
/// While the app runs in the background it beats every minute (`heartbeat`). Coming back to the
/// front, or starting afresh, it checks the last beat: a long silence means iOS suspended or ended
/// the app, and the log says from when to when.
public struct CompanionEventLog: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case app, keepAlive, audio, connection, liveActivity
    }

    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var id = UUID()
        public var date: Date
        public var kind: Kind
        public var text: String

        public init(date: Date, kind: Kind, text: String) {
            self.date = date
            self.kind = kind
            self.text = text
        }
    }

    /// Older entries go first, beyond either limit.
    public static let maxEntries = 500
    public static let maxAge: TimeInterval = 3 * 24 * 60 * 60
    /// How often the app beats while it runs in the background.
    public static let heartbeatInterval: TimeInterval = 60
    /// Silent this long past its last beat, the app wasn't running.
    public static let gapAfter: TimeInterval = 3 * heartbeatInterval

    /// Oldest first.
    public private(set) var entries: [Entry] = []
    /// When the app last beat in the background; nil while it's in front, or before it first left.
    public private(set) var lastHeartbeat: Date?

    public init() {}

    public mutating func add(_ kind: Kind, _ text: String, at date: Date = Date()) {
        entries.append(Entry(date: date, kind: kind, text: text))
        prune(now: date)
    }

    /// The app is running in the background at `date`.
    public mutating func heartbeat(at date: Date = Date()) {
        lastHeartbeat = date
    }

    /// The app came to the front at `date`. If it had stopped beating in the background, says from
    /// when to when it wasn't running. True when it found such a gap.
    @discardableResult
    public mutating func cameToFront(at date: Date = Date()) -> Bool {
        defer { lastHeartbeat = nil }
        guard let last = lastHeartbeat, date.timeIntervalSince(last) > Self.gapAfter else { return false }
        add(.app, "Wasn't running from \(Self.time(last)) to \(Self.time(date)) (\(Self.duration(date.timeIntervalSince(last)))): iOS suspended or ended it",
            at: date)
        return true
    }

    /// The app started at `date`. If it had been running in the background before, iOS ended it
    /// (or it was quit), and the log says when it was last seen.
    public mutating func started(at date: Date = Date(), version: String) {
        if let last = lastHeartbeat {
            add(.app, "Started afresh. It was last seen running in the background at \(Self.time(last)), \(Self.duration(date.timeIntervalSince(last))) ago: iOS ended it, or it was quit",
                at: date)
        }
        lastHeartbeat = nil
        add(.app, "Started (\(version))", at: date)
    }

    public mutating func clear() {
        entries.removeAll()
    }

    private mutating func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.date) > Self.maxAge }
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    /// The whole log as text, newest last, to share.
    public func text(timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return entries.map { "\(formatter.string(from: $0.date))  [\($0.kind.rawValue)]  \($0.text)" }
            .joined(separator: "\n")
    }

    /// "3:10 PM", in the phone's own clock.
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "45 s", "12 min", "2 h 7 min".
    public static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
