import Foundation
import Testing
@testable import MimamoriShared

/// The sample Mac the iPhone's demo shows, for App Review and screenshots.
@Suite("The companion's demo")
struct CompanionDemoTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func agent(_ snapshot: AgentWidgetSnapshot, _ path: String) throws -> AgentWidgetSnapshot.Agent {
        try #require(snapshot.agents.first { $0.worktreePath == path })
    }

    @Test func showsAnAgentInEveryGroup() {
        let snapshot = CompanionDemo(start: start).snapshot(at: start)
        #expect(snapshot.needingYou == 2)
        #expect(snapshot.working == 1)
        #expect(snapshot.agents.contains { $0.state == .ready })
        #expect(snapshot.agents.contains { $0.state == .ended })
        // One request to allow, one with questions to answer.
        let requests = snapshot.agents.compactMap(\.permissionRequest)
        #expect(Set(requests.map(\.id)) == [CompanionDemo.applePayRequest, CompanionDemo.rateLimitRequest])
        #expect(requests.contains { $0.questions?.isEmpty == false })
        // Each waiting card marks the call it waits on.
        for waiting in snapshot.agents where waiting.state == .needsYou {
            let card = waiting.card
            #expect(card?.calls.contains { $0.id == card?.waitingCallID && $0.finishedAt == nil } == true)
        }
    }

    @Test func allowedAgentWorksThenFinishes() throws {
        var demo = CompanionDemo(start: start)
        let answeredAt = start.addingTimeInterval(10)
        #expect(demo.answer(requestID: CompanionDemo.applePayRequest, allow: true, at: answeredAt) == nil)

        let working = try agent(demo.snapshot(at: answeredAt.addingTimeInterval(1)), CompanionDemo.applePayPath)
        #expect(working.state == .working)
        #expect(working.permissionRequest == nil)
        #expect(working.card?.waitingCallID == nil)
        #expect(working.card?.turnUnderway == true)

        let done = try agent(demo.snapshot(at: answeredAt.addingTimeInterval(CompanionDemo.workDuration + 1)), CompanionDemo.applePayPath)
        #expect(done.state == .ready)
        #expect(done.since == answeredAt.addingTimeInterval(CompanionDemo.workDuration))
        #expect(done.card?.turnUnderway == false)
        #expect(done.card?.lastCall?.failed == false)
        #expect(done.card?.lastCall?.finishedAt != nil)
    }

    @Test func deniedAgentStopsAtOnce() throws {
        var demo = CompanionDemo(start: start)
        let answeredAt = start.addingTimeInterval(5)
        #expect(demo.answer(requestID: CompanionDemo.applePayRequest, allow: false, at: answeredAt) == nil)
        let stopped = try agent(demo.snapshot(at: answeredAt), CompanionDemo.applePayPath)
        #expect(stopped.state == .ready)
        #expect(stopped.card?.lastCall?.failed == true)
    }

    @Test func answeredQuestionLeadsToAnEdit() throws {
        var demo = CompanionDemo(start: start)
        let answeredAt = start.addingTimeInterval(3)
        #expect(demo.answer(requestID: CompanionDemo.rateLimitRequest, allow: true, at: answeredAt) == nil)
        let working = try agent(demo.snapshot(at: answeredAt.addingTimeInterval(2)), CompanionDemo.rateLimitPath)
        #expect(working.state == .working)
        #expect(working.steps.first?.tool == "Edit")
        #expect(working.steps.first?.running == true)
        let done = try agent(demo.snapshot(at: answeredAt.addingTimeInterval(CompanionDemo.workDuration)), CompanionDemo.rateLimitPath)
        #expect(done.state == .ready)
        #expect(done.card?.calls.allSatisfy { $0.finishedAt != nil } == true)
    }

    @Test func takesEachAnswerOnce() {
        var demo = CompanionDemo(start: start)
        #expect(demo.answer(requestID: CompanionDemo.applePayRequest, allow: true, at: start) == nil)
        #expect(demo.answer(requestID: CompanionDemo.applePayRequest, allow: false, at: start) != nil)
        #expect(demo.answer(requestID: "someone-elses", allow: true, at: start) != nil)
    }

    @Test func everyAgentHasItsActions() throws {
        let demo = CompanionDemo(start: start)
        for agent in demo.snapshot(at: start).agents {
            let actions = try #require(demo.actions(for: agent.worktreePath, at: start))
            #expect(actions.agent == agent.agent)
            #expect(actions.waitingCallID == agent.card?.waitingCallID)
            // Newest turn first, and its calls newest first.
            let starts = actions.turns.compactMap(\.startedAt)
            #expect(starts == starts.sorted(by: >))
            for turn in actions.turns {
                #expect(turn.calls.map(\.startedAt) == turn.calls.map(\.startedAt).sorted(by: >))
            }
        }
        #expect(demo.actions(for: "/nowhere", at: start) == nil)
    }

    /// The cards stay put between changes, so the phone redraws only when something happens.
    @Test func snapshotsChangeOnlyWithTheAgents() {
        let demo = CompanionDemo(start: start)
        let early = demo.snapshot(at: start.addingTimeInterval(1))
        let later = demo.snapshot(at: start.addingTimeInterval(60))
        #expect(early.agents == later.agents)
    }
}
