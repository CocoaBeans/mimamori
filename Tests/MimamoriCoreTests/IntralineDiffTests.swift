import Foundation
import Testing
@testable import MimamoriCore

@Suite("Intraline diff")
struct IntralineDiffTests {
    @Test func highlightsInsertedWord() throws {
        let old = "    return f\"Howdy, {name}!\""
        let new = "    return f\"Howdy there, {name}!\""
        let result = try #require(IntralineDiff.changedRanges(old: old, new: new))
        #expect(result.old.isEmpty)
        #expect(result.new.count == 1)
        let range = result.new[0]
        let chars = Array(new)
        #expect(String(chars[range]) == " there")
    }

    @Test func highlightsReplacedTokenOnBothSides() throws {
        let result = try #require(IntralineDiff.changedRanges(old: "let count = 10", new: "let count = 42"))
        #expect(String(Array("let count = 10")[result.old[0]]) == "10")
        #expect(String(Array("let count = 42")[result.new[0]]) == "42")
    }

    @Test func givesUpWhenLinesAreUnrelated() {
        #expect(IntralineDiff.changedRanges(old: "import Foundation", new: "    return a * b") == nil)
    }

    @Test func mergesAdjacentTokens() {
        let merged = IntralineDiff.merge([0..<3, 3..<5, 7..<9, 10..<12])
        #expect(merged == [0..<5, 7..<12])
    }

    @Test func unifiedTextRoundTrips() {
        let patch = """
        diff --git a/a.txt b/a.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
         one
        -two
        +three

        """
        let diff = DiffParser.parse(patch)[0]
        #expect(diff.unifiedText == patch)
    }
}
