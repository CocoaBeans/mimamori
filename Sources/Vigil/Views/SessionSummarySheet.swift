import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VigilCore

/// A write-up of one worktree's session: what changed, what needs a look, what you have
/// reviewed and what the agent did, as Markdown to copy or save.
struct SessionSummarySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: WorktreeSession

    private enum Mode: String, CaseIterable { case preview = "Preview", markdown = "Markdown" }

    @State private var summary: SessionSummary?
    @State private var summaryHasDiffs = false
    @State private var mode = Mode.preview
    @State private var copied = false

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

    private var markdown: String { summary?.markdown(options: options) ?? "" }

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
        // Diffs take a while to gather, so only fetch them when they are wanted.
        .task(id: options.diffs) {
            guard summary == nil || (options.diffs && !summaryHasDiffs) else { return }
            let wantDiffs = options.diffs
            let gathered = await model.sessionSummary(for: session, includeDiffs: wantDiffs)
            guard !Task.isCancelled else { return }
            summary = gathered
            summaryHasDiffs = wantDiffs
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session Summary")
                        .font(.title3.weight(.semibold))
                    Text("\(session.state?.branch.displayName ?? session.displayName) · \(session.state?.baseline.label ?? session.baseline.title)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
            Button("Save…") { save() }
                .disabled(summary == nil)
                .help("Save the summary as a Markdown file, for example as a handoff note")
            Button("Copy Markdown") { copy() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(summary == nil)
                .help("Copy the summary as Markdown to paste into a pull request or note (⇧⌘C)")
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .help("Close the summary")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func footerNote(_ summary: SessionSummary) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).count
        return "\(lines) lines · activity since \(Format.dateTime.string(from: summary.activitySince ?? model.launchedAt))"
    }

    private func copy() {
        Workspace.copy(markdown)
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { copied = false }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        let text = markdown
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSSound.beep()
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
            Text(inline(text)).foregroundStyle(.secondary)
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
