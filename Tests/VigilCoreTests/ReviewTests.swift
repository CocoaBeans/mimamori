import Foundation
import Testing
@testable import VigilCore

@Suite("Review ledger")
struct ReviewLedgerTests {
    private func change(_ path: String, new: String?, old: String? = "aaa", mode: String = "100644") -> FileChange {
        FileChange(path: path, kind: new == nil ? .deleted : .modified, oldMode: "100644",
                   newMode: new == nil ? "000000" : mode, oldOID: old, newOID: new)
    }

    @Test func unmarkedFilesAreUnreviewed() {
        let ledger = ReviewLedger()
        #expect(ledger.status(of: change("a.swift", new: "b1")) == .unreviewed)
    }

    @Test func reviewedUntilTheContentChanges() throws {
        var ledger = ReviewLedger()
        let date = Date(timeIntervalSince1970: 1_000)
        ledger.markReviewed(change("a.swift", new: "b1"), at: date)
        #expect(ledger.status(of: change("a.swift", new: "b1")) == .reviewed(at: date))

        let status = ledger.status(of: change("a.swift", new: "b2"))
        guard case .changedSinceReview(let mark) = status else {
            Issue.record("expected changedSinceReview, got \(status)")
            return
        }
        #expect(mark.blob == "b1")
        #expect(mark.reviewedAt == date)
    }

    @Test func baselineSideDoesNotMatter() {
        var ledger = ReviewLedger()
        ledger.markReviewed(change("a.swift", new: "b1", old: "base-head"))
        #expect(ledger.isReviewed(change("a.swift", new: "b1", old: "base-branch-point")))
    }

    @Test func modeChangeCountsAsAChange() {
        var ledger = ReviewLedger()
        ledger.markReviewed(change("run.sh", new: "b1"))
        #expect(!ledger.isReviewed(change("run.sh", new: "b1", mode: "100755")))
    }

    @Test func deletionsAreReviewable() {
        var ledger = ReviewLedger()
        let deleted = change("gone.txt", new: nil, old: "o1")
        ledger.markReviewed(deleted)
        #expect(ledger.isReviewed(deleted))
        // The file comes back with new content: no longer the deletion you saw.
        #expect(!ledger.isReviewed(change("gone.txt", new: "b9")))
    }

    @Test func clearingForgetsTheMark() {
        var ledger = ReviewLedger()
        ledger.markReviewed(change("a.swift", new: "b1"))
        ledger.markReviewed(change("b.swift", new: "c1"))
        ledger.clear("a.swift")
        #expect(ledger.status(of: change("a.swift", new: "b1")) == .unreviewed)
        #expect(ledger.isReviewed(change("b.swift", new: "c1")))
        ledger.clearAll()
        #expect(ledger.isEmpty)
    }

    @Test func pruneKeepsCurrentAndRecentMarks() {
        var ledger = ReviewLedger()
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 9_000)
        ledger.markReviewed(change("listed.swift", new: "b1"), at: old)
        ledger.markReviewed(change("gone-old.swift", new: "b2"), at: old)
        ledger.markReviewed(change("gone-recent.swift", new: "b3"), at: recent)

        let removed = ledger.prune(keepingPaths: ["listed.swift"], olderThan: Date(timeIntervalSince1970: 5_000))
        #expect(removed)
        #expect(Set(ledger.marks.keys) == ["listed.swift", "gone-recent.swift"])
        let removedAgain = ledger.prune(keepingPaths: ["listed.swift"], olderThan: Date(timeIntervalSince1970: 5_000))
        #expect(!removedAgain)
    }

    @Test func countsReviewedChanges() {
        var ledger = ReviewLedger()
        let changes = [change("a", new: "1"), change("b", new: "2"), change("c", new: "3")]
        #expect(changes.reviewedCount(in: ledger) == 0)
        ledger.markReviewed(changes[0])
        ledger.markReviewed(change("b", new: "old"))
        #expect(changes.reviewedCount(in: ledger) == 1)
    }

    @Test func roundTripsThroughJSON() throws {
        var ledger = ReviewLedger()
        ledger.markReviewed(change("a.swift", new: "b1"), at: Date(timeIntervalSince1970: 1_234))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReviewLedger.self, from: encoder.encode(ledger))
        #expect(decoded == ledger)
    }
}
