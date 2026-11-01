import Testing
@testable import MimamoriCore

@Suite("Diff overview")
struct DiffOverviewTests {
    private func hunk(_ id: Int, _ kinds: [DiffLineKind], from first: Int) -> DiffHunk {
        DiffHunk(id: id, header: "@@ hunk \(id) @@", oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
                 lines: kinds.enumerated().map { offset, kind in
                     DiffLine(id: first + offset, kind: kind, text: "x", oldNumber: nil, newNumber: nil)
                 })
    }

    @Test func marksRunsOfAddedAndRemovedLines() {
        // Rows: header, ctx, -, -, +, ctx | header, +, +, +  (10 rows)
        let overview = DiffOverview(hunks: [hunk(0, [.context, .deletion, .deletion, .addition, .context], from: 0),
                                            hunk(1, [.addition, .addition, .addition], from: 5)], sideBySide: false)
        #expect(overview.rows.count == 10)
        #expect(overview.marks.map(\.kind) == [.deletion, .addition, .addition])
        #expect(overview.marks.map(\.start) == [0.2, 0.4, 0.7])
        #expect(overview.marks.map(\.length) == [0.2, 0.1, 0.3])
        #expect(overview.hunkStarts == [0, 0.6])
    }

    @Test func pairsRemovedAndAddedLinesSideBySide() {
        let overview = DiffOverview(hunks: [hunk(0, [.deletion, .deletion, .addition, .context], from: 0)], sideBySide: true)
        // Rows: header, (-,+), (-, ), ctx
        #expect(overview.rows.count == 4)
        #expect(overview.marks.map(\.kind) == [.change, .deletion])
    }

    @Test func findsTheRowAtAPointDownTheStrip() {
        let overview = DiffOverview(hunks: [hunk(0, [.context, .addition], from: 0), hunk(1, [.deletion], from: 2)], sideBySide: false)
        // Rows: header(0), 0, 1, header(1), 2
        #expect(overview.row(at: 0)?.id == 0)            // a header gives the line after it
        #expect(overview.row(at: 0.5)?.id == 1)
        #expect(overview.row(at: 0.65)?.id == 2)
        #expect(overview.row(at: 0.65)?.hunk == 1)
        #expect(overview.row(at: 1.5)?.id == 2)           // clamped
        #expect(DiffOverview(hunks: [], sideBySide: false).row(at: 0.5) == nil)
    }
}
