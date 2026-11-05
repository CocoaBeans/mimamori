import SwiftUI
import MimamoriCore

/// Where a note is being written or edited in the diff. Its words are kept apart, in
/// `NoteDraftText`, so the diff doesn't redraw as you type.
struct NoteDraft: Equatable {
    var side: ReviewNote.Side = .new
    /// The lines it will cover; nil for the whole file.
    var lines: ClosedRange<Int>?
    /// The hunk the lines are in: a range never leaves its hunk.
    var hunk: Int?
    /// The note being edited, if this is not a new one.
    var editing: UUID?

    var place: String {
        ReviewNote(path: "", side: side, lines: lines, text: "").place
    }
}

/// The words of the note being written. Only the composer reads them as it draws, so a
/// keystroke redraws the composer alone. They outlive it: a new note keeps its words when you
/// pick another line for it, which puts the composer somewhere else.
@MainActor @Observable
final class NoteDraftText {
    var text = ""
}

/// What the diff needs to show a file's notes and change them; nil where notes don't apply,
/// such as a commit's diff.
struct DiffNotes {
    var notes: [ReviewNote]
    /// The file's working-tree blob now, to tell a note the agent has changed the file since.
    var currentBlob: String?
    /// Whether notes on removed lines can be shown and made: the since-review diff numbers its
    /// old side differently.
    var showsOldSide: Bool
    var add: (ReviewNote.Side, ClosedRange<Int>?, [String], String) -> Void
    var edit: (UUID, String) -> Void
    var delete: (UUID) -> Void
    var setResolved: (UUID, Bool) -> Void

    /// Notes shown beside a line: open or resolved, with their lines still in the diff.
    func onLines(side: ReviewNote.Side, endingAt number: Int) -> [ReviewNote] {
        notes.filter { $0.side == side && !$0.isOutdated && $0.lines?.upperBound == number && (side == .new || showsOldSide) }
    }

    /// Notes shown above the diff: on the whole file, or whose lines are gone.
    var aboveDiff: [ReviewNote] {
        notes.filter { $0.lines == nil || $0.isOutdated || ($0.side == .old && !showsOldSide) }
    }

    /// Lines with a note shown beside them, by side.
    func notedLines(side: ReviewNote.Side) -> Set<Int> {
        var lines = Set<Int>()
        for note in notes where note.side == side && !note.isOutdated && !note.isResolved {
            if let range = note.lines { lines.formUnion(range) }
        }
        return lines
    }
}

/// How a diff line stands with notes, for its gutter.
enum NoteMark {
    case none, noted, drafting
}

/// The speech bubble in a line's gutter: filled on a line with a note, and under the pointer on
/// any other, to start one.
struct NoteGutterButton: View {
    let mark: NoteMark
    let visible: Bool
    let place: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: mark == .none ? "plus.bubble" : "text.bubble.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(mark == .none ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                .frame(width: 18, height: 16)
                .background(.background, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(visible || mark != .none ? 1 : 0)
        .allowsHitTesting(visible || mark != .none)
        .help("Leave a note on \(place.lowercased()) for the agent. Shift-click another line to cover the lines between.")
        .accessibilityLabel("Add a note on \(place.lowercased())")
    }
}

/// A note beside its lines: what you wrote, and where it stands.
struct ReviewNoteCard: View {
    let note: ReviewNote
    let currentBlob: String?
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onResolve: (Bool) -> Void

    private var state: (text: String, tint: Color) {
        if note.isResolved { return ("Resolved", .secondary) }
        if note.isOutdated { return ("Its lines have changed", .orange) }
        if note.changedSinceSent(currentBlob: currentBlob) {
            return (note.sentTo == nil ? "Changed since you copied it" : "Changed since you sent it", .accentColor)
        }
        if let sentAt = note.sentAt {
            let time = Format.time.string(from: sentAt)
            return (note.sentTo.map { "Sent to \($0) at \(time)" } ?? "Copied at \(time)", .secondary)
        }
        return ("Not sent", .secondary)
    }

    private var rendered: AttributedString {
        (try? AttributedString(markdown: note.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(note.text)
    }

    var body: some View {
        if note.isResolved {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.bubble")
                    .foregroundStyle(.secondary)
                Text("\(note.place) · \(note.text)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button("Reopen") { onResolve(false) }
                    .buttonStyle(.borderless)
                    .help("Open this note again")
            }
            .font(.callout)
            .modifier(NoteBox(tint: .secondary))
        } else {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(note.place)
                        .fontWeight(.medium)
                    Text(state.text)
                        .foregroundStyle(state.tint)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Group {
                        Button(action: onEdit) { Image(systemName: "pencil") }
                            .help("Edit this note")
                            .accessibilityLabel("Edit note")
                        Button { onResolve(true) } label: { Image(systemName: "checkmark") }
                            .help("Resolve: the agent has dealt with it, or it no longer matters")
                            .accessibilityLabel("Resolve note")
                        Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                            .help("Delete this note")
                            .accessibilityLabel("Delete note")
                    }
                    .buttonStyle(.borderless)
                }
                .font(.caption)
                if note.isOutdated || (note.side == .old && note.lines != nil), !note.quote.isEmpty {
                    // The lines it was written on, since they are not beside it.
                    Text(note.quote.prefix(ReviewNotePrompt.quoteLimit).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(ReviewNotePrompt.quoteLimit)
                        .textSelection(.enabled)
                }
                Text(rendered)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .modifier(NoteBox(tint: .accentColor))
        }
    }
}

/// Writes a new note or edits one. Return saves, Option-Return starts a new line, Escape cancels.
struct ReviewNoteComposer: View {
    let draft: NoteDraft
    @Bindable var words: NoteDraftText
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    private var isEmpty: Bool { words.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(Color.accentColor)
                Text(draft.editing == nil ? "New note on \(draft.place.lowercased())" : "Editing the note on \(draft.place.lowercased())")
                    .fontWeight(.medium)
                if draft.editing == nil, draft.lines != nil {
                    Text("Shift-click another line's bubble to cover more")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            TextField("What should the agent change?", text: $words.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(2...10)
                .focused($focused)
                .onSubmit(save)
                .onExitCommand(perform: onCancel)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            HStack(spacing: 8) {
                Text("Return saves · ⌥Return starts a new line · Markdown works")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Cancel", action: onCancel)
                    .help("Discard this note (Escape)")
                Button(draft.editing == nil ? "Add Note" : "Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(isEmpty)
                    .help("Save the note (Return)")
            }
            .controlSize(.small)
        }
        .modifier(NoteBox(tint: .accentColor))
        .onAppear { focused = true }
    }

    private func save() {
        guard !isEmpty else { return }
        onSave()
    }
}

/// A note's box: inset like the code it is about, not too wide to read.
private struct NoteBox: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: 680, alignment: .leading)
            .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(tint.opacity(0.3)))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
