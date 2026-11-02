import Foundation
import Testing
@testable import MimamoriCore

@Suite("Raw diff and line counts from one run")
struct CombinedDiffTests {
    @Test func splitsTheRawEntriesFromTheCounts() {
        // What `git diff --cached --raw --numstat -z -M` printed for an add, a delete, a rename and an edit.
        let output = [
            ":000000 100644 0000000000000000000000000000000000000000 3e757656cf36eca53338e520d134963a44f793f8 A", "added.txt",
            ":100644 000000 587be6b4c3f93f93c489c0111bba5596147a26cb 0000000000000000000000000000000000000000 D", "gone.txt",
            ":100644 100644 115c9a7dbe93b05a314bf0cb55aa830d5da41758 115c9a7dbe93b05a314bf0cb55aa830d5da41758 R100", "old-name.txt", "new-name.txt",
            ":100644 100644 de980441c3ab03a8c07dda1ad27b8a11f39deb1e a7bc997ebe8cf84988b83d2e83f1d193124fe593 M", "one.txt",
            "1\t0\tadded.txt", "0\t1\tgone.txt", "0\t0\t", "old-name.txt", "new-name.txt", "2\t1\tone.txt", "",
        ].joined(separator: "\0")
        let (raw, numstat) = GitClient.splitRawAndNumstat(Data(output.utf8))
        let entries = RawDiffParser.parse(raw)
        let counts = NumstatParser.parse(numstat)
        #expect(entries.map(\.path) == ["added.txt", "gone.txt", "new-name.txt", "one.txt"])
        #expect(entries[2].oldPath == "old-name.txt")
        #expect(counts.map(\.path) == ["added.txt", "gone.txt", "new-name.txt", "one.txt"])
        #expect(counts.last?.additions == 2 && counts.last?.deletions == 1)
    }

    @Test func emptyAndCountsOnly() {
        #expect(GitClient.splitRawAndNumstat(Data()).raw.isEmpty)
        let counts = Data("3\t0\tnew.txt\0".utf8)
        let (raw, numstat) = GitClient.splitRawAndNumstat(counts)
        #expect(raw.isEmpty && numstat == counts)
    }
}
