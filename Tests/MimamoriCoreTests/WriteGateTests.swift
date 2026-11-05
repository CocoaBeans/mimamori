import Testing
@testable import MimamoriCore

@Suite("Write gate")
struct WriteGateTests {
    private static func hooks(_ name: String, _ activity: AgentActivity) -> WriteGate.Agent {
        WriteGate.Agent(name: name, source: .hooks, activity: activity)
    }

    private static func process(_ name: String) -> WriteGate.Agent {
        WriteGate.Agent(name: name, source: .process)
    }

    private static func caution(_ gate: WriteGate) -> String? {
        if case .caution(let text) = gate { return text }
        return nil
    }

    @Test func noAgentsLeaveItClear() {
        #expect(WriteGate([]) == .clear)
        #expect(WriteGate([]).refusal == nil)
    }

    static let midTurn: [AgentActivity] = [
        .working(tool: "Edit", detail: "Sources/Cart.swift"),
        .working(tool: nil, detail: nil),
        .needsPermission(tool: "Bash", detail: "swift test"),
        .askedQuestion(detail: "Which tax table?"),
    ]

    @Test(arguments: midTurn)
    func anAgentMidTurnRefuses(_ activity: AgentActivity) throws {
        let reason = try #require(WriteGate([Self.hooks("Claude Code", activity)]).refusal)
        #expect(reason.hasPrefix("Claude Code is "))
        #expect(reason.contains("until the turn ends"))
    }

    @Test func waitingOnYouSaysItGoesOnEditing() throws {
        let reason = try #require(WriteGate([Self.hooks("Codex", .needsPermission(tool: "Bash", detail: nil))]).refusal)
        #expect(reason.contains("waiting on you"))
    }

    @Test func betweenTurnsIsACaution() throws {
        let gate = WriteGate([Self.hooks("Claude Code", .ready)])
        #expect(gate.refusal == nil)
        let text = try #require(Self.caution(gate))
        #expect(text.contains("Claude Code is between turns"))
    }

    @Test func aProcessIsACautionWhateverItsActivitySays() throws {
        let gate = WriteGate([WriteGate.Agent(name: "Codex", source: .process, activity: .working(tool: nil, detail: nil))])
        #expect(gate.refusal == nil)
        let text = try #require(Self.caution(gate))
        #expect(text.contains("can't tell whether it's in the middle of a turn"))
    }

    @Test func anEndedSessionStillRunningIsACaution() throws {
        let text = try #require(Self.caution(WriteGate([Self.hooks("Hermes", .idle)])))
        #expect(text.hasPrefix("Hermes is running"))
    }

    @Test func oneAgentMidTurnRefusesWhereverItIsListed() throws {
        let agents = [Self.hooks("Claude Code", .ready), Self.process("Codex"), Self.hooks("Hermes", .working(tool: nil, detail: nil))]
        for order in [agents, agents.reversed()] {
            let reason = try #require(WriteGate(order).refusal)
            #expect(reason.hasPrefix("Hermes "))
        }
    }

    @Test func notKnowingComesBeforeBetweenTurns() throws {
        let text = try #require(Self.caution(WriteGate([Self.hooks("Claude Code", .ready), Self.process("Codex")])))
        #expect(text.hasPrefix("Codex is running"))
    }
}
