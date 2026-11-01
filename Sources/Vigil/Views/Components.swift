import SwiftUI
import VigilCore

extension ChangeKind {
    var color: Color {
        switch self {
        case .added: .green
        case .modified: .orange
        case .deleted: .red
        case .renamed, .copied: .blue
        case .typeChanged: .purple
        case .unmerged: .red
        case .unknown: .gray
        }
    }
}

extension Severity {
    var color: Color {
        switch self {
        case .info: .gray
        case .warning: .orange
        case .critical: .red
        }
    }

    var systemImage: String {
        switch self {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }
}

struct StatusGlyph: View {
    let kind: ChangeKind

    var body: some View {
        Text(kind.glyph)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 17, height: 17)
            .background(kind.color.gradient, in: .rect(cornerRadius: 4))
            .accessibilityLabel(kind.title)
    }
}

struct CountBadge: View {
    let count: Int
    var tint: Color = .secondary

    var body: some View {
        Text(count, format: .number)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// "+12 −3" and its diff bar.
struct DeltaText: View {
    let additions: Int?
    let deletions: Int?
    var bar = true

    var body: some View {
        HStack(spacing: 4) {
            if let additions {
                Text("+\(additions)").foregroundStyle(.green)
            }
            if let deletions {
                Text("−\(deletions)").foregroundStyle(.red)
            }
            if bar, additions != nil || deletions != nil {
                DiffBar(additions: additions ?? 0, deletions: deletions ?? 0)
                    .padding(.leading, 2)
            }
        }
        .font(.caption.monospacedDigit())
    }
}

/// Five small blocks: as many lit as the change is large, green for the share of lines added and
/// red for the share removed (`DiffBlocks`).
struct DiffBar: View {
    let additions: Int
    let deletions: Int
    var block: CGFloat = 6

    var body: some View {
        let blocks = DiffBlocks(additions: additions, deletions: deletions)
        HStack(spacing: block / 4) {
            ForEach(0..<DiffBlocks.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: block / 4)
                    .fill(index < blocks.added ? AnyShapeStyle(Color.green)
                          : index < blocks.added + blocks.removed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.quaternary))
                    .frame(width: block, height: block)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(additions) lines added, \(deletions) removed")
    }
}

/// What kind of file a path is, at a glance (`FileSymbol`).
struct FileTypeIcon: View {
    let path: String

    var body: some View {
        Image(systemName: FileSymbol.name(for: path))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

struct FlagIcons: View {
    let flags: [AttentionFlag]

    private var distinct: [AttentionFlag] {
        var seen = Set<RuleID>()
        return flags.sorted { $0.severity > $1.severity }.filter { seen.insert($0.rule).inserted }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(distinct.prefix(3)) { flag in
                Image(systemName: flag.rule.systemImage)
                    .font(.caption2)
                    .foregroundStyle(flag.severity.color)
                    .help(flag.message)
            }
        }
    }
}

enum Format {
    static func abbreviate(path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

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

enum Workspace {
    static func reveal(path: String, in worktree: String) {
        let url = URL(fileURLWithPath: worktree).appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    static func open(path: String, in worktree: String) {
        let url = URL(fileURLWithPath: worktree).appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    static func openTerminal(at path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: configuration)
        }
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
