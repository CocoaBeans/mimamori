import Foundation

extension AgentToolCategory {
    /// "4 edits, 2 commands, 1 read": counts of steps by kind, edits first.
    public static func describe(_ counts: [AgentToolCategory: Int]) -> String {
        let order: [(AgentToolCategory, String, String)] = [
            (.edit, "edit", "edits"), (.command, "command", "commands"), (.read, "read", "reads"),
            (.search, "search", "searches"), (.web, "web lookup", "web lookups"), (.subagent, "subagent", "subagents"),
            (.question, "question", "questions"), (.other, "other step", "other steps"),
        ]
        return order.compactMap { category, one, many in
            counts[category].flatMap { $0 > 0 ? ($0 == 1 ? "1 \(one)" : "\($0) \(many)") : nil }
        }.joined(separator: ", ")
    }
}

/// A turn's tool calls laid out along its time, to draw as a strip: where each call starts and
/// how much of the turn it ran for, and how long the agent has gone without one. Gaps show a
/// turn's rhythm; a long one at the end, an agent gone quiet.
public struct TurnTimeline: Equatable, Sendable {
    public struct Mark: Equatable, Sendable, Identifiable {
        public var id: String
        public var category: AgentToolCategory
        /// Where it starts and how much of the turn it covers, each 0…1.
        public var start: Double
        public var length: Double
        public var running: Bool
        /// Waiting for your permission rather than running.
        public var waiting: Bool
        public var failed: Bool
    }

    /// Oldest first.
    public var marks: [Mark]
    /// From the turn's start (or its first known call) to its end, or to now while it runs.
    public var duration: TimeInterval
    /// How long since the last call finished, while none is running.
    public var quietFor: TimeInterval?
    /// The calls before these were dropped: an agent's record keeps the latest ones only.
    public var missedCalls: Int
    public var counts: [AgentToolCategory: Int]

    /// `calls` oldest first; `end` is now for a turn under way, or when the turn ended.
    /// `totalCalls` is how many the turn made, when more than `calls` holds; `waitingCallID` the
    /// call waiting for your permission.
    public init(calls: [AgentToolCall], turnStartedAt: Date?, end: Date, totalCalls: Int? = nil, waitingCallID: String? = nil) {
        missedCalls = max(0, (totalCalls ?? calls.count) - calls.count)
        // With calls missing, the record starts at the first one it kept.
        let start = (missedCalls > 0 ? calls.first?.startedAt : turnStartedAt ?? calls.first?.startedAt) ?? end
        duration = max(end.timeIntervalSince(start), 1)
        let span = duration
        func fraction(_ date: Date) -> Double { min(1, max(0, date.timeIntervalSince(start) / span)) }
        marks = calls.map { call in
            let from = fraction(call.startedAt)
            return Mark(id: call.id, category: call.category, start: from,
                        length: max(0, fraction(call.finishedAt ?? end) - from),
                        running: call.finishedAt == nil && call.id != waitingCallID,
                        waiting: call.finishedAt == nil && call.id == waitingCallID, failed: call.failed)
        }
        if calls.contains(where: { $0.finishedAt == nil }) {
            quietFor = nil
        } else {
            let last = calls.compactMap(\.finishedAt).max() ?? start
            quietFor = max(0, end.timeIntervalSince(last))
        }
        counts = calls.reduce(into: [:]) { $0[$1.category, default: 0] += 1 }
    }

    public var isEmpty: Bool { marks.isEmpty }
}
