import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MimamoriCore

/// The window a session summary opens in: one per worktree, to keep beside your work.
struct SessionSummaryWindow: View {
    static let id = "summary"

    @Environment(AppModel.self) private var model
    let worktree: String?

    var body: some View {
        if let worktree, let session = model.sessions[worktree] {
            SessionSummaryView(session: session)
                .navigationTitle("Session Summary — \(session.displayName)")
        } else {
            ContentUnavailableView("Worktree Not Watched", systemImage: "eye.slash",
                                   description: Text("Mimamori no longer watches this worktree, so there is nothing to summarize."))
                .frame(minWidth: 620, minHeight: 480)
                .navigationTitle("Session Summary")
        }
    }
}

extension OpenWindowAction {
    /// Opens the session summary for `worktree`, or brings its window to the front.
    func summary(for worktree: String) {
        self(id: SessionSummaryWindow.id, value: worktree)
    }
}

/// A write-up of one worktree's session: what changed, what needs a look, what you have
/// reviewed and what the agent did, as Markdown to copy or save. It keeps itself up to date
/// while the window stays open.
struct SessionSummaryView: View {
    @Environment(AppModel.self) private var model
    let session: WorktreeSession

    private enum Mode: String, CaseIterable { case preview = "Preview", markdown = "Markdown" }

    @State private var summary: SessionSummary?
    /// `summary` written up with `options`: worked out when either changes, not as the window draws.
    @State private var rendered = Rendered()
    @State private var summaryHasDiffs = false
    @State private var mode = Mode.preview
    @State private var copied = false
    @State private var gatheredAt: Date?
    /// The worktree changed since the summary was gathered, and gathering again is left to you.
    @State private var outOfDate = false
    @State private var refreshes = 0
    @State private var refreshesGathered = 0

    /// What, changing, makes the summary out of date: the worktree's state, your reviews, the
    /// agent's activity there, whether diffs are included, and a press of Refresh.
    private struct Stamp: Hashable {
        var state: WorktreeState?
        var unreviewed: Int
        var latestActivity: UUID?
        var diffs: Bool
        var refreshes: Int
    }

    private var stamp: Stamp {
        Stamp(state: session.state, unreviewed: session.unreviewedCount,
              latestActivity: model.activity.first { $0.worktreePath == session.id }?.id,
              diffs: options.diffs, refreshes: refreshes)
    }

    private var options: SessionSummaryOptions { model.settings.summaryOptions }

    private func option(_ keyPath: WritableKeyPath<SessionSummaryOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.settings.summaryOptions[keyPath: keyPath] },
            set: { value in
                var copy = model.settings
                copy.summaryOptions[keyPath: keyPath] = value
                model.updateSettings(copy)
            })
    }

    /// The summary as Markdown, and how many lines that is.
    private struct Rendered {
        var markdown = ""
        var lines = 0

        init(_ summary: SessionSummary? = nil, options: SessionSummaryOptions = SessionSummaryOptions()) {
            guard let summary else { return }
            markdown = summary.markdown(options: options)
            lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).count
        }
    }

    private var markdown: String { rendered.markdown }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if summary == nil {
                    ProgressView("Gathering the session…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if mode == .preview {
                    ScrollView {
                        MarkdownPreview(markdown: markdown)
                            .padding(16)
                    }
                } else {
                    ScrollView {
                        Text(markdown)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 760, minHeight: 480, idealHeight: 680)
        .task(id: stamp) { await gather() }
        .onChange(of: options) { rendered = Rendered(summary, options: options) }
    }

    /// Gathers the summary at first, when asked, and a moment after the worktree settles.
    /// Diffs take a while to gather, so they are fetched only when wanted, and a summary that
    /// includes them is marked out of date rather than gathered again on its own.
    private func gather() async {
        let wantDiffs = options.diffs
        let asked = refreshes != refreshesGathered
        if summary != nil, !asked, !(wantDiffs && !summaryHasDiffs) {
            if wantDiffs {
                outOfDate = true
                return
            }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
        }
        refreshesGathered = refreshes
        let gathered = await model.sessionSummary(for: session, includeDiffs: wantDiffs)
        guard !Task.isCancelled else { return }
        summary = gathered
        rendered = Rendered(gathered, options: options)
        summaryHasDiffs = wantDiffs
        gatheredAt = Date()
        outOfDate = false
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                // The window's title names the worktree; this says what the summary covers.
                Text("\(session.state?.branch.displayName ?? session.displayName) · \(session.state?.baseline.label ?? session.baseline.title)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Picker("Summary view", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Read the summary formatted, or as the Markdown that Copy and Save produce")
            }
            HStack(spacing: 14) {
                Text("Include:").foregroundStyle(.secondary)
                Toggle("Needs attention", isOn: option(\.attention))
                    .help("Include the flagged files and why each was flagged")
                Toggle("Files", isOn: option(\.files))
                    .help("Include every changed file with its line counts")
                Toggle("Not reviewed", isOn: option(\.unreviewed))
                    .help("Include the files you have not reviewed yet")
                Toggle("Commits", isOn: option(\.commits))
                    .help("Include the commits made since the baseline")
                Toggle("Agent activity", isOn: option(\.activity))
                    .help("Include what the agent did: its turns and tool calls")
                Toggle("Diffs", isOn: option(\.diffs))
                    .help("Include each file's diff. This can make the summary much longer.")
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let summary {
                Text(footerNote(summary))
                    .font(.caption)
                    .foregroundStyle(outOfDate ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .help(outOfDate ? "The worktree changed since this summary was gathered. With diffs included it is not gathered again on its own; press Refresh."
                          : "The summary gathers itself again a moment after the worktree changes")
            }
            if options.diffs && !summaryHasDiffs && summary != nil {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if copied {
                Label("Copied", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Button("Refresh") { refreshes += 1 }
                .disabled(summary == nil)
                .help("Gather the summary again now")
            Button("Save…") { save() }
                .disabled(summary == nil)
                .help("Save the summary as a Markdown file, for example as a handoff note")
            Button("Copy Markdown") { copy() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(summary == nil)
                .help("Copy the summary as Markdown to paste into a pull request or note (⇧⌘C)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func footerNote(_ summary: SessionSummary) -> String {
        let updated = gatheredAt.map { (outOfDate ? "Out of date · gathered " : "Updated ") + Format.time.string(from: $0) }
        return [updated, "\(rendered.lines) lines", "activity since \(Format.dateTime.string(from: summary.activitySince ?? model.launchedAt))"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func copy() {
        Workspace.copy(markdown)
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { copied = false }
        }
    }

    /// Asks where to save, attached to this window so the rest of Mimamori stays usable.
    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        let text = markdown
        let write = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSSound.beep()
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }

    private var suggestedFileName: String {
        let name = (session.state?.branch.displayName ?? session.displayName)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        return "\(name)-summary-\(day).md"
    }
}

/// Just enough Markdown for the summary's own output: headings, bullets, notes, and fenced
/// code (diffs colored by line). Each line is its own row, so long diffs stay lazy.
struct MarkdownPreview: View {
    let markdown: String
    /// The summary's paragraphs are asides between its lists; Help's are its text.
    var dimsParagraphs = true

    private enum Block {
        case title(String), heading(String), subheading(String)
        case bullet(String), note(String), paragraph(String)
        case code(String, diff: Bool)
        case gap
    }

    private var blocks: [(id: Int, block: Block)] {
        var result: [Block] = []
        var inCode: (fence: String, diff: Bool)? = nil
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let open = inCode {
                if line == open.fence { inCode = nil } else { result.append(.code(line, diff: open.diff)) }
                continue
            }
            if line.hasPrefix("```") {
                let fence = String(line.prefix { $0 == "`" })
                inCode = (fence, line.dropFirst(fence.count) == "diff")
            } else if line.hasPrefix("### ") {
                result.append(.subheading(String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                result.append(.heading(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                result.append(.title(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") {
                result.append(.bullet(String(line.dropFirst(2))))
            } else if line.hasPrefix("_"), line.hasSuffix("_"), line.count > 2 {
                result.append(.note(String(line.dropFirst().dropLast())))
            } else if line.isEmpty {
                if case .gap = result.last {} else { result.append(.gap) }
            } else {
                result.append(.paragraph(line))
            }
        }
        return result.enumerated().map { ($0.offset, $0.element) }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 3) {
            ForEach(blocks, id: \.id) { item in
                view(for: item.block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .title(let text):
            Text(inline(text)).font(.title2.weight(.semibold)).padding(.bottom, 2)
        case .heading(let text):
            Text(inline(text)).font(.headline).padding(.top, 8)
        case .subheading(let text):
            Text(inline(text)).font(.subheadline.weight(.semibold)).padding(.top, 6)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(text))
            }
        case .note(let text):
            Text(inline(text)).italic().foregroundStyle(.secondary)
        case .paragraph(let text):
            Text(inline(text)).foregroundStyle(dimsParagraphs ? .secondary : .primary)
        case .code(let text, let diff):
            Text(text.isEmpty ? " " : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(diff && text.hasPrefix("+") ? Color.green : diff && text.hasPrefix("-") ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .background(Color.secondary.opacity(0.08))
        case .gap:
            Color.clear.frame(height: 4)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
