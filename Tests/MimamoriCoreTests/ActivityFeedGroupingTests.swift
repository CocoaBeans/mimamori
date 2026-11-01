import Foundation
import Testing
@testable import MimamoriCore

@Suite("Activity feed grouping")
struct ActivityFeedGroupingTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// Noon, so a few minutes either way stay on the same day.
    private let noon = Date(timeIntervalSince1970: 1_800_014_400)

    private func tool(_ agent: String, _ tool: String, _ path: String? = nil, at minutes: Double, in worktree: String = "/w2") -> ActivityEntry {
        ActivityEntry(date: noon.addingTimeInterval(minutes * 60), worktreePath: worktree, kind: .agentTool, path: path,
                      title: "\(agent): \(tool)", agent: agent)
    }

    private func change(_ path: String, by agent: String?, at minutes: Double, in worktree: String = "/w2") -> ActivityEntry {
        ActivityEntry(date: noon.addingTimeInterval(minutes * 60), worktreePath: worktree, kind: .modified, path: path,
                      title: path, agent: agent)
    }

    private func runs(_ items: [ActivityFeedItem]) -> [AgentRun] {
        items.compactMap { if case .run(let run) = $0 { run } else { nil } }
    }

    private func entries(_ items: [ActivityFeedItem]) -> [ActivityEntry] {
        items.compactMap { if case .entry(let entry) = $0 { entry } else { nil } }
    }

    @Test func foldsAnAgentsToolCallsAndTheirChanges() throws {
        // Newest first, as the feed keeps them.
        let feed = [
            tool("Codex", "Bash", at: 3),
            change("Sources/b.swift", by: "Codex", at: 2.5),
            tool("Codex", "apply_patch", "Sources/b.swift", at: 2),
            tool("Codex", "Edit", "Sources/a.swift", at: 1),
        ]
        let items = ActivityFeedGrouping.items(feed, calendar: calendar)
        let run = try #require(runs(items).first)
        #expect(runs(items).count == 1)
        #expect(entries(items).isEmpty)
        #expect(run.agent == "Codex")
        #expect(run.entries.count == 4)
        #expect(run.summary == "2 edits, 1 command")
        #expect(run.files == ["Sources/b.swift", "Sources/a.swift"])
        #expect(run.startedAt == noon.addingTimeInterval(60))
        #expect(run.latestAt == noon.addingTimeInterval(180))
    }

    @Test func otherThingsBreakARun() {
        let turnEnded = ActivityEntry(date: noon.addingTimeInterval(4 * 60), worktreePath: "/w2", kind: .agentTurn,
                                      title: "Codex finished a turn", agent: "Codex")
        let flag = ActivityEntry(date: noon.addingTimeInterval(2.5 * 60), worktreePath: "/w2", kind: .flagged,
                                 title: "Secrets file edited", severity: .warning)
        let feed = [
            tool("Codex", "Edit", at: 5), tool("Codex", "Edit", at: 4.5),   // after the turn: a run of its own
            turnEnded,
            tool("Codex", "Edit", at: 3), tool("Codex", "Edit", at: 2.8),
            flag,
            tool("Codex", "Edit", at: 2), tool("Claude Code", "Edit", at: 1.9),   // another agent
            tool("Codex", "Edit", at: 1.8, in: "/w3"),                           // another worktree
            tool("Codex", "Edit", at: -10), tool("Codex", "Edit", at: -20),       // ten minutes apart
        ]
        let items = ActivityFeedGrouping.items(feed, calendar: calendar)
        #expect(runs(items).map(\.entries.count) == [2, 2])
        #expect(entries(items).map(\.title) == ["Codex finished a turn", "Secrets file edited", "Codex: Edit", "Claude Code: Edit",
                                                "Codex: Edit", "Codex: Edit", "Codex: Edit"])
    }

    @Test func aLoneCallOrChangesAloneStayAsTheyAre() {
        let items = ActivityFeedGrouping.items([
            tool("Codex", "Edit", at: 3),
            ActivityEntry(date: noon.addingTimeInterval(120), worktreePath: "/w2", kind: .committed, title: "Commit"),
            change("a.swift", by: "Codex", at: 1), change("b.swift", by: "Codex", at: 0.5),
            change("c.swift", by: nil, at: 0.2), change("d.swift", by: nil, at: 0.1),
        ], calendar: calendar)
        #expect(runs(items).isEmpty)
        #expect(entries(items).count == 6)
    }

    @Test func aRunKeepsItsIdentityAsItGrows() throws {
        let first = [tool("Codex", "Edit", at: 1), tool("Codex", "Edit", at: 0)]
        let before = try #require(runs(ActivityFeedGrouping.items(first, calendar: calendar)).first)
        let after = try #require(runs(ActivityFeedGrouping.items([tool("Codex", "Bash", at: 2)] + first, calendar: calendar)).first)
        #expect(before.id == after.id)
        #expect(after.entries.count == 3)
    }

    @Test func separatesDays() {
        let yesterday = noon.addingTimeInterval(-86_400)
        let feed = [
            tool("Codex", "Edit", at: 1), tool("Codex", "Edit", at: 0),
            ActivityEntry(date: yesterday, worktreePath: "/w2", kind: .committed, title: "Commit"),
        ]
        let items = ActivityFeedGrouping.items(feed, calendar: calendar)
        let days = items.compactMap { if case .day(let day) = $0 { day } else { nil } }
        #expect(days == [calendar.startOfDay(for: noon), calendar.startOfDay(for: yesterday)])
        if case .day = items[0] {} else { Issue.record("The first item is the first day's header") }
        #expect(items.count == 4)
    }
}
