import Foundation

/// The activity feed as it is drawn. A busy agent adds a row for every tool call, which buries
/// everything else, so an agent's run of tool calls in one worktree folds into one row, along
/// with the file changes those calls made. Days are separated.
public enum ActivityFeedItem: Identifiable, Hashable, Sendable {
    /// The start of a day; its entries follow.
    case day(Date)
    case entry(ActivityEntry)
    case run(AgentRun)

    public var id: String {
        switch self {
        case .day(let date): "day-\(Int(date.timeIntervalSince1970))"
        case .entry(let entry): entry.id.uuidString
        case .run(let run): "run-\(run.id.uuidString)"
        }
    }
}

/// One agent's run of tool calls in one worktree, with the file changes they made.
public struct AgentRun: Identifiable, Hashable, Sendable {
    public var agent: String
    public var worktreePath: String
    /// Newest first, as the feed lists them.
    public var entries: [ActivityEntry]

    /// Its first entry's: it stays the same as the run grows, so the row keeps its place and
    /// whether it is open.
    public var id: UUID { entries[entries.count - 1].id }
    public var startedAt: Date { entries[entries.count - 1].date }
    public var latestAt: Date { entries[0].date }
    public var toolCalls: [ActivityEntry] { entries.filter { $0.kind == .agentTool } }

    /// "4 edits, 2 commands, 1 read": its tool calls by kind.
    public var summary: String {
        var counts: [AgentToolCategory: Int] = [:]
        for call in toolCalls { counts[AgentRun.category(of: call), default: 0] += 1 }
        return AgentToolCategory.describe(counts)
    }

    /// The files it touched, the most recent first, each once.
    public var files: [String] {
        var seen = Set<String>()
        return entries.compactMap(\.path).filter { seen.insert($0).inserted }
    }

    /// "Codex: apply_patch" → apply_patch's category.
    static func category(of call: ActivityEntry) -> AgentToolCategory {
        let tool = call.title.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
        return AgentToolCategory(toolName: tool.isEmpty ? call.title : tool)
    }
}

public enum ActivityFeedGrouping {
    /// A pause this long between two of an agent's entries starts a new run.
    public static let maximumGap: TimeInterval = 5 * 60

    private static let changeKinds: Set<ActivityKind> = [.created, .modified, .deleted, .renamed]

    /// `entries` newest first, as the feed keeps them.
    public static func items(_ entries: [ActivityEntry], calendar: Calendar = .current) -> [ActivityFeedItem] {
        var grouped: [ActivityFeedItem] = []
        var run: [ActivityEntry] = []
        var runAgent: String? = nil

        func flush() {
            // A run is worth folding when it holds a tool call and something else.
            if run.count > 1, run.contains(where: { $0.kind == .agentTool }), let agent = runAgent {
                grouped.append(.run(AgentRun(agent: agent, worktreePath: run[0].worktreePath, entries: run)))
            } else {
                grouped += run.map(ActivityFeedItem.entry)
            }
            run = []
            runAgent = nil
        }

        for entry in entries {
            // Tool calls, and file changes traced to them, belong to the agent that made them.
            let agent = entry.kind == .agentTool || changeKinds.contains(entry.kind) ? entry.agent : nil
            if let agent, let last = run.last, agent == runAgent, entry.worktreePath == last.worktreePath,
               last.date.timeIntervalSince(entry.date) < maximumGap {
                run.append(entry)
                continue
            }
            flush()
            if let agent {
                run = [entry]
                runAgent = agent
            } else {
                grouped.append(.entry(entry))
            }
        }
        flush()

        // Day headers before the first item of each day.
        var items: [ActivityFeedItem] = []
        var currentDay: Date? = nil
        for item in grouped {
            let date: Date
            switch item {
            case .entry(let entry): date = entry.date
            case .run(let run): date = run.latestAt
            case .day: continue
            }
            let day = calendar.startOfDay(for: date)
            if day != currentDay {
                items.append(.day(day))
                currentDay = day
            }
            items.append(item)
        }
        return items
    }
}
