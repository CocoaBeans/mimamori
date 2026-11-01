import Foundation
import Testing
@testable import VigilCore

@Suite("Widget snapshot")
struct AgentWidgetSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func survivesTheTripThroughTheSharedFile() throws {
        let snapshot = AgentWidgetSnapshot(writtenAt: now, agents: [
            .init(worktreePath: "/repo/plan", repository: "harbor", worktree: "plan", agent: "Codex", state: .needsYou,
                  status: "needs permission · Bash", since: now.addingTimeInterval(-90), task: "Plan the release",
                  steps: [.init(tool: "Bash", target: "rm -rf dist", running: true)], others: 1,
                  collision: "Codex and Cursor Agent both edited PLAN.md"),
            .init(worktreePath: "/repo", repository: "harbor", worktree: "main", agent: "Claude Code", state: .working,
                  status: "working · Edit", since: now.addingTimeInterval(-20)),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widgets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try snapshot.encoded().write(to: url)
        let loaded = try #require(AgentWidgetSnapshot.load(from: url))
        #expect(loaded == snapshot)
        #expect(loaded.needingYou == 1)
        #expect(loaded.working == 1)
        #expect(AgentWidgetSnapshot.load(from: url.appendingPathExtension("missing")) == nil)
    }

    @Test func isCurrentOnlyWhileVigilKeepsItSo() {
        #expect(AgentWidgetSnapshot(writtenAt: now).isCurrent(at: now.addingTimeInterval(60)))
        #expect(!AgentWidgetSnapshot(writtenAt: now).isCurrent(at: now.addingTimeInterval(AgentWidgetSnapshot.staleAfter + 1)))
        #expect(!AgentWidgetSnapshot(writtenAt: now, vigilRunning: false).isCurrent(at: now))
    }

    @Test func linksRoundTripAWorktreePath() throws {
        let path = "/Users/me/Development/My Project/worktrees/feature #2"
        let link = AgentWidgetSnapshot.link(to: path)
        #expect(link.scheme == "vigil")
        #expect(AgentWidgetSnapshot.worktree(in: link) == path)
        #expect(AgentWidgetSnapshot.worktree(in: try #require(URL(string: "vigil://worktree?path=relative"))) == nil)
        #expect(AgentWidgetSnapshot.worktree(in: try #require(URL(string: "https://example.com/worktree?path=/x"))) == nil)
    }
}
