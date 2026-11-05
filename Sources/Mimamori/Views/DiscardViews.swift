import SwiftUI
import MimamoriCore

/// Whether the agents in a worktree let Mimamori write to it. Mid-turn, an agent goes on editing
/// files as it last read them, so a write then is refused; between turns it only needs telling.
enum WriteGate: Equatable {
    case clear
    /// Allowed, with a word of warning.
    case caution(String)
    /// Not while it lasts.
    case refused(String)

    init(_ presence: AgentPresence?) {
        guard let presence else {
            self = .clear
            return
        }
        let all = [presence] + presence.others
        for agent in all where agent.source == .hooks {
            let name = agent.kind.displayName
            switch agent.activity {
            case .working:
                self = .refused("\(name) is in the middle of a turn in this worktree. Discard once its turn ends.")
                return
            case .needsPermission, .askedQuestion:
                self = .refused("\(name) is waiting on you in the middle of a turn, and goes on editing once you answer. Discard once its turn ends.")
                return
            case .ready, .idle:
                continue
            }
        }
        if let running = all.first(where: { $0.source == .process || $0.activity == .idle }) {
            self = .caution("\(running.kind.displayName) is running in this worktree, and Mimamori can't tell whether it's in the middle of a turn. Make sure it isn't editing this file.")
        } else if let ready = all.first(where: { $0.activity == .ready }) {
            self = .caution("\(ready.kind.displayName) is between turns here. It won't know about this unless you tell it.")
        } else {
            self = .clear
        }
    }

    var refusal: String? {
        if case .refused(let reason) = self { return reason }
        return nil
    }
}

/// A hunk or a whole file you asked to discard, with the version of the file it was shown for.
struct DiscardRequest: Identifiable {
    enum Scope: Hashable {
        case hunk(DiffHunk)
        case file
    }

    let change: FileChange
    let scope: Scope
    /// The file's diff against HEAD as shown, for the preview; the sheet reads it when nil.
    var diff: FileDiff? = nil
    var decorations: DiffDecorations = .empty
    /// Debug builds: confirm by itself once shown (`MIMAMORI_DEBUG_FLAGS=discard:<n>:confirm`).
    var confirmsItself = false

    var id: String {
        switch scope {
        case .hunk(let hunk): "\(change.contentKey)|hunk|\(hunk.id)"
        case .file: "\(change.contentKey)|file"
        }
    }
}

/// Asks before throwing a hunk or a whole file away, showing the lines that go and the ones that
/// come back.
struct DiscardSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: WorktreeSession
    let request: DiscardRequest
    let fontSize: Double

    @State private var working = false
    @State private var failure: String?
    @State private var previewHeight: CGFloat = 0
    /// The file's diff, read when the request came without one.
    @State private var loadedDiff: FileDiff?

    private static let maxPreviewHeight: CGFloat = 320
    /// A whole file's preview stops after this many lines.
    private static let previewLineLimit = 400

    private var change: FileChange { request.change }

    private var title: String {
        switch (request.scope, change.kind) {
        case (.hunk, _): "Discard this hunk?"
        case (.file, .added): "Discard this new file?"
        case (.file, .deleted): "Bring back this deleted file?"
        case (.file, _): "Discard all changes to this file?"
        }
    }

    private var message: String {
        let what = switch (request.scope, change.kind) {
        case (.hunk, _): "Its lines in \(change.path) go back to how they are in the last commit."
        case (.file, .added): "\(change.path) isn't in the last commit, so it moves to the Trash."
        case (.file, .deleted): "\(change.path) comes back as it is in the last commit."
        case (.file, _): "\(change.path) goes back to how it is in the last commit, mode included."
        }
        return what + " Mimamori takes a snapshot first, so you can undo this."
    }

    private var confirmTitle: String {
        switch (request.scope, change.kind) {
        case (.hunk, _): "Discard Hunk"
        case (.file, .added): "Move to Trash"
        case (.file, .deleted): "Bring Back"
        case (.file, _): "Discard Changes"
        }
    }

    /// The hunks to show, and how many lines past the limit are left out.
    private var shown: (hunks: [DiffHunk], hiddenLines: Int) {
        switch request.scope {
        case .hunk(let hunk):
            return ([hunk], 0)
        case .file:
            let hunks = (request.diff ?? loadedDiff)?.hunks ?? []
            var budget = Self.previewLineLimit
            var result: [DiffHunk] = []
            for hunk in hunks where budget > 0 {
                var part = hunk
                part.lines = Array(hunk.lines.prefix(budget))
                budget -= part.lines.count
                result.append(part)
            }
            let total = hunks.reduce(0) { $0 + $1.lines.count }
            return (result, max(0, total - Self.previewLineLimit))
        }
    }

    private var counts: (additions: Int, deletions: Int) {
        switch request.scope {
        case .hunk(let hunk): (hunk.additions, hunk.deletions)
        case .file: (change.additions ?? 0, change.deletions ?? 0)
        }
    }

    private var numberWidth: CGFloat {
        let largest = shown.hunks.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 999
        return CGFloat(max(3, String(largest).count)) * fontSize * 0.62 + 10
    }

    var body: some View {
        let gate = WriteGate(model.agentHub.presence(for: session.id))
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            preview
            notices(gate)
            HStack {
                Spacer()
                if working {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(failure == nil ? "Cancel" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help(failure == nil ? "Keep the change" : "Close; the file is as it was")
                if failure == nil {
                    Button(confirmTitle, role: .destructive) { confirm() }
                        .disabled(working || gate.refusal != nil)
                        .help(gate.refusal ?? "Put it back as it is in the last commit, after a snapshot")
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .task {
            if case .file = request.scope, request.diff == nil, !change.isBinary {
                loadedDiff = try? await session.diff(for: change)
            }
            guard request.confirmsItself else { return }
            try? await Task.sleep(for: .seconds(2))
            confirm()
        }
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Group {
                    if case .hunk(let hunk) = request.scope {
                        Text(hunk.header)
                            .font(.system(size: max(9, fontSize - 1), design: .monospaced))
                    } else {
                        Text(change.path)
                            .font(.system(size: max(9, fontSize - 1), weight: .medium, design: .monospaced))
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 8)
                if !change.isBinary {
                    DeltaText(additions: counts.additions, deletions: counts.deletions)
                        .fixedSize()
                        .help("\(counts.additions) lines added and \(counts.deletions) removed, which go")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.09))
            Divider()
            if let note = previewNote {
                Text(note)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                ScrollView {
                    lines
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
                }
                .frame(height: min(max(previewHeight, 24), Self.maxPreviewHeight))
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What is discarded")
    }

    /// In place of lines, when there are none to show.
    private var previewNote: String? {
        if change.isBinary { return "A binary file: its contents go back to the last commit's." }
        guard case .file = request.scope, shown.hunks.isEmpty else { return nil }
        if request.diff == nil, loadedDiff == nil { return "Reading the diff…" }
        if change.modeChanged { return "Only its mode changed (\(change.oldMode) to \(change.newMode))." }
        return "No lines changed."
    }

    private var lines: some View {
        let shown = shown
        let several = shown.hunks.count > 1 || request.scope == .file
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown.hunks) { hunk in
                if several {
                    Text(hunk.header)
                        .font(.system(size: max(9, fontSize - 1), design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.05))
                }
                ForEach(hunk.lines) { line in
                    DiffLineRow(line: line, wrap: true, fontSize: fontSize, numberWidth: numberWidth,
                                syntax: request.decorations.syntax[line.id], emphasis: request.decorations.emphasis[line.id],
                                isTarget: false)
                }
            }
            if shown.hiddenLines > 0 {
                Text("and \(shown.hiddenLines) more lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func notices(_ gate: WriteGate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if change.isStaged {
                Label("This file has staged changes. Only the working tree changes: what you staged stays in the index.",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            switch gate {
            case .clear:
                EmptyView()
            case .caution(let text):
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .refused(let text):
                Label(text, systemImage: "hand.raised.fill")
                    .foregroundStyle(.red)
            }
            if let failure {
                Label(failure, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func confirm() {
        guard !working, failure == nil else { return }
        // Looked at again now: an agent may have started since the sheet opened.
        if let refusal = WriteGate(model.agentHub.presence(for: session.id)).refusal {
            failure = refusal
            return
        }
        working = true
        Task {
            do {
                switch request.scope {
                case .hunk(let hunk): try await session.discard(hunk, of: change)
                case .file: try await session.discardFile(change)
                }
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            working = false
        }
    }
}

/// Above the diff once something is discarded: what went, with Undo, until you dismiss it.
struct DiscardUndoBar: View {
    @Environment(AppModel.self) private var model
    let session: WorktreeSession

    var body: some View {
        if let latest = session.discards.first {
            let gate = WriteGate(model.agentHub.presence(for: session.id))
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "trash.circle")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(latest.summary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Group {
                            if let error = session.restoreError {
                                Text(error)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            } else {
                                Text(detail(latest))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .font(.caption)
                    }
                    Spacer(minLength: 8)
                    if session.restoreError != nil {
                        Button("Copy Restore Command") { Workspace.copy(latest.restoreCommand) }
                            .help("Copy a command that puts the whole file back as the snapshot taken before the discard has it: \(latest.restoreCommand)")
                    }
                    Button("Undo") { Task { await session.restoreLatestDiscard() } }
                        .disabled(session.isWriting || gate.refusal != nil)
                        .help(gate.refusal ?? "Put it back as it was, after a snapshot")
                    Button {
                        session.forgetDiscards()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss. The snapshot taken before the discard stays.")
                    .accessibilityLabel("Dismiss")
                }
                .font(.callout)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.08))
                Divider()
            }
            .task(id: latest.id) { await undoForDebugging() }
        }
    }

    private func detail(_ discarded: DiscardedChange) -> String {
        var parts = ["at \(Format.time.string(from: discarded.date))", "snapshot taken first"]
        let more = session.discards.count - 1
        if more > 0 { parts.append(more == 1 ? "1 earlier one to undo" : "\(more) earlier ones to undo") }
        return parts.joined(separator: " · ")
    }

    /// Debug builds: `MIMAMORI_DEBUG_FLAGS=discard-undo` presses Undo once, 3 s after a discard.
    private func undoForDebugging() async {
        guard model.debugFlags.contains("discard-undo"), !Self.undidForDebugging else { return }
        Self.undidForDebugging = true
        try? await Task.sleep(for: .seconds(3))
        await session.restoreLatestDiscard()
    }

    private static var undidForDebugging = false
}

extension View {
    /// A line's context menu with Discard This Hunk, where hunks can be discarded.
    @ViewBuilder
    func discardHunkMenu(_ action: (() -> Void)?) -> some View {
        if let action {
            contextMenu {
                Button("Discard This Hunk…", action: action)
            }
        } else {
            self
        }
    }
}
