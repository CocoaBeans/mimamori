import Foundation

/// How Mimamori answers a permission request.
public enum PermissionAnswer: Sendable, Equatable {
    case allow, deny

    /// What a Claude Code `PermissionRequest` hook prints to make the decision.
    public var hookResponse: String {
        switch self {
        case .allow:
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        case .deny:
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied in Mimamori."}}}"#
        }
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

    /// Blocks until `id` is answered or let go, or `timeout` passes. Nil: no decision.
    func wait(_ id: String, timeout: TimeInterval) -> PermissionAnswer? {
        guard let semaphore = lock.withLock({ waiting[id]?.semaphore }) else { return nil }
        _ = semaphore.wait(timeout: .now() + timeout)
        return lock.withLock { waiting.removeValue(forKey: id)?.answer }
    }

    /// Answers `id`; nil lets it go with no decision, leaving it to the agent's own prompt. Only
    /// the first answer counts.
    public func answer(_ id: String, _ answer: PermissionAnswer?) {
        lock.withLock {
            guard var entry = waiting[id], !entry.settled else { return }
            entry.answer = answer
            entry.settled = true
            waiting[id] = entry
            entry.semaphore.signal()
        }
    }

    /// Requests still waiting, for tests.
    var openCount: Int { lock.withLock { waiting.values.filter { !$0.settled }.count } }
}
