import Foundation
import Testing
@testable import MimamoriCore

@Suite("Companion alerts")
struct CompanionAlertsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func agent(_ state: AgentWidgetSnapshot.State, status: String = "working", since offset: TimeInterval = 0,
                       path: String = "/repo/main", task: String? = "Add a cart", collision: String? = nil) -> AgentWidgetSnapshot.Agent {
        .init(worktreePath: path, repository: "shop", worktree: (path as NSString).lastPathComponent, agent: "Claude Code",
              state: state, status: status, since: now.addingTimeInterval(offset), task: task, collision: collision)
    }

    @Test func theFirstSnapshotOnlySetsTheBaseline() {
        let changes = CompanionAlerts.changes(from: nil, to: [agent(.needsYou, status: "needs permission · Bash swift test")])
        #expect(changes == .init())
    }

    @Test func anAgentStartingToNeedYouIsAnnounced() throws {
        let changes = CompanionAlerts.changes(from: [agent(.working)],
                                              to: [agent(.needsYou, status: "needs permission · Bash swift test", since: 5)])
        let alert = try #require(changes.post.first)
        #expect(changes.post.count == 1)
        #expect(alert.kind == .needsYou)
        #expect(alert.id == "needs:/repo/main")
        #expect(alert.title == "Claude Code needs permission: Bash")
        #expect(alert.body == "swift test · shop › main")
        #expect(alert.thread == "/repo/main")
    }

    @Test func aQuestionAndOtherWaitsAreWordedAsTheMacWordsThem() {
        let question = CompanionAlerts.changes(from: [agent(.working)], to: [agent(.needsYou, status: "asks: Which port?", since: 5)])
        #expect(question.post.first?.title == "Claude Code has a question for you")
        #expect(question.post.first?.body == "Which port? · shop › main")
        let bare = CompanionAlerts.changes(from: [agent(.working)], to: [agent(.needsYou, status: "needs permission", since: 5)])
        #expect(bare.post.first?.title == "Claude Code needs permission")
        #expect(bare.post.first?.body == "shop › main")
    }

    @Test func stillNeedingYouIsNotAnnouncedAgainUntilANewRequest() {
        let waiting = agent(.needsYou, status: "needs permission · Bash ls", since: 5)
        #expect(CompanionAlerts.changes(from: [waiting], to: [waiting]).post.isEmpty)
        let next = agent(.needsYou, status: "needs permission · Edit README.md", since: 30)
        #expect(CompanionAlerts.changes(from: [waiting], to: [next]).post.map(\.title) == ["Claude Code needs permission: Edit"])
    }

    @Test func answeringOrLeavingWithdrawsTheAlert() {
        let waiting = agent(.needsYou, status: "needs permission · Bash ls", since: 5)
        #expect(CompanionAlerts.changes(from: [waiting], to: [agent(.working, since: 9)]).withdraw == ["needs:/repo/main"])
        #expect(CompanionAlerts.changes(from: [waiting], to: []).withdraw == ["needs:/repo/main"])
    }

    @Test func aFinishedTurnIsAnnouncedWithItsTask() {
        let changes = CompanionAlerts.changes(from: [agent(.working)], to: [agent(.ready, status: "ready for your next prompt", since: 60)])
        #expect(changes.post.map(\.title) == ["Claude Code finished a turn"])
        #expect(changes.post.first?.body == "Add a cart · shop › main")
        #expect(changes.post.first?.kind == .turnFinished)
        // Ready to ready is no news.
        let ready = agent(.ready, status: "ready for your next prompt", since: 60)
        #expect(CompanionAlerts.changes(from: [ready], to: [ready]).post.isEmpty)
    }

    @Test func aNewCollisionIsAnnouncedOnce() {
        let colliding = agent(.working, collision: "Codex and Claude Code both edited Cart.swift")
        let changes = CompanionAlerts.changes(from: [agent(.working)], to: [colliding])
        #expect(changes.post.map(\.title) == ["Codex and Claude Code both edited Cart.swift"])
        #expect(changes.post.first?.kind == .collision)
        #expect(CompanionAlerts.changes(from: [colliding], to: [colliding]).post.isEmpty)
    }

    private func asking(_ request: AgentWidgetSnapshot.PermissionRequest?, since offset: TimeInterval = 5) -> AgentWidgetSnapshot.Agent {
        var waiting = agent(.needsYou, status: "needs permission · Bash make", since: offset)
        waiting.permissionRequest = request
        return waiting
    }

    @Test func aQuestionsAlertNamesTheQuestionAndOffersNoAllowOrDeny() throws {
        let questions = [AgentQuestion(question: "Which color?", options: [.init(label: "Red"), .init(label: "Blue")]),
                         AgentQuestion(question: "Which fruits?", multiSelect: true, options: [.init(label: "Pear")])]
        let request = AgentWidgetSnapshot.PermissionRequest(id: "req-1", tool: "AskUserQuestion", since: now.addingTimeInterval(5),
                                                            questions: questions)
        let alert = try #require(CompanionAlerts.changes(from: [agent(.working)], to: [asking(request)]).post.first)
        #expect(alert.title.hasSuffix("has a question for you"))
        #expect(alert.body.contains("Which color?") && alert.body.contains("1 more"))
        #expect(alert.requestID == nil)
    }

    @Test func aRequestToAnswerGivesTheAlertItsIDAndCommand() throws {
        let request = AgentWidgetSnapshot.PermissionRequest(id: "req-1", tool: "Bash", detail: "make deploy\nmake tag",
                                                            since: now.addingTimeInterval(5),
                                                            autoAnswer: .init(allow: false, at: now.addingTimeInterval(35)))
        let alert = try #require(CompanionAlerts.changes(from: [agent(.working)], to: [asking(request)]).post.first)
        #expect(alert.requestID == "req-1")
        #expect(!alert.quiet)
        #expect(alert.title == "Claude Code needs permission: Bash")
        #expect(alert.body == "make deploy\nmake tag · shop › main\nDenying in 30 s unless you answer.")
        // Without a request, nothing on the notification can answer.
        let plain = CompanionAlerts.changes(from: [agent(.working)], to: [asking(nil)]).post.first
        #expect(plain?.requestID == nil)
    }

    @Test func aRequestArrivingOrSettledLaterUpdatesTheAlertQuietly() throws {
        let request = AgentWidgetSnapshot.PermissionRequest(id: "req-1", tool: "Bash", detail: "make", since: now)
        let added = try #require(CompanionAlerts.changes(from: [asking(nil)], to: [asking(request)]).post.first)
        #expect(added.quiet && added.requestID == "req-1" && added.id == "needs:/repo/main")
        // Settled while the agent still waits (on its own prompt): Allow and Deny go.
        let settled = try #require(CompanionAlerts.changes(from: [asking(request)], to: [asking(nil)]).post.first)
        #expect(settled.quiet && settled.requestID == nil)
        #expect(CompanionAlerts.changes(from: [asking(request)], to: [asking(request)]).post.isEmpty)
    }

    @Test func autoAnswerWaitsAreWordedShortly() {
        #expect(CompanionAlerts.duration(45) == "45 s")
        #expect(CompanionAlerts.duration(120) == "2 min")
        #expect(CompanionAlerts.duration(90) == "1 min 30 s")
    }
}
