import Foundation
import Testing
@testable import MimamoriCore

/// Subagents as Claude Code's hooks told of them in real runs (2026-11-05): steps carry `agent_id`
/// and `agent_type`; an Agent call in the background answers at once with the subagent's id; Stop
/// and SubagentStop list what's still in flight.
@Suite("Subagents")
struct SubagentTests {
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1000 + seconds) }

    private func event(_ name: HookEvent.Name, tool: String? = nil, id: String? = nil, summary: String? = nil,
                       agent: String? = nil, type: String? = nil, launch: HookEvent.SubagentLaunch? = nil,
                       tasks: [HookEvent.BackgroundTask]? = nil, lastMessage: String? = nil,
                       at seconds: TimeInterval) -> HookEvent {
        var event = HookEvent(name: name, rawName: name.rawValue, sessionID: "s1", cwd: "/repo", toolName: tool, toolUseID: id,
                              summary: summary, agentID: agent, receivedAt: at(seconds))
        event.agentType = type
        event.subagentLaunch = launch
        event.backgroundTasks = tasks
        event.lastMessage = lastMessage
        return event
    }

    private func subagentTask(_ id: String, _ description: String, type: String = "Explore") -> HookEvent.BackgroundTask {
        .init(id: id, type: "subagent", status: "running", description: description, agentType: type)
    }

    /// A turn started with a prompt.
    private func started() -> AgentStatusMachine {
        var machine = AgentStatusMachine()
        _ = machine.apply(event(.userPromptSubmit, at: 0))
        return machine
    }

    @Test func aForegroundSubagentTakesItsTaskFromTheCallThatLaunchedIt() throws {
        var machine = started()
        _ = machine.apply(event(.preToolUse, tool: "Agent", id: "t1",
                                launch: .init(subagentType: "Explore", description: "Count the rules"), at: 1))
        _ = machine.apply(event(.preToolUse, tool: "Bash", id: "b1", summary: "grep rules", agent: "a1", type: "Explore", at: 2))
        _ = machine.apply(event(.postToolUse, tool: "Bash", id: "b1", agent: "a1", type: "Explore", at: 3))
        let notes = machine.apply(event(.subagentStop, agent: "a1", type: "Explore", lastMessage: "There are 10.", at: 4))
        _ = machine.apply(event(.postToolUse, tool: "Agent", id: "t1",
                                launch: .init(subagentType: "Explore", description: "Count the rules", status: "completed", agentID: "a1"),
                                at: 5))
        let status = try #require(machine.status)
        let subagent = try #require(status.subagents.first)
        #expect(status.subagents.count == 1)
        #expect(subagent.id == "a1" && subagent.type == "Explore" && subagent.description == "Count the rules")
        #expect(!subagent.background && !subagent.isRunning && subagent.steps == 1)
        #expect(subagent.lastStep?.summary == "grep rules" && subagent.lastMessage == "There are 10.")
        #expect(notes.map(\.title) == ["Claude Code's Explore subagent finished"])
        #expect(notes.first?.detail == "Count the rules")
        // Its step is labelled as its own.
        #expect(status.recentToolCalls.first { $0.id == "b1" }?.agentID == "a1")
        #expect(status.pendingLaunches.isEmpty)
    }

    @Test func theTurnWaitsForBackgroundSubagentsAndEndsWithTheLast() throws {
        var machine = started()
        _ = machine.apply(event(.preToolUse, tool: "Agent", id: "t1",
                                launch: .init(subagentType: "Explore", description: "Find the hooks", background: true), at: 1))
        _ = machine.apply(event(.postToolUse, tool: "Agent", id: "t1",
                                launch: .init(subagentType: "Explore", description: "Find the hooks", background: true,
                                              status: "async_launched", agentID: "a1"), at: 2))
        _ = machine.apply(event(.preToolUse, tool: "Read", id: "r1", agent: "a1", type: "Explore", at: 3))

        // The agent stops; its subagent is still in flight.
        let stopNotes = machine.apply(event(.stop, tasks: [subagentTask("a1", "Find the hooks")], at: 4))
        #expect(stopNotes.isEmpty)
        #expect(machine.status?.activity == .working(tool: nil, detail: "waiting on 1 subagent"))
        #expect(machine.status?.waitingOnSubagents == true)
        #expect(machine.status?.turnStartedAt != nil)

        // Its later steps don't flip the status or start a turn.
        _ = machine.apply(event(.postToolUse, tool: "Read", id: "r1", agent: "a1", type: "Explore", at: 5))
        _ = machine.apply(event(.preToolUse, tool: "Grep", id: "g1", agent: "a1", type: "Explore", at: 6))
        #expect(machine.status?.activity == .working(tool: nil, detail: "waiting on 1 subagent"))

        let notes = machine.apply(event(.subagentStop, agent: "a1", type: "Explore", tasks: [subagentTask("a1", "Find the hooks")], at: 9))
        let status = try #require(machine.status)
        #expect(status.activity == .ready && !status.waitingOnSubagents && status.turnStartedAt == nil)
        #expect(notes.map(\.kind) == [.notification, .turnFinished])
        #expect(notes.last?.title == "Claude Code finished a turn")
        #expect(status.subagents.first?.background == true && status.subagents.first?.steps == 2)
    }

    @Test func twoSubagentsCountDownOneByOne() throws {
        var machine = started()
        let both = [subagentTask("a1", "One"), subagentTask("a2", "Two", type: "general-purpose")]
        _ = machine.apply(event(.stop, tasks: both, at: 5))
        #expect(machine.status?.activity == .working(tool: nil, detail: "waiting on 2 subagents"))
        #expect(machine.status?.subagents.map(\.description) == ["One", "Two"])
        #expect(machine.apply(event(.subagentStop, agent: "a1", type: "Explore", tasks: both, at: 6)).map(\.kind) == [.notification])
        #expect(machine.status?.activity == .working(tool: nil, detail: "waiting on 1 subagent"))
        let last = machine.apply(event(.subagentStop, agent: "a2", type: "general-purpose", tasks: [both[1]], at: 7))
        #expect(last.map(\.kind) == [.notification, .turnFinished])
        #expect(machine.status?.activity == .ready)
    }

    @Test func aSubagentNoLongerListedHasFinished() {
        var machine = started()
        _ = machine.apply(event(.stop, tasks: [subagentTask("a1", "One"), subagentTask("a2", "Two")], at: 5))
        // a1's stop was never heard; the next list leaves it out.
        _ = machine.apply(event(.subagentStop, agent: "a2", type: "Explore", tasks: [subagentTask("a2", "Two")], at: 8))
        #expect(machine.status?.activity == .ready)
        #expect(machine.status?.runningSubagents.isEmpty == true)
    }

    @Test func aSubagentStepAfterTheTurnStartsNoTurn() {
        var machine = started()
        _ = machine.apply(event(.stop, at: 5))
        #expect(machine.status?.activity == .ready)
        _ = machine.apply(event(.preToolUse, tool: "Read", id: "r9", agent: "a7", type: "Explore", at: 6))
        _ = machine.apply(event(.postToolUse, tool: "Read", id: "r9", agent: "a7", type: "Explore", at: 7))
        #expect(machine.status?.activity == .ready)
        #expect(machine.status?.turnStartedAt == nil)
        #expect(machine.status?.subagents.first?.steps == 1)
    }

    @Test func aSilentSubagentIsTakenToHaveFinished() {
        var machine = started()
        _ = machine.apply(event(.stop, tasks: [subagentTask("a1", "One")], at: 5))
        #expect(machine.expireSubagents(now: at(5 + Subagent.quietLimit - 1)).isEmpty)
        #expect(machine.status?.waitingOnSubagents == true)
        let notes = machine.expireSubagents(now: at(5 + Subagent.quietLimit + 1))
        #expect(notes.map(\.kind) == [.turnFinished])
        #expect(machine.status?.activity == .ready)
    }

    @Test func backgroundCommandsAreCountedButDontHoldTheTurn() {
        var machine = started()
        _ = machine.apply(event(.stop, tasks: [.init(id: "x1", type: "shell", status: "running", description: "Watch CI")], at: 5))
        #expect(machine.status?.activity == .ready)
        #expect(machine.status?.backgroundCommands == 1)
    }

    @Test func aNewPromptWhileWaitingStartsATurnOfItsOwn() {
        var machine = started()
        _ = machine.apply(event(.stop, tasks: [subagentTask("a1", "One")], at: 5))
        let notes = machine.apply(HookEvent(name: .userPromptSubmit, rawName: "UserPromptSubmit", sessionID: "s1", cwd: "/repo",
                                            message: "Next thing", receivedAt: at(6)))
        #expect(notes.map(\.kind) == [.turnStarted])
        #expect(machine.status?.waitingOnSubagents == false)
        #expect(machine.status?.task == "Next thing")
        // Its subagent from before still runs.
        #expect(machine.status?.runningSubagents.count == 1)
    }

    @Test func aSubagentInAWorktreeOfItsOwnKeepsItOnItsParentsCard() throws {
        var machine = started()
        // The hub places it on its session's worktree, and says where it works.
        var step = event(.preToolUse, tool: "Bash", id: "b1", agent: "a9", type: "general-purpose", at: 2)
        step.subagentWorktree = "/repo/.claude/worktrees/agent-a9"
        _ = machine.apply(step)
        let subagent = try #require(machine.status?.subagents.first)
        #expect(subagent.worktreePath == "/repo/.claude/worktrees/agent-a9")
        #expect(machine.status?.sessionID == "s1")
    }

    @Test func aBackgroundCommandRunsUntilClaudeCodeSaysItEnded() throws {
        var machine = started()
        var pre = event(.preToolUse, tool: "Bash", id: "c1", summary: "gh pr checks 64 --watch", at: 1)
        pre.commandLaunch = .init(description: "Watch CI", command: "gh pr checks 64 --watch")
        _ = machine.apply(pre)
        var post = event(.postToolUse, tool: "Bash", id: "c1", at: 2)
        post.commandLaunch = .init(description: "Watch CI", command: "gh pr checks 64 --watch", taskID: "b42")
        _ = machine.apply(post)
        let command = try #require(machine.status?.commands.first)
        #expect(command.id == "b42" && command.description == "Watch CI" && command.command == "gh pr checks 64 --watch")
        #expect(command.startedAt == at(1) && command.isRunning)

        // The agent hands the turn back; the command goes on, and the turn isn't held for it.
        _ = machine.apply(event(.stop, tasks: [.init(id: "b42", type: "shell", status: "running", description: "Watch CI")], at: 5))
        #expect(machine.status?.activity == .ready)
        #expect(machine.status?.backgroundCommands == 1)

        // Claude Code wakes the agent to say it ended.
        var told = HookEvent(name: .userPromptSubmit, rawName: "UserPromptSubmit", sessionID: "s1", cwd: "/repo",
                             message: #"Background command "Watch CI" completed (exit code 0)"#, receivedAt: at(60))
        told.taskNotification = .init(taskID: "b42", status: "completed", summary: #"Background command "Watch CI" completed (exit code 0)"#)
        _ = machine.apply(told)
        let done = try #require(machine.status?.commands.first)
        #expect(!done.isRunning && done.status == "completed" && done.exitCode == 0)
        #expect(done.outcome == "completed (exit 0)")
        #expect(machine.status?.task == #"Background command "Watch CI" completed (exit code 0)"#)
    }

    @Test func aSubagentsNotificationFinishesIt() {
        var machine = started()
        _ = machine.apply(event(.stop, tasks: [subagentTask("a1", "One")], at: 5))
        var told = HookEvent(name: .userPromptSubmit, rawName: "UserPromptSubmit", sessionID: "s1", cwd: "/repo",
                             message: #"Agent "One" finished"#, receivedAt: at(9))
        told.taskNotification = .init(taskID: "a1", status: "completed", summary: #"Agent "One" finished"#)
        _ = machine.apply(told)
        #expect(machine.status?.runningSubagents.isEmpty == true)
    }

    @Test func taskNotificationsAreReadAsClaudeCodeWritesThem() throws {
        let prompt = """
            <task-notification>
            <task-id>bow430idd</task-id>
            <tool-use-id>toolu_01Nm</tool-use-id>
            <output-file>/tmp/tasks/bow430idd.output</output-file>
            <status>failed</status>
            <summary>Background command "Wait for #64's checks" failed (exit code 1)</summary>
            </task-notification>
            """
        let notification = try #require(HookEvent.TaskNotification.parse(prompt))
        #expect(notification.taskID == "bow430idd" && notification.status == "failed" && notification.exitCode == 1)
        #expect(HookEvent.TaskNotification.parse("Please fix <task-id>x</task-id>") == nil)
        let event = try #require(HookEventParser.parse(["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/repo",
                                                        "prompt": prompt]))
        #expect(event.taskNotification?.taskID == "bow430idd")
        #expect(event.message == #"Background command "Wait for #64's checks" failed (exit code 1)"#)
        let launch = try #require(HookEventParser.parse([
            "hook_event_name": "PostToolUse", "session_id": "s1", "cwd": "/repo", "tool_name": "Bash", "tool_use_id": "c1",
            "tool_input": ["command": "gh pr checks 64 --watch\necho done", "description": "Watch CI", "run_in_background": true],
            "tool_response": ["backgroundTaskId": "b42", "interrupted": false],
        ]))
        #expect(launch.commandLaunch == .init(description: "Watch CI", command: "gh pr checks 64 --watch", taskID: "b42"))
    }

    @Test func hookFieldsAreReadAsClaudeCodeSendsThem() throws {
        let stop: [String: Any] = [
            "hook_event_name": "SubagentStop", "session_id": "s1", "cwd": "/repo", "agent_id": "a1", "agent_type": "Explore",
            "last_assistant_message": "Done.\nMore lines.",
            "background_tasks": [["id": "a1", "type": "subagent", "status": "running", "description": "Find it", "agent_type": "Explore"],
                                 ["id": "x1", "type": "shell", "status": "running", "description": "Watch CI", "command": "sleep 60"]],
        ]
        let event = try #require(HookEventParser.parse(stop))
        #expect(event.agentID == "a1" && event.agentType == "Explore" && event.lastMessage == "Done.")
        #expect(event.backgroundTasks?.map(\.type) == ["subagent", "shell"])
        #expect(event.backgroundTasks?.first?.description == "Find it")
        let launch: [String: Any] = [
            "hook_event_name": "PostToolUse", "session_id": "s1", "cwd": "/repo", "tool_name": "Agent", "tool_use_id": "t1",
            "tool_input": ["subagent_type": "Explore", "description": "Find it", "prompt": "…", "run_in_background": true],
            "tool_response": ["status": "async_launched", "agentId": "a1"],
        ]
        let post = try #require(HookEventParser.parse(launch))
        #expect(post.subagentLaunch == HookEvent.SubagentLaunch(subagentType: "Explore", description: "Find it", background: true,
                                             status: "async_launched", agentID: "a1"))
    }
}

@Suite("Subagents on the iPhone")
struct SubagentsOnThePhoneTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aCardsSubagentsAndCommandsSurviveTheTrip() throws {
        let card = AgentWidgetSnapshot.Card(
            reportsSteps: true, turnUnderway: true,
            subagents: [.init(id: "a1", title: "Explore", description: "Find the hooks", background: true, steps: 3,
                              startedAt: now, lastStep: "Read Sources/App.swift")],
            commands: [.init(id: "b42", description: "Watch CI", command: "gh pr checks 64 --watch", startedAt: now,
                             finishedAt: now.addingTimeInterval(90), outcome: "failed (exit 1)", failed: true)])
        let snapshot = AgentWidgetSnapshot(writtenAt: now, agents: [
            .init(worktreePath: "/repo", repository: "shop", worktree: "main", agent: "Claude Code", state: .working,
                  status: "working · waiting on 1 subagent", since: now, card: card),
        ])
        var reader = CompanionLineReader()
        let line = try #require(reader.lines(adding: try CompanionMessage(snapshot: snapshot).line()).first)
        #expect(try CompanionMessage(line: line).snapshot == snapshot)
    }

    @Test func aCardFromBeforeSubagentsStillReads() throws {
        let json = #"{"reportsSteps":true,"turnUnderway":false,"calls":[],"callsThisTurn":0,"files":[],"#
            + #""changes":{"files":0,"toReview":0,"flagged":0,"additions":0,"deletions":0},"others":[]}"#
        let card = try JSONDecoder().decode(AgentWidgetSnapshot.Card.self, from: Data(json.utf8))
        #expect(card.subagents == nil && card.commands == nil)
    }

    @Test func theActionsListNamesEachSubagent() throws {
        let step = AgentToolCall(id: "r1", toolName: "Read", summary: "App.swift", filePath: nil, startedAt: now, agentID: "a1")
        let actions = AgentActions(worktreePath: "/repo", agent: "Claude Code", turns: [.init(startedAt: now, calls: [step])],
                                   subagentTitles: ["a1": "Explore"])
        var reader = CompanionLineReader()
        let line = try #require(reader.lines(adding: try CompanionMessage(actions: actions).line()).first)
        let decoded = try #require(try CompanionMessage(line: line).actions)
        #expect(decoded.subagentTitles?["a1"] == "Explore")
        #expect(decoded.turns.first?.calls.first?.agentID == "a1")
    }
}
