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

    private let questions: [String: Set<String>] = ["req-1": ["Which color?", "Which fruits?"]]

    @Test func aPhonesAnswersToEveryQuestionAreTaken() {
        let answers = ["Which color?": "Blue", "Which fruits?": "Pear, Plum"]
        let answered = CompanionMessage.Answer(requestID: "req-1", allow: true, answers: answers)
        #expect(CompanionAnswerCheck.verdict(for: answered, pairingID: "pairing-1", phones: phones, answering: true,
                                             pending: ["req-1"], questions: questions)
                == .answers(requestID: "req-1", answers: answers, phone: "Kevin's iPhone"))
    }

    @Test func partialEmptyOrMissingAnswersAreTurnedDown() {
        func check(_ answer: CompanionMessage.Answer, asked: [String: Set<String>]) -> CompanionAnswerCheck.Verdict {
            CompanionAnswerCheck.verdict(for: answer, pairingID: "pairing-1", phones: phones, answering: true,
                                         pending: ["req-1"], questions: asked)
        }
        let partial = CompanionMessage.Answer(requestID: "req-1", allow: true, answers: ["Which color?": "Blue"])
        let empty = CompanionMessage.Answer(requestID: "req-1", allow: true, answers: ["Which color?": "Blue", "Which fruits?": " "])
        for answer in [partial, empty] {
            guard case .refuse(let reason) = check(answer, asked: questions) else { Issue.record("accepted \(answer)"); continue }
            #expect(reason.contains("every question"))
        }
        // An older phone can't show questions: its Allow would pass them on unanswered.
        guard case .refuse(let reason) = check(allow, asked: questions) else {
            Issue.record("a bare Allow answered questions")
            return
        }
        #expect(reason.contains("Update Mimamori"))
        // Its Deny still tells the agent no.
        #expect(check(CompanionMessage.Answer(requestID: "req-1", allow: false), asked: questions)
                == .answer(requestID: "req-1", allow: false, phone: "Kevin's iPhone"))
        // Answers for a request that asks nothing are a mistake, not an Allow.
        guard case .refuse = check(CompanionMessage.Answer(requestID: "req-1", allow: true, answers: ["x": "y"]), asked: [:]) else {
            Issue.record("answers were taken as an Allow")
            return
        }
    }

    @Test func answersTravelAndOlderMessagesStillRead() throws {
        // An older phone's answer has no answers.
        let old = try JSONDecoder().decode(CompanionMessage.Answer.self, from: Data(#"{"requestID":"req-1","allow":true}"#.utf8))
        #expect(old == CompanionMessage.Answer(requestID: "req-1", allow: true))
        let new = CompanionMessage.Answer(requestID: "req-1", allow: true, answers: ["Which color?": "Blue"])
        #expect(try JSONDecoder().decode(CompanionMessage.Answer.self, from: JSONEncoder().encode(new)) == new)
        // A request with questions goes to the phone whole; an older Mac's request has none.
        let question = AgentQuestion(question: "Which color?", header: "Color", multiSelect: false,
                                     options: [.init(label: "Red", description: "Warm"), .init(label: "Blue")])
        let request = AgentWidgetSnapshot.PermissionRequest(id: "req-1", tool: "AskUserQuestion", since: now, questions: [question])
        let sent = try JSONDecoder().decode(AgentWidgetSnapshot.PermissionRequest.self, from: JSONEncoder().encode(request))
        #expect(sent.questions == [question])
        let older = #"{"id":"req-1","tool":"Bash","since":800000000}"#
        #expect(try JSONDecoder().decode(AgentWidgetSnapshot.PermissionRequest.self, from: Data(older.utf8)).questions == nil)
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

    @Test func onlyAPairingStillListedCanAnswer() {
        // Proved a pairing that's gone since, such as one removed on the Mac.
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

    @Test func anUnprovedConnectionCantAnswer() {
        // Nil is what the publisher passes until the connection's proof holds, whatever its hello claimed.
        guard case .refuse(let reason) = verdict(allow, pairingID: nil) else {
            Issue.record("An unproved connection answered")
            return
        }
        #expect(reason.contains("hasn't proved"))
    }

    // MARK: Proving the pairing

    private let secret = Data(repeating: 7, count: 32)
    private let otherSecret = Data(repeating: 9, count: 32)
    private let nonce = Data((0..<32).map { UInt8($0) })

    private func proof(_ pairingID: String = "pairing-1", secret: Data? = nil, nonce: Data? = nil,
                       claiming claimed: String? = nil) -> CompanionMessage.Proof {
        let mac = CompanionProof.mac(secret: secret ?? self.secret, nonce: nonce ?? self.nonce, pairingID: pairingID)
        return CompanionMessage.Proof(pairingID: claimed ?? pairingID, mac: mac)
    }

    @Test func aCorrectProofVerifiesTheConnection() {
        var identity = CompanionConnectionIdentity(nonce: nonce)
        #expect(identity.verifiedPairingID == nil)
        #expect(identity.check(proof(), secret: secret) == .verified("pairing-1"))
        #expect(identity.verifiedPairingID == "pairing-1")
        #expect(identity.check(proof(), secret: secret) == .alreadyVerified)
    }

    private func hello(_ pairingID: String = "pairing-1") -> CompanionMessage.Hello {
        CompanionMessage.Hello(pairingID: pairingID, deviceName: "iPhone")
    }

    @Test func aHelloBeforeTheProofWaitsForIt() {
        // The phone says hello at once and proves itself after the challenge.
        var identity = CompanionConnectionIdentity(nonce: nonce)
        #expect(identity.receive(hello()) == nil)
        #expect(identity.releaseHeldHello() == nil)
        #expect(identity.check(proof(), secret: secret) == .verified("pairing-1"))
        #expect(identity.releaseHeldHello() == hello())
        // Once only.
        #expect(identity.releaseHeldHello() == nil)
    }

    @Test func aHelloAfterTheProofCountsAtOnce() {
        var identity = CompanionConnectionIdentity(nonce: nonce)
        #expect(identity.check(proof(), secret: secret) == .verified("pairing-1"))
        #expect(identity.receive(hello()) == hello())
    }

    @Test func aHelloForAnotherPairingNeverCounts() {
        // A paired phone naming another pairing, such as the code on show for a phone pairing now.
        var held = CompanionConnectionIdentity(nonce: nonce)
        #expect(held.receive(hello("pairing-2")) == nil)
        #expect(held.check(proof(), secret: secret) == .verified("pairing-1"))
        #expect(held.releaseHeldHello() == nil)

        var proved = CompanionConnectionIdentity(nonce: nonce)
        #expect(proved.check(proof(), secret: secret) == .verified("pairing-1"))
        #expect(proved.receive(hello("pairing-2")) == nil)
    }

    @Test func aHelloWithoutAProofNeverCounts() {
        var identity = CompanionConnectionIdentity(nonce: nonce)
        #expect(identity.receive(hello()) == nil)
        #expect(identity.check(proof(secret: otherSecret), secret: secret) == .mismatch)
        #expect(identity.releaseHeldHello() == nil)
    }

    @Test func aProofUnderAnotherSecretFails() {
        // Another paired phone's key, which TLS would let in, can't prove this pairing.
        var identity = CompanionConnectionIdentity(nonce: nonce)
        #expect(identity.check(proof(secret: otherSecret), secret: secret) == .mismatch)
        #expect(identity.verifiedPairingID == nil)
    }

    @Test func aMACForOnePairingDoesntProveAnother() {
        // Right for pairing-2's id under pairing-2's secret, sent as pairing-1.
        var identity = CompanionConnectionIdentity(nonce: nonce)
        #expect(identity.check(proof("pairing-2", secret: otherSecret, claiming: "pairing-1"), secret: secret) == .mismatch)
        #expect(!CompanionProof.isValid(proof("pairing-2").mac, secret: secret, nonce: nonce, pairingID: "pairing-1"))
        #expect(identity.verifiedPairingID == nil)
    }

    @Test func aProofForAnotherConnectionsNonceFails() {
        // Replayed from an earlier connection, whose nonce was different.
        let earlier = Data(repeating: 1, count: 32)
        var identity = CompanionConnectionIdentity(nonce: nonce)
        #expect(identity.check(proof(nonce: earlier), secret: secret) == .mismatch)
        #expect(!CompanionProof.isValid(proof().mac, secret: secret, nonce: Data(nonce.prefix(16)), pairingID: "pairing-1"))
    }

    @Test func anUnknownPairingAndASecondPairingAreRefused() {
        var identity = CompanionConnectionIdentity(nonce: nonce)
        #expect(identity.check(proof("pairing-removed"), secret: nil) == .unknownPairing)
        #expect(identity.check(proof(), secret: secret) == .verified("pairing-1"))
        // Verified once, a connection stays that pairing, even with a good proof for another.
        #expect(identity.check(proof("pairing-2", secret: otherSecret), secret: otherSecret) == .conflicting)
        #expect(identity.verifiedPairingID == "pairing-1")
    }

    @Test func eachConnectionGetsAFreshNonce() {
        #expect(CompanionProof.newNonce().count == CompanionProof.nonceLength)
        #expect(CompanionConnectionIdentity().nonce != CompanionConnectionIdentity().nonce)
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
