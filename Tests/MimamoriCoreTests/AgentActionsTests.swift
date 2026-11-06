import Foundation
import Testing
@testable import MimamoriCore

@Suite("Agent actions")
struct AgentActionsTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func call(_ id: String, at seconds: TimeInterval, tool: String = "Edit", done: Bool = true) -> AgentToolCall {
        AgentToolCall(id: id, toolName: tool, summary: "\(id).swift", filePath: nil, startedAt: base.addingTimeInterval(seconds),
                      finishedAt: done ? base.addingTimeInterval(seconds + 1) : nil)
    }

    @Test func callsFallUnderTheTurnThatStartedBeforeThemNewestFirst() {
        let turns = AgentActions.turns(
            calls: [call("a", at: 5), call("b", at: 12), call("c", at: 25), call("d", at: 30, done: false)],
            starts: [.init(at: base.addingTimeInterval(20), prompt: "Add tests"), .init(at: base, prompt: "Add a cart")])
        #expect(turns.map(\.prompt) == ["Add tests", "Add a cart"])
        #expect(turns.map { $0.calls.map(\.id) } == [["d", "c"], ["b", "a"]])
    }

    @Test func stepsFromBeforeTheFirstKnownTurnFormATurnWithoutAPrompt() {
        let turns = AgentActions.turns(calls: [call("old", at: -50), call("new", at: 10)],
                                       starts: [.init(at: base, prompt: "Fix the build")])
        #expect(turns.map(\.prompt) == ["Fix the build", nil])
        #expect(turns.last?.startedAt == nil)
        #expect(turns.last?.calls.map(\.id) == ["old"])
    }

    @Test func aTurnJustStartedShowsBeforeItsFirstStepButEmptyOldTurnsDont() {
        let turns = AgentActions.turns(calls: [call("a", at: 5)],
                                       starts: [.init(at: base, prompt: "One"), .init(at: base.addingTimeInterval(8), prompt: "Two"),
                                                .init(at: base.addingTimeInterval(9), prompt: "Three")])
        #expect(turns.map(\.prompt) == ["Three", "One"])
        #expect(turns.first?.calls.isEmpty == true)
    }

    @Test func actionsSurviveTheTripToThePhone() throws {
        let actions = AgentActions(worktreePath: "/repo", agent: "Claude Code",
                                   turns: AgentActions.turns(calls: [call("a", at: 5, done: false)],
                                                             starts: [.init(at: base, prompt: "Go")]),
                                   waitingCallID: "a")
        var reader = CompanionLineReader()
        let line = try #require(reader.lines(adding: try CompanionMessage(actions: actions).line()).first)
        #expect(try CompanionMessage(line: line).actions == actions)
        let watch = try #require(reader.lines(adding: try CompanionMessage(watchActions: "/repo").line()).first)
        #expect(try CompanionMessage(line: watch).watchActions == "/repo")
    }
}
