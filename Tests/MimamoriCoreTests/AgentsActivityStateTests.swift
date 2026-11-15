import Foundation
import Testing
@testable import MimamoriCore

@Suite("The companion's Live Activity state")
struct AgentsActivityStateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func agent(_ state: AgentWidgetSnapshot.State, path: String = "/repo/main", task: String? = "Add a cart",
                       steps: [AgentWidgetSnapshot.Step] = [], status: String = "working · Edit") -> AgentWidgetSnapshot.Agent {
        .init(worktreePath: path, repository: "shop", worktree: (path as NSString).lastPathComponent, agent: "Claude Code",
              state: state, status: status, since: now, task: task, steps: steps)
    }

    @Test func countsEveryAgentButShowsTheFirstFewLeavingEndedOnesOut() {
        let snapshot = AgentWidgetSnapshot(writtenAt: now, agents: [
            agent(.needsYou, path: "/repo/a"), agent(.working, path: "/repo/b"), agent(.running, path: "/repo/c"),
            agent(.ended, path: "/repo/d"), agent(.ready, path: "/repo/e"),
        ])
        let state = AgentsActivityState(snapshot: snapshot, connected: true)
        #expect(state.agents.map(\.worktree) == ["a", "b", "c"])
        #expect(state.needingYou == 1)
        #expect(state.working == 2)
        #expect(state.total == 4)
        #expect(state.featured?.worktree == "a")
        #expect(state.summary == "1 needs you · 2 working")
    }

    @Test func summarySaysHowManyWhenNoneNeedYouOrWork() {
        #expect(AgentsActivityState(snapshot: nil, connected: true).summary == "No agents at work")
        let ready = AgentWidgetSnapshot(writtenAt: now, agents: [agent(.ready, path: "/repo/a"), agent(.ready, path: "/repo/b")])
        #expect(AgentsActivityState(snapshot: ready, connected: true).summary == "2 agents")
        let one = AgentWidgetSnapshot(writtenAt: now, agents: [agent(.ready)])
        #expect(AgentsActivityState(snapshot: one, connected: false).summary == "1 agent")
    }

    @Test func rowsKeepTheLatestStepAndOneShortLineOfTask() throws {
        var full = agent(.needsYou, task: "Tidy the cart\nand then the checkout",
                         steps: [.init(tool: "Edit", target: "Cart.swift", running: true), .init(tool: "Bash", target: "swift test")])
        full.card = .init(reportsSteps: true, turnUnderway: true, turnStartedAt: now, callsThisTurn: 2)
        full.permissionRequest = .init(id: "r1", tool: "Bash", detail: "rm -rf build", since: now)
        let state = AgentsActivityState(snapshot: AgentWidgetSnapshot(writtenAt: now, agents: [full]), connected: true)
        let shown = try #require(state.featured)
        #expect(shown.task == "Tidy the cart")
        #expect(shown.steps == [.init(tool: "Edit", target: "Cart.swift", running: true)])
        #expect(shown.card == nil)
        #expect(shown.permissionRequest == nil)

        let long = String(repeating: "x", count: 300)
        let cut = AgentsActivityState(snapshot: AgentWidgetSnapshot(writtenAt: now, agents: [agent(.working, task: long)]),
                                      connected: true)
        #expect(cut.featured?.task?.count == 80)
        #expect(cut.featured?.task?.hasSuffix("…") == true)
    }

    @Test func staysWithinTheBudgetHoweverLongThePaths() {
        let deep = "/" + Array(repeating: String(repeating: "folder", count: 20), count: 12).joined(separator: "/")
        let agents = (0..<3).map { index in
            agent(.working, path: "\(deep)/\(index)", task: String(repeating: "t", count: 200),
                  steps: [.init(tool: "Edit", target: deep)])
        }
        let state = AgentsActivityState(snapshot: AgentWidgetSnapshot(writtenAt: now, agents: agents), connected: true)
        #expect(state.encodedSize <= AgentsActivityState.byteBudget)
        #expect(state.total == 3)
        #expect(state.working == 3)
    }

    @Test func roundTripsAsActivityKitStoresIt() throws {
        let snapshot = AgentWidgetSnapshot(writtenAt: now, agents: [agent(.working, steps: [.init(tool: "Edit", target: "a.swift")])])
        let state = AgentsActivityState(snapshot: snapshot, connected: false)
        let decoded = try JSONDecoder().decode(AgentsActivityState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }
}
