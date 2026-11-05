import Foundation

// Shared with the iPhone companion, which shows the same times and spans.
enum Format {
    #if os(macOS)
    static func abbreviate(path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
    #endif

    static func relative(_ date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        // Minutes, not seconds: lists keep this current with a clock that ticks every 30 s.
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86400))d ago"
        }
    }

    /// "42s", "12m", "5h 12m", "2d 3h": how long something has been going on.
    /// "45s", "12m", "1h 05m" for a span of time.
    static func duration(_ interval: TimeInterval) -> String {
        duration(since: Date(timeIntervalSinceReferenceDate: 0), to: Date(timeIntervalSinceReferenceDate: interval))
    }

    static func duration(since start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400:
            let minutes = (seconds % 3600) / 60
            return minutes > 0 ? "\(seconds / 3600)h \(minutes)m" : "\(seconds / 3600)h"
        default:
            let hours = (seconds % 86400) / 3600
            return hours > 0 ? "\(seconds / 86400)d \(hours)h" : "\(seconds / 86400)d"
        }
    }

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
