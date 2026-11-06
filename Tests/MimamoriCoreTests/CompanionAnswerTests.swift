import Foundation
import Testing
@testable import MimamoriCore

@Suite("Companion answers")
struct CompanionAnswerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let phones = ["pairing-1": "Kevin's iPhone"]
    private let allow = CompanionMessage.Answer(requestID: "req-1", allow: true)

    private func verdict(_ answer: CompanionMessage.Answer, pairingID: String? = "pairing-1", answering: Bool = true,
                         pending: Set<String> = ["req-1"]) -> CompanionAnswerCheck.Verdict {
        CompanionAnswerCheck.verdict(for: answer, pairingID: pairingID, phones: phones, answering: answering, pending: pending)
    }

    @Test func aPairedPhoneSettlesAWaitingRequest() {
        #expect(verdict(allow) == .answer(requestID: "req-1", allow: true, phone: "Kevin's iPhone"))
        let deny = CompanionMessage.Answer(requestID: "req-1", allow: false)
        #expect(verdict(deny) == .answer(requestID: "req-1", allow: false, phone: "Kevin's iPhone"))
    }

    @Test func anAnswerToARequestNoLongerWaitingChangesNothing() {
        // Answered on the Mac first, or by its own prompt: the phone's answer comes too late.
        guard case .refuse(let reason) = verdict(allow, pending: []) else {
            Issue.record("A stale answer was accepted")
            return
        }
        #expect(reason.contains("no longer waits"))
        // Another request waits, but the answer names a different one.
        guard case .refuse = verdict(allow, pending: ["req-2"]) else {
            Issue.record("An answer settled a request it didn't name")
            return
        }
    }

    @Test func onlyAPairedPhoneThatSaidWhoItIsCanAnswer() {
        guard case .refuse = verdict(allow, pairingID: nil) else {
            Issue.record("A phone that hadn't said hello answered")
            return
        }
        // Holds a key TLS took, but names a pairing that's gone, such as one removed on the Mac.
        guard case .refuse(let reason) = verdict(allow, pairingID: "pairing-removed") else {
            Issue.record("An unpaired phone answered")
            return
        }
        #expect(reason.contains("isn't paired"))
    }

    @Test func nothingIsAnsweredWhileMimamoriDoesntAnswerRequests() {
        guard case .refuse(let reason) = verdict(allow, answering: false) else {
            Issue.record("Answered with Answer permission requests in Mimamori off")
            return
        }
        #expect(reason.contains("own prompt"))
    }

    @Test func aLongCommandIsCutForThePhone() {
        #expect(CompanionAnswerCheck.clipped(nil) == nil)
        #expect(CompanionAnswerCheck.clipped("swift test") == "swift test")
        let long = String(repeating: "x", count: CompanionAnswerCheck.detailLimit + 50)
        let clipped = CompanionAnswerCheck.clipped(long)
        #expect(clipped?.count == CompanionAnswerCheck.detailLimit + 1)
        #expect(clipped?.hasSuffix("…") == true)
    }

    private func agent(_ state: AgentWidgetSnapshot.State, request: AgentWidgetSnapshot.PermissionRequest? = nil) -> AgentWidgetSnapshot.Agent {
        .init(worktreePath: "/repo/main", repository: "shop", worktree: "main", agent: "Claude Code", state: state,
              status: "needs permission · Bash", since: now, permissionRequest: request)
    }

    @Test func aRequestComingGoingOrStoppingItsCountdownIsSentAtOnce() {
        let request = AgentWidgetSnapshot.PermissionRequest(id: "req-1", tool: "Bash", detail: "make deploy", since: now,
                                                            autoAnswer: .init(allow: false, at: now.addingTimeInterval(30)))
        let waiting = CompanionMessage.urgentKeys([agent(.needsYou)])
        let asked = CompanionMessage.urgentKeys([agent(.needsYou, request: request)])
        #expect(waiting != asked)
        var stopped = request
        stopped.autoAnswer = nil
        #expect(CompanionMessage.urgentKeys([agent(.needsYou, request: stopped)]) != asked)
        // Steps changing alone wait for the usual 10 s.
        var stepped = agent(.needsYou, request: request)
        stepped.steps = [.init(tool: "Bash", target: "make deploy", running: true)]
        #expect(CompanionMessage.urgentKeys([stepped]) == asked)
    }
}
