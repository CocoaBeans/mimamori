import Foundation

/// Which Hermes session each turn's task belongs to.
///
/// A tool Hermes runs from `execute_code` reports through its hooks with no session, only the
/// task of the turn that ran the code. Filed under no session, it read as a second Hermes at
/// work, and its edits as that second Hermes editing the session's files. The turn's own tool
/// calls name both its session and its task, and `execute_code` itself is one of them, so the
/// task is known by the time the calls it runs report.
public struct HermesTaskSessions: Sendable {
    /// Tasks remembered; a turn has one, so this covers many turns across sessions.
    public static let capacity = 64

    private var sessions: [String: String] = [:]
    /// Tasks, the least recently seen first.
    private var order: [String] = []

    public init() {}

    /// Remembers the session of a Hermes event that names its task, and gives one that names
    /// only a task it knows that task's session.
    public mutating func resolve(_ event: inout HookEvent) {
        guard event.agent == .hermes, let task = event.hermesTaskID else { return }
        if let session = event.sessionID {
            remember(task: task, session: session)
        } else if let session = sessions[task] {
            event.sessionID = session
        }
    }

    public func session(forTask task: String) -> String? { sessions[task] }

    private mutating func remember(task: String, session: String) {
        if sessions.updateValue(session, forKey: task) != nil {
            order.removeAll { $0 == task }
        }
        order.append(task)
        if order.count > Self.capacity {
            sessions.removeValue(forKey: order.removeFirst())
        }
    }
}
