import Foundation

/// Which pairing a connection is, once its phone has proved it: the challenge's nonce, and the
/// pairing whose secret answered it. TLS lets in any phone holding a paired key, so without this
/// one paired phone could answer under another's name.
public struct CompanionConnectionIdentity: Sendable {
    public enum Outcome: Equatable, Sendable {
        case verified(String)
        /// The same pairing proved again: nothing changes.
        case alreadyVerified
        /// Proved one pairing already; a connection is only ever one.
        case conflicting
        /// No paired phone has that id.
        case unknownPairing
        /// The MAC isn't that pairing's for this nonce.
        case mismatch
    }

    /// What the phone signs; sent in the connection's challenge.
    public let nonce: Data
    public private(set) var verifiedPairingID: String?
    /// A hello that came before any proof, held until a proof says whether to believe it.
    public private(set) var heldHello: CompanionMessage.Hello?

    public init(nonce: Data = CompanionProof.newNonce()) {
        self.nonce = nonce
    }

    /// Checks `proof` against `secret`, the secret paired under `proof.pairingID`, if any.
    public mutating func check(_ proof: CompanionMessage.Proof, secret: Data?) -> Outcome {
        if let verifiedPairingID {
            return proof.pairingID == verifiedPairingID ? .alreadyVerified : .conflicting
        }
        guard let secret else { return .unknownPairing }
        guard CompanionProof.isValid(proof.mac, secret: secret, nonce: nonce, pairingID: proof.pairingID) else { return .mismatch }
        verifiedPairingID = proof.pairingID
        return .verified(proof.pairingID)
    }

    /// A hello to act on, or nil. Its name and model go in the paired phones' list, and for a
    /// phone pairing now it completes the pairing, so only a hello from the pairing this
    /// connection proved counts. One that comes first is held for the proof; one naming another
    /// pairing is dropped.
    public mutating func receive(_ hello: CompanionMessage.Hello) -> CompanionMessage.Hello? {
        guard let verifiedPairingID else {
            heldHello = hello
            return nil
        }
        return hello.pairingID == verifiedPairingID ? hello : nil
    }

    /// The held hello, once a proof has made it believable: nil until then, or if it named
    /// another pairing than the one proved.
    public mutating func releaseHeldHello() -> CompanionMessage.Hello? {
        guard let verifiedPairingID, let held = heldHello else { return nil }
        heldHello = nil
        return held.pairingID == verifiedPairingID ? held : nil
    }
}

/// Whether Allow or Deny from an iPhone may settle a permission request. Allow runs a command on
/// the Mac, so it counts only from a phone that is paired and proved which pairing it is, while
/// Mimamori answers requests at all, and only for a request that still waits. Anything else, such
/// as an answer to a request already answered on the Mac, is turned down and changes nothing.
public enum CompanionAnswerCheck {
    public enum Verdict: Equatable, Sendable {
        /// Settle the request, recording it as answered on `phone`.
        case answer(requestID: String, allow: Bool, phone: String)
        /// Answer the request's questions with `answers`, recording it as answered on `phone`.
        case answers(requestID: String, answers: [String: String], phone: String)
        /// Leave everything as it is, telling the phone why in a sentence.
        case refuse(String)
    }

    /// - Parameters:
    ///   - pairingID: the pairing the connection proved it is (`CompanionConnectionIdentity`), not
    ///     the one its hello claims; nil before it has.
    ///   - phones: paired phones' names, by pairing id.
    ///   - answering: "Answer permission requests in Mimamori" is on.
    ///   - pending: the ids of the requests waiting for an answer now.
    ///   - questions: the questions' texts of each waiting request that asks some, by its id.
    public static func verdict(for answer: CompanionMessage.Answer, pairingID: String?, phones: [String: String],
                               answering: Bool, pending: Set<String>, questions: [String: Set<String>] = [:]) -> Verdict {
        guard let pairingID else { return .refuse("This iPhone hasn't proved which pairing it is yet. Try again in a moment.") }
        guard let phone = phones[pairingID] else { return .refuse("This iPhone isn't paired with the Mac any more.") }
        guard answering else {
            return .refuse("Mimamori on the Mac doesn't answer permission requests now. Answer in the agent's own prompt.")
        }
        guard pending.contains(answer.requestID) else {
            return .refuse("That request no longer waits: it was answered, or the agent moved on.")
        }
        if let asked = questions[answer.requestID] {
            // Allow alone would pass the questions on unanswered: an older phone's, which can't show them.
            guard let answers = answer.answers else {
                if !answer.allow { return .answer(requestID: answer.requestID, allow: false, phone: phone) }
                return .refuse("Update Mimamori on this iPhone to answer questions, or answer in the agent's own prompt.")
            }
            guard Set(answers.keys) == asked, answers.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                return .refuse("Answer every question, then send them again.")
            }
            return .answers(requestID: answer.requestID, answers: answers, phone: phone)
        }
        guard answer.answers == nil else { return .refuse("That request asks no questions.") }
        return .answer(requestID: answer.requestID, allow: answer.allow, phone: phone)
    }

    /// The longest detail sent to the phone. A command longer than this is cut, and the phone says so.
    public static let detailLimit = 2_000

    /// `detail` as the phone shows it: whole, unless it's longer than `detailLimit`.
    public static func clipped(_ detail: String?) -> String? {
        guard let detail, detail.count > detailLimit else { return detail }
        return String(detail.prefix(detailLimit)) + "…"
    }
}

extension CompanionMessage {
    /// What makes a snapshot worth sending to the phones at once rather than within 10 s: an agent
    /// that needs you or collides, and each request waiting for an answer, so the phone's Allow and
    /// Deny appear, and go, as soon as the Mac's do. Its countdown too: stopped on the Mac, the
    /// phone mustn't go on saying it will answer by itself.
    public static func urgentKeys(_ agents: [AgentWidgetSnapshot.Agent]) -> Set<String> {
        var keys: Set<String> = []
        for agent in agents {
            if agent.state == .needsYou || agent.collision != nil { keys.insert(agent.id) }
            if let request = agent.permissionRequest {
                keys.insert("request:" + request.id + (request.autoAnswer == nil ? "" : ":countdown"))
            }
        }
        return keys
    }
}
