import Foundation
import Testing
@testable import MimamoriCore

@Suite("Companion messages")
struct CompanionMessageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func line(_ text: String) -> Data { Data(text.utf8) }

    @Test func aSnapshotSurvivesTheTripAsOneLine() throws {
        let snapshot = AgentWidgetSnapshot(writtenAt: now, agents: [
            .init(worktreePath: "/repo/plan", repository: "backend", repositoryColor: .teal, worktree: "plan",
                  agent: "Codex", state: .needsYou, status: "needs permission · Bash", since: now,
                  task: "Plan the release\nthen tag it", steps: [.init(tool: "Bash", target: "make\ttest", running: true)]),
        ])
        let data = try CompanionMessage(snapshot: snapshot).line()
        // A newline inside the task is escaped, so the only one ends the line.
        #expect(data.filter { $0 == 0x0A }.count == 1)
        #expect(data.last == 0x0A)

        var reader = CompanionLineReader()
        let lines = reader.lines(adding: data)
        #expect(lines.count == 1)
        let message = try CompanionMessage(line: lines[0])
        #expect(message.version == CompanionMessage.currentVersion)
        #expect(message.snapshot == snapshot)
        #expect(message.wantsSnapshot == nil)
    }

    @Test func fieldsFromANewerVersionAreIgnored() throws {
        let message = try CompanionMessage(line: line(#"{"version":2,"wantsSnapshot":true,"somethingNew":[1,2]}"#))
        #expect(message.version == 2)
        #expect(message.wantsSnapshot == true)
    }

    @Test func linesAreSplitWhereverThePiecesBreak() {
        var reader = CompanionLineReader()
        #expect(reader.lines(adding: line("{\"a\":1}\n{\"b\"")).map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#])
        #expect(reader.lines(adding: line(":2")).isEmpty)
        #expect(reader.lines(adding: line("}\n\n{\"c\":3}\n")).map { String(decoding: $0, as: UTF8.self) }
                == [#"{"b":2}"#, #"{"c":3}"#])
    }

    @Test func aLineOverTheLimitIsDroppedAndReadingCarriesOn() {
        var reader = CompanionLineReader(limit: 8)
        // Over the limit before its newline arrives: dropped, the rest of it too.
        #expect(reader.lines(adding: line("0123456789")).isEmpty)
        #expect(reader.lines(adding: line("abc\nok\n")).map { String(decoding: $0, as: UTF8.self) } == ["ok"])
        // Over the limit within one piece.
        #expect(reader.lines(adding: line("0123456789\nfine\n")).map { String(decoding: $0, as: UTF8.self) } == ["fine"])
    }
}
