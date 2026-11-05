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

    @Test func anAgentsCardSurvivesTheTrip() throws {
        let edit = AgentToolCall(id: "c1", toolName: "Edit", summary: "Sources/Checkout.swift", filePath: nil,
                                 startedAt: now.addingTimeInterval(-40), finishedAt: now.addingTimeInterval(-38))
        let test = AgentToolCall(id: "c2", toolName: "Bash", summary: "swift test", filePath: nil,
                                 startedAt: now.addingTimeInterval(-30))
        let card = AgentWidgetSnapshot.Card(
            reportsSteps: true, turnUnderway: true, turnStartedAt: now.addingTimeInterval(-60), calls: [edit, test],
            callsThisTurn: 14, waitingCallID: "c2", lastCall: test,
            files: [.init(path: "Sources/Checkout.swift", additions: 40, deletions: 2), .init(path: "logo.png"),
                    .init(path: ".env", additions: 1, deletions: 0, flagged: true)],
            changes: .init(files: 3, toReview: 2, flagged: 1, additions: 41, deletions: 2),
            others: [.init(agent: "Codex", symbol: "terminal", state: .working, status: "working · Edit", since: now)])
        let snapshot = AgentWidgetSnapshot(writtenAt: now, agents: [
            .init(worktreePath: "/repo", repository: "shop", worktree: "main", agent: "Claude Code", state: .needsYou,
                  status: "needs permission · Bash swift test", since: now.addingTimeInterval(-30), card: card),
        ])
        var reader = CompanionLineReader()
        let lines = reader.lines(adding: try CompanionMessage(snapshot: snapshot).line())
        let decoded = try #require(try CompanionMessage(line: lines[0]).snapshot)
        #expect(decoded == snapshot)
        #expect(decoded.agents[0].card?.files.map(\.name) == ["Checkout.swift", "logo.png", ".env"])
    }

    @Test func aWidgetSnapshotCarriesNoCards() throws {
        // The widgets' file leaves the card out, and one written before cards existed decodes as before.
        let snapshot = AgentWidgetSnapshot(writtenAt: now, agents: [
            .init(worktreePath: "/repo", repository: "shop", worktree: "main", agent: "Codex", state: .working,
                  status: "working", since: now),
        ])
        let json = String(decoding: try snapshot.encoded(), as: UTF8.self)
        #expect(!json.contains("card"))
        let old = #"{"writtenAt":1800000000,"mimamoriRunning":true,"agents":[{"worktreePath":"/repo","repository":"shop","#
            + #""worktree":"main","agent":"Codex","state":"working","status":"working","since":1800000000,"steps":[],"others":0}]}"#
        let decoded = try #require(AgentWidgetSnapshot.load(from: {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("old-\(UUID().uuidString).json")
            try? Data(old.utf8).write(to: url)
            return url
        }()))
        #expect(decoded.agents[0].card == nil)
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
