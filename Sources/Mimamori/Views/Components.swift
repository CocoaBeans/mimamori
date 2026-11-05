import SwiftUI
import MimamoriCore

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

/// A count with a symbol that says what it counts, in a capsule: "⚠ 2", "± 7", "👁 3".
struct CountChip: View {
    let symbol: String
    let count: Int
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .imageScale(.small)
            Text(count, format: .number)
        }
        .font(.caption2.monospacedDigit().weight(.semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(tint.opacity(0.16), in: Capsule())
        .foregroundStyle(tint)
        .fixedSize()
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
        // Squeezed in a narrow column, the counts would wrap a character a line and vanish.
        .fixedSize()
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

/// A button that copies something and shows that it did, since copying changes nothing on screen:
/// for a moment its icon turns into a green checkmark, or its title reads Copied (keeping its
/// width, so nothing beside it moves). VoiceOver hears "Copied".
struct CopyButton: View {
    private let title: String?
    private let helpText: String
    private let copy: () -> Void
    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    /// An icon button, `doc.on.doc`; `help` is also its accessibility label.
    init(help: String, copy: @escaping () -> Void) {
        self.title = nil
        self.helpText = help
        self.copy = copy
    }

    /// A button with a title, such as "Copy YAML".
    init(_ title: String, help: String, copy: @escaping () -> Void) {
        self.title = title
        self.helpText = help
        self.copy = copy
    }

    var body: some View {
        Button {
            copy()
            AccessibilityNotification.Announcement("Copied").post()
            withAnimation(.easeOut(duration: 0.1)) { copied = true }
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.15)) { copied = false }
            }
        } label: {
            if let title {
                ZStack {
                    Text(title).opacity(copied ? 0 : 1)
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark").foregroundStyle(.green)
                        Text("Copied")
                    }
                    .opacity(copied ? 1 : 0)
                }
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace, options: .speed(1.4)))
                    .foregroundStyle(copied ? AnyShapeStyle(Color.green) : AnyShapeStyle(.foreground))
            }
        }
        .help(copied ? "Copied" : helpText)
        .accessibilityLabel(copied ? "Copied" : (title ?? helpText))
        .onDisappear { reset?.cancel() }
    }
}
