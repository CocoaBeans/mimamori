import SwiftUI
import VigilCore

/// The orange "⚠ N" count, as a button that explains itself in a popover.
struct AttentionBadgeButton: View {
    @Environment(AppModel.self) private var model
    let sessions: [WorktreeSession]
    var arrowEdge: Edge = .bottom
    /// Lets the debug hooks open a specific instance.
    var debugID: String? = nil

    @State private var isPresented = false

    private var count: Int { sessions.reduce(0) { $0 + $1.flaggedCount } }

    var body: some View {
        if count > 0 {
            Button {
                isPresented.toggle()
            } label: {
                Label("\(count)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Files needing attention. Click for details.")
            .accessibilityLabel("\(count) files need attention")
            .popover(isPresented: $isPresented, arrowEdge: arrowEdge) {
                AttentionPopover(sessions: sessions) { isPresented = false }
            }
            .onAppear {
                if let debugID, model.debugFlags.contains("popover:" + debugID) { isPresented = true }
            }
        }
    }
}

struct AttentionPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let sessions: [WorktreeSession]
    let dismiss: () -> Void

    private struct Item: Identifiable {
        let session: WorktreeSession
        let change: FileChange
        var id: String { session.id + "|" + change.path }
        var severity: Severity { change.maxSeverity ?? .info }
    }

    private var items: [Item] {
        sessions
            .flatMap { session in session.changes.filter(\.isFlagged).map { Item(session: session, change: $0) } }
            .sorted { a, b in
                if a.severity != b.severity { return a.severity > b.severity }
                if a.change.flags.count != b.change.flags.count { return a.change.flags.count > b.change.flags.count }
                return a.change.path < b.change.path
            }
    }

    private var showsWorktree: Bool { sessions.count > 1 }

    var body: some View {
        let items = items
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(items.count == 1 ? "1 file needs attention" : "\(items.count) files need attention")
                    .font(.headline)
            }
            Text("These changes match rules that usually deserve a second look before they ship: secrets and credentials, dependency lockfiles, CI and agent instructions, mass deletions, skipped tests, conflict markers and similar. A flag is a hint to read the diff, not a verdict.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        Button {
                            model.select(worktree: item.session.id, path: item.change.path)
                            dismiss()
                        } label: {
                            AttentionRow(change: item.change,
                                         worktreeName: showsWorktree ? item.session.displayName : nil)
                        }
                        .buttonStyle(.plain)
                        .help("Show this file")
                    }
                }
            }
            .frame(maxHeight: 340)
            Divider()
            HStack {
                Button("Rules in Settings…") {
                    model.settingsTab = .attention
                    openSettings()
                    dismiss()
                }
                Spacer()
                Button("Show Only Flagged") {
                    model.flaggedOnly = true
                    if sessions.count == 1, let only = sessions.first { model.select(worktree: only.id) }
                    dismiss()
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 400)
    }
}

private struct AttentionRow: View {
    let change: FileChange
    let worktreeName: String?

    private var flags: [AttentionFlag] {
        change.flags.sorted { $0.severity > $1.severity }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusGlyph(kind: change.kind)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    if !change.directory.isEmpty {
                        Text(change.directory + "/").foregroundStyle(.secondary)
                    }
                    Text(change.fileName).fontWeight(.medium)
                    if let worktreeName {
                        Text("  ·  \(worktreeName)")
                            .foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.head)
                ForEach(flags.prefix(3)) { flag in
                    Label {
                        Text(flag.message + (flag.line.map { " (line \($0))" } ?? ""))
                    } icon: {
                        Image(systemName: flag.rule.systemImage)
                    }
                    .font(.caption)
                    .foregroundStyle(flag.severity.color)
                    .lineLimit(1)
                }
                if flags.count > 3 {
                    Text("+\(flags.count - 3) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}
