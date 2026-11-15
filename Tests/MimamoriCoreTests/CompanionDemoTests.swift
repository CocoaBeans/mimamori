import Foundation
import Testing
@testable import MimamoriShared

/// The sample Macs the iPhone shows: Try the Demo's, for App Review, and the App Store
/// screenshots' own.
@Suite("The companion's demo")
struct CompanionDemoTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let samples: [CompanionDemo.Sample] = [.tryIt, .screenshots]

    /// The agent waiting on `request`, found before anything is answered.
    private func path(of request: String, in demo: CompanionDemo) throws -> String {
        try #require(demo.snapshot(at: start).agents.first { $0.permissionRequest?.id == request }).worktreePath
    }

    private func agent(_ snapshot: AgentWidgetSnapshot, _ path: String) throws -> AgentWidgetSnapshot.Agent {
        try #require(snapshot.agents.first { $0.worktreePath == path })
    }

    @Test(arguments: samples)
    func showsAnAgentInEveryGroup(_ sample: CompanionDemo.Sample) {
        let snapshot = CompanionDemo(start: start, sample: sample).snapshot(at: start)
        #expect(snapshot.needingYou == 2)
        #expect(snapshot.working == 1)
        #expect(snapshot.agents.contains { $0.state == .ready })
        #expect(snapshot.agents.contains { $0.state == .ended })
        // One request to allow, one with questions to answer.
        let requests = snapshot.agents.compactMap(\.permissionRequest)
        #expect(Set(requests.map(\.id)) == [CompanionDemo.commandRequest, CompanionDemo.questionRequest])
        #expect(requests.contains { $0.questions?.isEmpty == false })
        // Each waiting card marks the call it waits on.
        for waiting in snapshot.agents where waiting.state == .needsYou {
            let card = waiting.card
            #expect(card?.calls.contains { $0.id == card?.waitingCallID && $0.finishedAt == nil } == true)
        }
        #expect(Set(snapshot.agents.map(\.id)).count == snapshot.agents.count)
    }

    @Test(arguments: samples)
    func allowedAgentWorksThenFinishes(_ sample: CompanionDemo.Sample) throws {
        var demo = CompanionDemo(start: start, sample: sample)
        let path = try path(of: CompanionDemo.commandRequest, in: demo)
        let answeredAt = start.addingTimeInterval(10)
        #expect(demo.answer(requestID: CompanionDemo.commandRequest, allow: true, at: answeredAt) == nil)

        let working = try agent(demo.snapshot(at: answeredAt.addingTimeInterval(1)), path)
        #expect(working.state == .working)
        #expect(working.permissionRequest == nil)
        #expect(working.card?.waitingCallID == nil)
        #expect(working.card?.turnUnderway == true)

        let done = try agent(demo.snapshot(at: answeredAt.addingTimeInterval(CompanionDemo.workDuration + 1)), path)
        #expect(done.state == .ready)
        #expect(done.since == answeredAt.addingTimeInterval(CompanionDemo.workDuration))
        #expect(done.card?.turnUnderway == false)
        #expect(done.card?.lastCall?.failed == false)
        #expect(done.card?.lastCall?.finishedAt != nil)
    }

    @Test(arguments: samples)
    func deniedAgentStopsAtOnce(_ sample: CompanionDemo.Sample) throws {
        var demo = CompanionDemo(start: start, sample: sample)
        let path = try path(of: CompanionDemo.commandRequest, in: demo)
        let answeredAt = start.addingTimeInterval(5)
        #expect(demo.answer(requestID: CompanionDemo.commandRequest, allow: false, at: answeredAt) == nil)
        let stopped = try agent(demo.snapshot(at: answeredAt), path)
        #expect(stopped.state == .ready)
        #expect(stopped.card?.lastCall?.failed == true)
    }

    @Test(arguments: samples)
    func answeredQuestionLeadsToAnEdit(_ sample: CompanionDemo.Sample) throws {
        var demo = CompanionDemo(start: start, sample: sample)
        let path = try path(of: CompanionDemo.questionRequest, in: demo)
        let answeredAt = start.addingTimeInterval(3)
        #expect(demo.answer(requestID: CompanionDemo.questionRequest, allow: true, at: answeredAt) == nil)
        let working = try agent(demo.snapshot(at: answeredAt.addingTimeInterval(2)), path)
        #expect(working.state == .working)
        #expect(working.steps.first?.tool == "Edit")
        #expect(working.steps.first?.running == true)
        let done = try agent(demo.snapshot(at: answeredAt.addingTimeInterval(CompanionDemo.workDuration)), path)
        #expect(done.state == .ready)
        #expect(done.card?.calls.allSatisfy { $0.finishedAt != nil } == true)
    }

    @Test func takesEachAnswerOnce() {
        var demo = CompanionDemo(start: start)
        #expect(demo.answer(requestID: CompanionDemo.commandRequest, allow: true, at: start) == nil)
        #expect(demo.answer(requestID: CompanionDemo.commandRequest, allow: false, at: start) != nil)
        #expect(demo.answer(requestID: "someone-elses", allow: true, at: start) != nil)
    }

    @Test(arguments: samples)
    func everyAgentHasItsActions(_ sample: CompanionDemo.Sample) throws {
        let demo = CompanionDemo(start: start, sample: sample)
        for agent in demo.snapshot(at: start).agents {
            let actions = try #require(demo.actions(for: agent.worktreePath, at: start))
            #expect(actions.agent == agent.agent)
            #expect(actions.waitingCallID == agent.card?.waitingCallID)
            // Newest turn first, and its calls newest first.
            let starts = actions.turns.compactMap(\.startedAt)
            #expect(starts == starts.sorted(by: >))
            for turn in actions.turns {
                #expect(turn.calls.map(\.startedAt) == turn.calls.map(\.startedAt).sorted(by: >))
                #expect(Set(turn.calls.map(\.id)).count == turn.calls.count)
            }
        }
        #expect(demo.actions(for: "/nowhere", at: start) == nil)
    }

    /// The cards stay put between changes, so the phone redraws only when something happens.
    @Test(arguments: samples)
    func snapshotsChangeOnlyWithTheAgents(_ sample: CompanionDemo.Sample) {
        let demo = CompanionDemo(start: start, sample: sample)
        let early = demo.snapshot(at: start.addingTimeInterval(1))
        let later = demo.snapshot(at: start.addingTimeInterval(60))
        #expect(early.agents == later.agents)
    }

    /// Trying the demo doesn't replay the App Store's screenshots: another Mac, other work.
    @Test func theScreenshotsTellAnotherStory() {
        let tryIt = CompanionDemo(start: start, sample: .tryIt)
        let screenshots = CompanionDemo(start: start, sample: .screenshots)
        #expect(tryIt.macName != screenshots.macName)
        let demoAgents = tryIt.snapshot(at: start).agents
        let shotAgents = screenshots.snapshot(at: start).agents
        #expect(Set(demoAgents.map(\.repository)).isDisjoint(with: shotAgents.map(\.repository)))
        #expect(Set(demoAgents.compactMap(\.task)).isDisjoint(with: shotAgents.compactMap(\.task)))
        let questions = { (agents: [AgentWidgetSnapshot.Agent]) in
            Set(agents.compactMap(\.permissionRequest).flatMap { $0.questions ?? [] }.map(\.question))
        }
        #expect(questions(demoAgents).isDisjoint(with: questions(shotAgents)))
    }
}
