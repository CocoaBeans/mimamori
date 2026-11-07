import Foundation

/// How Mimamori answers a permission request.
public enum PermissionAnswer: Sendable, Equatable {
    case allow, deny
    /// Answers to an AskUserQuestion call: it's allowed with them in its input, and returns them
    /// to the agent. `questions` is the call's `questions`, as JSON, which the input keeps.
    case answers(questions: Data, answers: [String: String])

    /// What a Claude Code `PermissionRequest` hook prints to make the decision.
    public var hookResponse: String {
        switch self {
        case .allow:
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        case .deny:
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied in Mimamori."}}}"#
        case .answers(let questions, let answers):
            Self.answering(questions: questions, answers: answers)
        }
    }

    private static func answering(questions: Data, answers: [String: String]) -> String {
        let asked = (try? JSONSerialization.jsonObject(with: questions)) ?? []
        let decision: [String: Any] = ["behavior": "allow", "updatedInput": ["questions": asked, "answers": answers]]
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Holds an agent's permission request open while its hook waits for an answer from Mimamori.
/// The agent shows its own prompt at the same time, and whichever is answered first counts, so a
/// request is also let go without an answer once the agent has moved on.
public final class PermissionBroker: @unchecked Sendable {
    private struct Waiting {
        let semaphore = DispatchSemaphore(value: 0)
        var answer: PermissionAnswer?
        var settled = false
    }

    private let lock = NSLock()
    private var waiting: [String: Waiting] = [:]

    public init() {}

    func open(_ id: String) {
        lock.withLock { waiting[id] = Waiting() }
    }

    /// How a wait ended.
    struct Outcome: Equatable {
        /// Nil: no decision.
        var answer: PermissionAnswer?
        /// Nobody answered or let it go before the time was up.
        var timedOut: Bool
    }

    /// Blocks until `id` is answered or let go, or `timeout` passes.
    func wait(_ id: String, timeout: TimeInterval) -> Outcome {
        guard let semaphore = lock.withLock({ waiting[id]?.semaphore }) else { return Outcome(answer: nil, timedOut: false) }
        _ = semaphore.wait(timeout: .now() + timeout)
        return lock.withLock {
            let entry = waiting.removeValue(forKey: id)
            return Outcome(answer: entry?.answer, timedOut: entry?.settled == false)
        }
    }

    /// Answers `id`; nil lets it go with no decision, leaving it to the agent's own prompt. Only
    /// the first answer counts: false when `id` was answered already, or never asked.
    @discardableResult
    public func answer(_ id: String, _ answer: PermissionAnswer?) -> Bool {
        lock.withLock {
            guard var entry = waiting[id], !entry.settled else { return false }
            entry.answer = answer
            entry.settled = true
            waiting[id] = entry
            entry.semaphore.signal()
            return true
        }
    }

    /// Requests still waiting, for tests.
    var openCount: Int { lock.withLock { waiting.values.filter { !$0.settled }.count } }
}
