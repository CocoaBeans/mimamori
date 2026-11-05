import Foundation
import Testing
@testable import MimamoriCore

@Suite("Review notes")
struct ReviewNotesTests {
    /// A one-hunk diff of `cart.js` from a unified patch body.
    private func diff(_ body: String) throws -> FileDiff {
        let patch = """
        diff --git a/cart.js b/cart.js
        --- a/cart.js
        +++ b/cart.js
        \(body)
        """
        return try #require(DiffParser.parse(patch).first)
    }

    private let original = """
    @@ -1,4 +1,5 @@
     function total(items) {
    -  return items.reduce((s, i) => s + i.price, 0);
    +  const sum = items.reduce((s, i) => s + i.price * i.quantity, 0);
    +  return Math.round(sum);
     }
     export { total };
    """

    private func note(_ lines: ClosedRange<Int>?, quote: [String], side: ReviewNote.Side = .new, text: String = "Why round?") -> ReviewNote {
        ReviewNote(path: "cart.js", side: side, lines: lines, quote: quote, text: text, createdAt: Date(timeIntervalSince1970: 1_000))
    }

    @Test func followsItsLinesWhenOthersAreInsertedAbove() throws {
        var notes = ReviewNotes([note(3...3, quote: ["  return Math.round(sum);"])])
        let moved = try diff("""
        @@ -1,4 +1,7 @@
        +// Totals for the cart.
        +
         function total(items) {
        -  return items.reduce((s, i) => s + i.price, 0);
        +  const sum = items.reduce((s, i) => s + i.price * i.quantity, 0);
        +  return Math.round(sum);
         }
         export { total };
        """)
        let changed = notes.reanchor(path: "cart.js", in: moved, blob: "b2")
        #expect(changed)
        #expect(notes.all[0].lines == 5...5)
        #expect(notes.all[0].isOutdated == false)
        #expect(notes.all[0].blob == "b2")
    }

    @Test func isOutdatedOnceItsLinesAreGone() throws {
        var notes = ReviewNotes([note(2...3, quote: ["  const sum = items.reduce((s, i) => s + i.price * i.quantity, 0);",
                                                     "  return Math.round(sum);"])])
        let rewritten = try diff("""
        @@ -1,4 +1,4 @@
         function total(items) {
        -  return items.reduce((s, i) => s + i.price, 0);
        +  return items.reduce((s, i) => s + i.price * i.quantity, 0);
         }
         export { total };
        """)
        notes.reanchor(path: "cart.js", in: rewritten, blob: "b2")
        #expect(notes.all[0].isOutdated)
        #expect(notes.all[0].lines == 2...3, "an outdated note keeps the lines it was written on")
    }

    @Test func picksTheCopyNearestItsOldPlace() {
        let lines: [(number: Int, text: String)] = [(1, "}"), (2, "x"), (3, "}"), (9, "}")]
        #expect(ReviewNotes.find(["}"], in: lines, near: 8) == 9)
        #expect(ReviewNotes.find(["}"], in: lines, near: 2) == 1)
        #expect(ReviewNotes.find(["x", "}"], in: lines, near: 9) == 2)
        // Lines 3 and 9 match the text but are not consecutive.
        #expect(ReviewNotes.find(["}", "}"], in: lines, near: 3) == nil)
    }

    @Test func resolvedNotesFollowTheirLinesToo() throws {
        var notes = ReviewNotes([note(1...1, quote: ["  return Math.round(sum);"])])
        let id = notes.all[0].id
        notes.resolve(id)
        notes.reanchor(path: "cart.js", in: try diff(original), blob: "b2")
        #expect(notes[id]?.lines == 3...3)
        #expect(notes[id]?.blob == nil, "a resolved note keeps the version it was written against")
    }

    @Test func notesOnRemovedLinesUseTheOldSide() throws {
        var notes = ReviewNotes([note(2...2, quote: ["  return items.reduce((s, i) => s + i.price, 0);"], side: .old)])
        notes.reanchor(path: "cart.js", in: try diff(original), blob: "b1")
        #expect(notes.all[0].lines == 2...2)
        #expect(notes.all[0].isOutdated == false)
    }

    @Test func wholeFileNotesNeverGoOutOfDate() throws {
        var notes = ReviewNotes([note(nil, quote: [])])
        notes.reanchor(path: "cart.js", in: try diff(original), blob: "b1")
        #expect(notes.all[0].isOutdated == false)
        #expect(notes.all[0].lines == nil)
    }

    @Test func aSentNoteKeepsTheBlobItWasSentAgainst() throws {
        var notes = ReviewNotes([note(3...3, quote: ["  return Math.round(sum);"])])
        let id = notes.all[0].id
        notes.markSent([id], to: "Claude Code", blobs: ["cart.js": "b1"])
        notes.reanchor(path: "cart.js", in: try diff(original), blob: "b2")
        #expect(notes[id]?.blob == "b1")
        #expect(notes[id]?.changedSinceSent(currentBlob: "b2") == true)
        #expect(notes[id]?.changedSinceSent(currentBlob: "b1") == false)
    }

    @Test func editingClearsTheSentState() {
        var notes = ReviewNotes([note(1...1, quote: ["function total(items) {"])])
        let id = notes.all[0].id
        notes.markSent([id], to: nil, blobs: [:])
        #expect(notes.unsent.isEmpty)
        notes.edit(id, text: "Why round?")
        #expect(notes[id]?.isSent == true, "the same text is no edit")
        notes.edit(id, text: "Round to cents instead.")
        #expect(notes[id]?.isSent == false)
        #expect(notes.unsent.count == 1)
    }

    @Test func resolvedNotesLeaveTheCountsAndArePrunedLater() {
        var notes = ReviewNotes([note(1...1, quote: ["a"]), note(2...2, quote: ["b"])])
        let first = notes.all[0].id
        notes.resolve(first, at: Date(timeIntervalSince1970: 5_000))
        #expect(notes.open.count == 1)
        #expect(notes.unsentCount(for: "cart.js") == 1)
        let early = notes.prune(resolvedBefore: Date(timeIntervalSince1970: 4_000))
        #expect(early == false)
        let late = notes.prune(resolvedBefore: Date(timeIntervalSince1970: 6_000))
        #expect(late)
        #expect(notes.all.count == 1)
        notes.reopen(notes.all[0].id)
        #expect(notes.open.count == 1)
    }

    @Test func survivesARoundTrip() throws {
        var notes = ReviewNotes([note(2...3, quote: ["a", "b"]), note(nil, quote: [])])
        notes.markSent([notes.all[0].id], to: "Codex", blobs: ["cart.js": "b1"])
        let data = try JSONEncoder().encode(notes)
        #expect(try JSONDecoder().decode(ReviewNotes.self, from: data) == notes)
    }

    @Test func placeNamesTheLines() {
        #expect(note(4...4, quote: ["a"]).place == "Line 4")
        #expect(note(4...6, quote: ["a", "b", "c"]).place == "Lines 4–6")
        #expect(note(7...7, quote: ["a"], side: .old).place == "Removed line 7")
        #expect(note(nil, quote: []).place == "Whole file")
    }
}

@Suite("Review note prompt")
struct ReviewNotePromptTests {
    @Test func oneBlockPerNoteWithItsCode() {
        let notes = [
            ReviewNote(path: "src/cart.ts", lines: 42...43, quote: ["const a = 1;", "const b = 2;"], text: "Merge these."),
            ReviewNote(path: "src/discounts.ts", lines: nil, text: "Trim the codes."),
            ReviewNote(path: "src/old.ts", side: .old, lines: 7...7, quote: ["legacy();"], text: "Why did this go?"),
        ]
        #expect(ReviewNotePrompt.format(notes, branch: "feature/discounts") == """
        Review notes on your changes on feature/discounts (3 notes), written in Mimamori, the review app watching this worktree. Address each one, then say what you changed.

        File: src/cart.ts
        Lines: 42-43
        Code:
            const a = 1;
            const b = 2;
        User comment: "Merge these."

        File: src/discounts.ts
        Scope: file
        User comment: "Trim the codes."

        File: src/old.ts
        Removed line: 7
        Code:
            legacy();
        User comment: "Why did this go?"

        """)
    }

    @Test func escapesTheComment() {
        #expect(ReviewNotePrompt.escape("Say \"hi\"\nthen C:\\temp") == #"Say \"hi\"\nthen C:\\temp"#)
    }

    @Test func longQuotesAreCut() {
        let quote = (1...20).map { "line \($0)" }
        let block = ReviewNotePrompt.block(ReviewNote(path: "a", lines: 1...20, quote: quote, text: "Too long."))
        #expect(block.contains("    line 12\n    …\n"))
        #expect(!block.contains("line 13"))
    }
}
