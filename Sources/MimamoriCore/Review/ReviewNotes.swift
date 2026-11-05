import Foundation

/// A note you leave on lines of a change, or on a whole file, for the agent to read.
public struct ReviewNote: Codable, Hashable, Sendable, Identifiable {
    /// Which side of the diff the lines are on: the new file, or the old one for removed lines.
    public enum Side: String, Codable, Sendable {
        case new, old
    }

    public var id: UUID
    public var path: String
    public var side: Side
    /// The first and last line it covers, numbered on its side; nil for the whole file.
    public var lines: ClosedRange<Int>?
    /// Those lines as they read when the note was written: what it quotes, and how it finds
    /// them again after the file changes.
    public var quote: [String]
    public var text: String
    public var createdAt: Date
    public var editedAt: Date?
    /// The file's working-tree blob when the note was written, or when it was last handed over,
    /// to tell when the agent has changed the file since.
    public var blob: String?
    /// When the note was handed over: to an agent, by its name, or copied when `sentTo` is nil.
    public var sentAt: Date?
    public var sentTo: String?
    public var resolvedAt: Date?
    /// Its lines are no longer in the diff, so it can't sit beside them.
    public var isOutdated: Bool

    public init(id: UUID = UUID(), path: String, side: Side = .new, lines: ClosedRange<Int>?, quote: [String] = [],
                text: String, createdAt: Date = Date(), blob: String? = nil) {
        self.id = id
        self.path = path
        self.side = side
        self.lines = lines
        self.quote = quote
        self.text = text
        self.createdAt = createdAt
        self.blob = blob
        self.isOutdated = false
    }

    // A note needs its file and its words; the rest fall back to what a new note has.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReviewNote(path: try c.decode(String.self, forKey: .path), lines: nil,
                                  text: try c.decode(String.self, forKey: .text))
        path = defaults.path
        text = defaults.text
        id = c.decode(.id, or: defaults.id)
        side = c.decode(.side, or: defaults.side)
        lines = c.decode(.lines, or: defaults.lines)
        quote = c.decode(.quote, or: defaults.quote)
        createdAt = c.decode(.createdAt, or: defaults.createdAt)
        editedAt = c.decode(.editedAt, or: defaults.editedAt)
        blob = c.decode(.blob, or: defaults.blob)
        sentAt = c.decode(.sentAt, or: defaults.sentAt)
        sentTo = c.decode(.sentTo, or: defaults.sentTo)
        resolvedAt = c.decode(.resolvedAt, or: defaults.resolvedAt)
        isOutdated = c.decode(.isOutdated, or: defaults.isOutdated)
    }

    public var isSent: Bool { sentAt != nil }
    public var isResolved: Bool { resolvedAt != nil }

    /// "Line 42", "Lines 42–45", "Removed line 7", or "Whole file".
    public var place: String {
        guard let lines else { return "Whole file" }
        let removed = side == .old
        if lines.count == 1 { return removed ? "Removed line \(lines.lowerBound)" : "Line \(lines.lowerBound)" }
        return (removed ? "Removed lines" : "Lines") + " \(lines.lowerBound)–\(lines.upperBound)"
    }

    /// Whether the file has changed since the note was handed over, given its blob now.
    public func changedSinceSent(currentBlob: String?) -> Bool {
        isSent && !isResolved && currentBlob != blob
    }
}

/// A worktree's review notes, oldest first.
public struct ReviewNotes: Codable, Hashable, Sendable {
    public private(set) var all: [ReviewNote] = []

    public init(_ notes: [ReviewNote] = []) {
        all = notes
    }

    // Notes are read one at a time, so one that can't be read loses only itself.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReviewNotes()
        all = c.decode(.all, or: defaults.all)
    }

    public var isEmpty: Bool { all.isEmpty }
    /// Notes not yet resolved.
    public var open: [ReviewNote] { all.filter { !$0.isResolved } }
    /// Open notes not yet handed over.
    public var unsent: [ReviewNote] { all.filter { !$0.isResolved && !$0.isSent } }

    public func notes(for path: String) -> [ReviewNote] { all.filter { $0.path == path } }
    public func unsentCount(for path: String) -> Int { all.lazy.filter { $0.path == path && !$0.isResolved && !$0.isSent }.count }
    public subscript(id: UUID) -> ReviewNote? { all.first { $0.id == id } }

    public mutating func add(_ note: ReviewNote) {
        all.append(note)
    }

    /// New text clears the sent state: the agent hasn't read this version.
    public mutating func edit(_ id: UUID, text: String, at date: Date = Date()) {
        update(id) { note in
            guard note.text != text else { return }
            note.text = text
            note.editedAt = date
            note.sentAt = nil
            note.sentTo = nil
        }
    }

    public mutating func delete(_ id: UUID) {
        all.removeAll { $0.id == id }
    }

    public mutating func resolve(_ id: UUID, at date: Date = Date()) {
        update(id) { $0.resolvedAt = date }
    }

    public mutating func reopen(_ id: UUID) {
        update(id) { $0.resolvedAt = nil }
    }

    /// Records that `ids` were handed over, to `agent` or (nil) copied, with each file's blob now.
    public mutating func markSent(_ ids: [UUID], to agent: String?, blobs: [String: String], at date: Date = Date()) {
        let wanted = Set(ids)
        for index in all.indices where wanted.contains(all[index].id) {
            all[index].sentAt = date
            all[index].sentTo = agent
            all[index].blob = blobs[all[index].path]
        }
    }

    /// Follows each note on `path` to where its quoted lines are now in `diff`, the copy nearest
    /// their old place, and marks a note outdated when they are gone. Resolved notes follow too,
    /// so their folded line stays by the right code. An open note not yet handed over takes
    /// `blob` as the version it was written against. Returns true when anything changed.
    @discardableResult
    public mutating func reanchor(path: String, in diff: FileDiff, blob: String?) -> Bool {
        let before = all
        let sides: [ReviewNote.Side: [(number: Int, text: String)]] = [
            .new: Self.numbered(diff, side: .new),
            .old: Self.numbered(diff, side: .old),
        ]
        for index in all.indices where all[index].path == path {
            if !all[index].isSent && !all[index].isResolved { all[index].blob = blob }
            guard let lines = all[index].lines, !all[index].quote.isEmpty else { continue }
            let found = Self.find(all[index].quote, in: sides[all[index].side] ?? [], near: lines.lowerBound)
            if let found {
                all[index].lines = found...(found + all[index].quote.count - 1)
            }
            all[index].isOutdated = found == nil
        }
        return all != before
    }

    /// Forgets notes resolved before `cutoff`. Returns true when any went.
    @discardableResult
    public mutating func prune(resolvedBefore cutoff: Date) -> Bool {
        let before = all.count
        all.removeAll { ($0.resolvedAt ?? .distantFuture) < cutoff }
        return all.count != before
    }

    private mutating func update(_ id: UUID, _ change: (inout ReviewNote) -> Void) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[index])
    }

    /// The diff's lines a note on `side` can sit on, with their numbers there, in order: added
    /// and unchanged lines for the new file, removed lines for the old one.
    static func numbered(_ diff: FileDiff, side: ReviewNote.Side) -> [(number: Int, text: String)] {
        diff.hunks.flatMap(\.lines).compactMap { line in
            guard let number = number(of: line, on: side) else { return nil }
            return (number, line.text)
        }
    }

    /// The line's number on `side`, when a note there can cover it.
    public static func number(of line: DiffLine, on side: ReviewNote.Side) -> Int? {
        switch (side, line.kind) {
        case (.new, .addition), (.new, .context): line.newNumber
        case (.old, .deletion): line.oldNumber
        default: nil
        }
    }

    /// Where `quote` starts as consecutive lines of `lines`, the start nearest `near`.
    static func find(_ quote: [String], in lines: [(number: Int, text: String)], near: Int) -> Int? {
        guard !quote.isEmpty, lines.count >= quote.count else { return nil }
        var best: Int?
        for start in 0...(lines.count - quote.count) {
            let first = lines[start].number
            let matches = quote.indices.allSatisfy { offset in
                lines[start + offset].text == quote[offset] && lines[start + offset].number == first + offset
            }
            guard matches else { continue }
            if best.map({ abs(first - near) < abs($0 - near) }) ?? true { best = first }
        }
        return best
    }
}
