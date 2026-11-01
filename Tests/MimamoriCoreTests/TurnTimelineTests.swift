import Foundation
import Testing
@testable import MimamoriCore

@Suite("Turn timeline")
struct TurnTimelineTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func call(_ id: String, _ tool: String, at seconds: Double, for length: Double?, failed: Bool = false) -> AgentToolCall {
        AgentToolCall(id: id, toolName: tool, summary: nil, filePath: nil, startedAt: start.addingTimeInterval(seconds),
                      finishedAt: length.map { start.addingTimeInterval(seconds + $0) }, failed: failed)
    }

    @Test func placesEachCallAlongTheTurn() throws {
        let timeline = TurnTimeline(calls: [call("a", "Read", at: 0, for: 10), call("b", "Edit", at: 50, for: 10),
                                            call("c", "Bash", at: 80, for: nil)],
                                    turnStartedAt: start, end: start.addingTimeInterval(100))
        #expect(timeline.duration == 100)
        #expect(timeline.marks.map { ($0.start * 1000).rounded() } == [0, 500, 800])
        #expect(timeline.marks.map { ($0.length * 1000).rounded() } == [100, 100, 200])
        #expect(timeline.marks.map(\.category) == [.read, .edit, .command])
        #expect(timeline.marks.map(\.running) == [false, false, true])
        // A call still running: the agent is not quiet.
        #expect(timeline.quietFor == nil)
        #expect(AgentToolCategory.describe(timeline.counts) == "1 edit, 1 command, 1 read")
    }

    @Test func measuresTheSilenceAfterTheLastCall() {
        let timeline = TurnTimeline(calls: [call("a", "Edit", at: 0, for: 5, failed: true), call("b", "Grep", at: 10, for: 2)],
                                    turnStartedAt: start, end: start.addingTimeInterval(252))
        #expect(timeline.quietFor == 240)
        #expect(timeline.marks.first?.failed == true)
        // No calls yet: quiet since the turn began.
        let empty = TurnTimeline(calls: [], turnStartedAt: start, end: start.addingTimeInterval(30))
        #expect(empty.isEmpty)
        #expect(empty.quietFor == 30)
    }

    @Test func marksTheCallWaitingOnYou() {
        let timeline = TurnTimeline(calls: [call("a", "Edit", at: 0, for: 5), call("b", "Bash", at: 10, for: nil)],
                                    turnStartedAt: start, end: start.addingTimeInterval(60), waitingCallID: "b")
        #expect(timeline.marks.map(\.waiting) == [false, true])
        #expect(timeline.marks.map(\.running) == [false, false])
    }

    @Test func startsAtTheFirstKeptCallWhenEarlierOnesWereDropped() {
        let timeline = TurnTimeline(calls: [call("x", "Edit", at: 200, for: 10), call("y", "Edit", at: 300, for: 10)],
                                    turnStartedAt: start, end: start.addingTimeInterval(400), totalCalls: 250)
        #expect(timeline.missedCalls == 248)
        #expect(timeline.duration == 200)
        #expect(timeline.marks.first?.start == 0)
    }

    @Test func keepsMarksInsideTheStrip() {
        // A call from before the turn (a clock skew) and one past the end stay within 0…1.
        let timeline = TurnTimeline(calls: [call("early", "Read", at: -20, for: 30), call("late", "Bash", at: 90, for: 50)],
                                    turnStartedAt: start, end: start.addingTimeInterval(100))
        for mark in timeline.marks {
            #expect(mark.start >= 0 && mark.start + mark.length <= 1.000_001)
        }
    }
}
