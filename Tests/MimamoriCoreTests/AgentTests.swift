import Foundation
import SQLite3
import Testing
@testable import MimamoriCore

@Suite("Agent classification")
struct AgentClassifierTests {
    let classifier = AgentClassifier(customNames: ["myagent"])

    @Test func recognizesKnownAgents() {
        #expect(classifier.classify(executable: "/usr/local/bin/claude", arguments: ["claude"]) == .claudeCode)
        #expect(classifier.classify(executable: "/Users/x/Library/Application Support/Claude/claude-code/2.1.308/abc/claude.app/Contents/MacOS/claude", arguments: []) == .claudeCode)
        #expect(classifier.classify(executable: "/usr/local/bin/node", arguments: ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"]) == .claudeCode)
        #expect(classifier.classify(executable: "/opt/homebrew/bin/codex", arguments: ["codex"]) == .codex)
        #expect(classifier.classify(executable: "/usr/bin/python3", arguments: ["python3", "-m", "aider", "--model", "x"]) == .aider)
        #expect(classifier.classify(executable: "/usr/local/bin/cursor-agent", arguments: []) == .cursor)
        #expect(classifier.classify(executable: "/opt/homebrew/bin/myagent", arguments: [])?.displayName == "myagent")
    }

    @Test func recognizesHermesConsoleScripts() {
        // Hermes installs as a Python console script inside a venv; the interpreter is versioned.
        let python = "/Users/x/.hermes/tools/python-3.14.7+20260901-darwin-arm64/bin/python3.14"
        #expect(classifier.classify(executable: python, arguments: ["/Users/x/.hermes/hermes-agent/.hermes/bin/hermes", "gateway", "run"]) == .hermes)
        #expect(classifier.classify(executable: python, arguments: ["python3.14", "/Users/x/.hermes/hermes-agent/.hermes/bin/hermes"]) == .hermes)
        #expect(classifier.classify(executable: python, arguments: ["/Users/x/.hermes/hermes-agent/.hermes/bin/hermes-agent"]) == .hermes)
        // A plain Python script in the same venv is not an agent.
        #expect(classifier.classify(executable: python, arguments: ["python3.14", "-I", "-c", "import os"]) == nil)
    }

    @Test func ignoresOrdinaryProcesses() {
        #expect(classifier.classify(executable: "/bin/zsh", arguments: ["-zsh"]) == nil)
        #expect(classifier.classify(executable: "/usr/local/bin/node", arguments: ["node", "server.js"]) == nil)
        #expect(classifier.classify(executable: "/Applications/Xcode.app/Contents/MacOS/Xcode", arguments: []) == nil)
    }
}

@Suite("Process inspection")
struct ProcessInspectorTests {
    @Test func inspectsOwnProcess() throws {
        let pid = getpid()
        let executable = try #require(ProcessInspector.executablePath(of: pid))
        #expect(!executable.isEmpty)
        let cwd = try #require(ProcessInspector.currentDirectory(of: pid))
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
        #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == expected)
        #expect(!ProcessInspector.arguments(of: pid).isEmpty)
        #expect((ProcessInspector.cpuTime(of: pid) ?? 0) > 0)
        let started = try #require(ProcessInspector.startDate(of: pid))
        #expect(Date().timeIntervalSince(started) < 86_400)
    }

    @Test func scannerMatchesWorktreeByWorkingDirectory() async throws {
        let pid = getpid()
        let executable = try #require(ProcessInspector.executablePath(of: pid))
        let name = (executable as NSString).lastPathComponent
        let cwd = try #require(ProcessInspector.currentDirectory(of: pid))
        let scanner = AgentScanner(classifier: AgentClassifier(customNames: [name]))
        let parent = (cwd as NSString).deletingLastPathComponent
        let found = await scanner.scan(worktrees: [parent, cwd]).byWorktree
        // Longest prefix wins: the exact cwd, not its parent.
        #expect(found[cwd]?.contains { $0.pid == pid } == true)
        #expect(found[parent]?.contains { $0.pid == pid } != true)
        let none = await scanner.scan(worktrees: ["/nonexistent/path"])
        #expect(none.byWorktree.isEmpty)
        // Not Claude Code, so not followed outside the worktrees.
        #expect(!none.elsewhere.contains { $0.pid == pid })
    }
}

@Suite("Hook events")
struct HookEventTests {
    private func parse(_ json: String) -> HookEvent? {
        HookEventParser.parse(Data(json.utf8))
    }

    @Test func parsesToolEvents() throws {
        let edit = try #require(parse(#"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/repo","tool_name":"Edit","tool_use_id":"t1","tool_input":{"file_path":"src/app.py","old_string":"a","new_string":"b"}}"#))
        #expect(edit.name == .preToolUse)
        #expect(edit.toolName == "Edit")
        #expect(edit.filePath == "/repo/src/app.py")
        #expect(edit.summary == "src/app.py")
        #expect(edit.isMutatingTool)

        let bash = try #require(parse(#"{"hook_event_name":"PreToolUse","cwd":"/repo","tool_name":"Bash","tool_input":{"command":"swift test\necho done"}}"#))
        #expect(bash.summary == "swift test")

        let read = try #require(parse(#"{"hook_event_name":"PostToolUse","cwd":"/repo","tool_name":"Read","tool_use_id":"t2","tool_input":{"file_path":"/repo/README.md"},"tool_response":{}}"#))
        #expect(!read.isMutatingTool)
        #expect(read.filePath == "/repo/README.md")
    }

    @Test func parsesLifecycleEvents() throws {
        let note = try #require(parse(#"{"hook_event_name":"Notification","cwd":"/repo","message":"Claude needs your permission to use Bash"}"#))
        #expect(note.name == .notification)
        #expect(note.message?.contains("permission") == true)
        let stop = try #require(parse(#"{"hook_event_name":"Stop","cwd":"/repo","stop_hook_active":false}"#))
        #expect(stop.name == .stop)
        let unknown = try #require(parse(#"{"hook_event_name":"SomethingNew","cwd":"/repo"}"#))
        #expect(unknown.name == .other && unknown.rawName == "SomethingNew")
        #expect(parse(#"{"not":"a hook"}"#) == nil)
    }
}

@Suite("Hermes hook events")
struct HermesHookTests {
    private func parse(_ json: String) -> HookEvent? { HermesHookParser.parse(Data(json.utf8)) }

    @Test func translatesHermesEvents() throws {
        let pre = try #require(parse(#"{"hook_event_name":"pre_tool_call","tool_name":"write_file","tool_input":{"path":"src/a.py","content":"x"},"session_id":"sess_1","cwd":"/repo","profile":"default","extra":{"tool_call_id":"call_9"}}"#))
        #expect(pre.name == .preToolUse)
        #expect(pre.rawName == "pre_tool_call")
        #expect(pre.agent == .hermes)
        #expect(pre.toolUseID == "call_9")
        // Relative paths stay relative: Hermes's cwd is the process directory, not the project.
        #expect(pre.filePath == "src/a.py")
        #expect(pre.isMutatingTool)

        let llm = try #require(parse(#"{"hook_event_name":"pre_llm_call","tool_name":null,"tool_input":null,"session_id":"sess_1","cwd":"/repo","extra":{"user_message":"fix the build"}}"#))
        #expect(llm.name == .userPromptSubmit)
        #expect(llm.message == "fix the build")

        let approval = try #require(parse(#"{"hook_event_name":"pre_approval_request","tool_name":"terminal","tool_input":{"command":"git push"},"cwd":"/repo","extra":{}}"#))
        #expect(approval.name == .permissionRequest)
        #expect(approval.summary == "git push")

        let human = try #require(parse(#"{"hook_event_name":"on_human_input_request","cwd":"/repo","extra":{"prompt":"Which branch?"}}"#))
        #expect(human.name == .notification)
        #expect(human.notificationType == "question")
        #expect(human.message == "Which branch?")

        let verify = try #require(parse(#"{"hook_event_name":"pre_verify","cwd":"/repo","extra":{}}"#))
        #expect(verify.name == .stop)
    }

    @Test func gatewayEventsKeepRelativePathsAndOfferHints() throws {
        // Process cwd is ~/.hermes; the tool path is relative to the session's project.
        let write = try #require(parse(#"{"hook_event_name":"pre_tool_call","tool_name":"write_file","tool_input":{"path":"src/a.py","content":"x"},"session_id":"s","cwd":"/Users/x/.hermes","extra":{}}"#))
        #expect(write.filePath == "src/a.py")
        #expect(write.cwd == "/Users/x/.hermes")

        let shell = try #require(parse(#"{"hook_event_name":"pre_tool_call","tool_name":"terminal","tool_input":{"command":"cd /Users/x/Projects/backend && swift test"},"session_id":"s","cwd":"/Users/x/.hermes","extra":{}}"#))
        #expect(shell.absolutePathHints == ["/Users/x/Projects/backend"])

        let scoped = try #require(parse(#"{"hook_event_name":"pre_tool_call","tool_name":"terminal","tool_input":{"command":"ls","workdir":"/Users/x/Projects/backend"},"session_id":"s","cwd":"/Users/x/.hermes","extra":{}}"#))
        #expect(scoped.cwd == "/Users/x/Projects/backend")
    }

    @Test func repeatedModelCallsDoNotRestartTheTurn() {
        var machine = AgentStatusMachine()
        func llm(_ t: TimeInterval) -> HookEvent {
            HookEvent(name: .userPromptSubmit, rawName: "pre_llm_call", agent: .hermes, cwd: "/repo", receivedAt: Date(timeIntervalSince1970: 1000 + t))
        }
        let first = machine.apply(llm(0))
        #expect(first.contains { $0.kind == .turnStarted })
        _ = machine.apply(HookEvent(name: .preToolUse, rawName: "pre_tool_call", agent: .hermes, cwd: "/repo", toolName: "terminal", toolUseID: "c1", receivedAt: Date(timeIntervalSince1970: 1001)))
        let second = machine.apply(llm(2))
        #expect(second.isEmpty)
        #expect(machine.status?.toolCallsThisTurn == 1)
        let stop = machine.apply(HookEvent(name: .stop, rawName: "pre_verify", agent: .hermes, cwd: "/repo", receivedAt: Date(timeIntervalSince1970: 1010)))
        #expect(stop.first?.kind == .turnFinished)
        #expect(machine.status?.activity == .ready)
    }

    @Test func answeringHermesContinuesTheTurn() {
        var machine = AgentStatusMachine()
        func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: 1000 + t) }
        _ = machine.apply(HookEvent(name: .userPromptSubmit, rawName: "pre_llm_call", agent: .hermes, cwd: "/repo", receivedAt: at(0)))
        _ = machine.apply(HookEvent(name: .preToolUse, rawName: "pre_tool_call", agent: .hermes, cwd: "/repo", toolName: "terminal", toolUseID: "c1", receivedAt: at(1)))
        let asked = machine.apply(HookEvent(name: .notification, rawName: "on_human_input_request", agent: .hermes, cwd: "/repo",
                                            message: "Which branch?", notificationType: "question", receivedAt: at(2)))
        #expect(machine.status?.activity == .askedQuestion(detail: "Which branch?"))
        #expect(machine.status?.activity.needsAttention == true)
        #expect(asked.first?.kind == .waiting)
        let answered = machine.apply(HookEvent(name: .userPromptSubmit, rawName: "on_human_input_resolved", agent: .hermes, cwd: "/repo", receivedAt: at(5)))
        #expect(answered.isEmpty)
        #expect(machine.status?.toolCallsThisTurn == 1)
        #expect(machine.status?.activity == .working(tool: nil, detail: nil))
    }
}

@Suite("Agent status machine")
struct AgentStatusMachineTests {
    private func event(_ name: HookEvent.Name, tool: String? = nil, id: String? = nil, path: String? = nil,
                       message: String? = nil, type: String? = nil, at seconds: TimeInterval) -> HookEvent {
        HookEvent(name: name, rawName: name.rawValue, sessionID: "s1", cwd: "/repo", toolName: tool, toolUseID: id,
                  filePath: path, summary: path, message: message, notificationType: type,
                  receivedAt: Date(timeIntervalSince1970: 1000 + seconds))
    }

    @Test func followsATurn() {
        var machine = AgentStatusMachine()
        _ = machine.apply(event(.sessionStart, at: 0))
        #expect(machine.status?.activity == .ready)
        #expect(machine.status?.activity.needsAttention == false)
        _ = machine.apply(event(.userPromptSubmit, message: "fix the tests", at: 1))
        #expect(machine.status?.activity == .working(tool: nil, detail: nil))
        let notes = machine.apply(event(.preToolUse, tool: "Edit", id: "t1", path: "/repo/a.swift", at: 2))
        #expect(machine.status?.activity == .working(tool: "Edit", detail: "/repo/a.swift"))
        #expect(notes.first?.kind == .toolCall && notes.first?.isMutatingTool == true)
        _ = machine.apply(event(.postToolUse, tool: "Edit", id: "t1", at: 4))
        #expect(machine.status?.recentToolCalls.first?.finishedAt != nil)
        _ = machine.apply(event(.preToolUse, tool: "Bash", id: "t2", at: 5))
        _ = machine.apply(event(.permissionRequest, tool: "Bash", at: 6))
        #expect(machine.status?.activity.needsAttention == true)
        let stop = machine.apply(event(.stop, at: 30))
        // A finished turn is ready for the next prompt, not something waiting on you.
        #expect(machine.status?.activity == .ready)
        #expect(machine.status?.activity.needsAttention == false)
        #expect(stop.first?.kind == .turnFinished)
        #expect(stop.first?.detail?.contains("2 tool calls") == true)
        _ = machine.apply(event(.sessionEnd, at: 31))
        #expect(machine.status?.activity == .idle)
    }

    @Test func findsTheToolCallActiveAtATime() {
        var machine = AgentStatusMachine()
        _ = machine.apply(event(.preToolUse, tool: "Edit", id: "t1", path: "/repo/a.swift", at: 10))
        _ = machine.apply(event(.postToolUse, tool: "Edit", id: "t1", at: 12))
        let status = machine.status!
        #expect(status.toolCall(activeAt: Date(timeIntervalSince1970: 1011))?.id == "t1")
        #expect(status.toolCall(activeAt: Date(timeIntervalSince1970: 1014))?.id == "t1")   // within grace
        #expect(status.toolCall(activeAt: Date(timeIntervalSince1970: 1020)) == nil)
        #expect(status.toolCall(activeAt: Date(timeIntervalSince1970: 1005)) == nil)
    }

    @Test func notificationsClassifyState() {
        var machine = AgentStatusMachine()
        // Claude's idle reminder is not a question: still ready, and nothing for the feed.
        let idle = machine.apply(event(.notification, message: "Claude is waiting for your input", type: "idle_prompt", at: 0))
        #expect(machine.status?.activity == .ready)
        #expect(idle.isEmpty)
        _ = machine.apply(event(.notification, tool: "Bash", message: "Claude needs your permission to use Bash", type: "permission_prompt", at: 1))
        if case .needsPermission(let tool, _) = machine.status!.activity { #expect(tool == "Bash") } else { Issue.record("expected needsPermission") }
        let dialog = machine.apply(event(.notification, message: "Claude Code needs your input", type: "elicitation_dialog", at: 2))
        #expect(machine.status?.activity == .askedQuestion(detail: "Claude Code needs your input"))
        #expect(dialog.first?.kind == .waiting)
        let other = machine.apply(event(.notification, message: "Signed in", type: "auth_success", at: 3))
        #expect(other.first?.kind == .notification)
    }

    @Test func notificationsWithoutATypeFallBackToTheMessage() {
        var machine = AgentStatusMachine()
        _ = machine.apply(event(.notification, message: "Claude is waiting for your input", at: 0))
        #expect(machine.status?.activity == .ready)
        _ = machine.apply(event(.notification, message: "Claude needs your permission to use Write", at: 1))
        #expect(machine.status?.activity.needsAttention == true)
    }

    @Test func askUserQuestionWaitsForTheAnswer() throws {
        let pre = try #require(HookEventParser.parse(Data(#"{"hook_event_name":"PreToolUse","cwd":"/repo","tool_name":"AskUserQuestion","tool_use_id":"q1","tool_input":{"questions":[{"question":"Which database should we use?","header":"DB","options":[]}]}}"#.utf8)))
        #expect(pre.summary == "Which database should we use?")
        var machine = AgentStatusMachine()
        _ = machine.apply(event(.userPromptSubmit, at: 0))
        let notes = machine.apply(pre)
        #expect(machine.status?.activity == .askedQuestion(detail: "Which database should we use?"))
        #expect(notes.first?.kind == .waiting)
        _ = machine.apply(event(.postToolUse, tool: "AskUserQuestion", id: "q1", at: 9))
        #expect(machine.status?.activity == .working(tool: nil, detail: nil))
    }
}

@Suite("Claude hooks config")
struct ClaudeHooksConfigTests {
    let command = ClaudeHooksConfig.command(socketPath: FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Mimamori/mimamori.sock")

    @Test func commandIsPortableAndSafe() {
        #expect(command.contains("$HOME/Library/Application Support/Mimamori/mimamori.sock"))
        #expect(command.contains(ClaudeHooksConfig.marker))
        #expect(command.hasSuffix("|| true"))
        #expect(command.contains("-m 1"))
    }

    @Test func installPreservesExistingHooksAndIsIdempotent() {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": [
                "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "python3 loop-detector.py"]]]],
                "Stop": [["hooks": [["type": "command", "command": "say done"]]]],
            ],
        ]
        let once = ClaudeHooksConfig.install(into: existing, command: command)
        let twice = ClaudeHooksConfig.install(into: once, command: command)
        #expect(ClaudeHooksConfig.isInstalled(in: once))
        #expect(!ClaudeHooksConfig.isInstalled(in: existing))
        #expect(once["model"] as? String == "opus")
        let hooks = twice["hooks"] as! [String: Any]
        let pre = hooks["PreToolUse"] as! [[String: Any]]
        #expect(pre.count == 2)
        #expect((pre[0]["hooks"] as! [[String: Any]])[0]["command"] as? String == "python3 loop-detector.py")
        #expect(pre[1]["matcher"] as? String == "*")
        let stop = hooks["Stop"] as! [[String: Any]]
        #expect(stop.count == 2)
        for event in ClaudeHooksConfig.events {
            #expect(hooks[event.name] != nil, "missing \(event.name)")
        }
    }

    @Test func uninstallRemovesOnlyOurs() {
        let existing: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]]]
        let installed = ClaudeHooksConfig.install(into: existing, command: command)
        let removed = ClaudeHooksConfig.uninstall(from: installed)
        let hooks = removed["hooks"] as! [String: Any]
        #expect(hooks.count == 1)
        #expect((hooks["Stop"] as! [[String: Any]]).count == 1)
        #expect(!ClaudeHooksConfig.isInstalled(in: removed))
        let empty = ClaudeHooksConfig.uninstall(from: ClaudeHooksConfig.install(into: [:], command: command))
        #expect(empty["hooks"] == nil)
    }
}

@Suite("Hermes hooks config")
struct HermesHooksConfigTests {
    let script = "~/.hermes/agent-hooks/mimamori.sh"

    @Test func appendsAndRemovesADelimitedBlock() throws {
        let original = "model:\n  default: foo\nhooks_auto_accept: false\n"
        let installed = try #require(HermesHooksConfig.install(into: original, scriptPath: script))
        #expect(installed.hasPrefix(original))
        #expect(installed.contains("\nhooks:\n  on_session_start:\n    - command: \"\(script)\"\n"))
        #expect(installed.contains("  pre_tool_call:\n    - command: \"\(script)\"\n      timeout: 5\n"))
        #expect(HermesHooksConfig.isInstalled(in: installed))
        // Mimamori's own block does not count as a user-owned hooks: key.
        #expect(!HermesHooksConfig.hasTopLevelHooksKey(installed))
        // Idempotent: a second install replaces, never duplicates.
        let again = try #require(HermesHooksConfig.install(into: installed, scriptPath: script))
        #expect(again == installed)
        let removed = HermesHooksConfig.uninstall(from: installed)
        #expect(removed == original)
        #expect(!HermesHooksConfig.isInstalled(in: removed))
    }

    @Test func refusesToTouchAnExistingHooksKey() {
        let existing = "hooks:\n  pre_tool_call:\n    - command: \"~/x.sh\"\n"
        #expect(HermesHooksConfig.install(into: existing, scriptPath: script) == nil)
        #expect(HermesHooksConfig.uninstall(from: existing) == existing)
        #expect(HermesHooksConfig.yamlEntries(scriptPath: script).contains("  on_session_start:\n"))
    }

    @Test func readsWhichHooksHermesApproved() {
        let all = HermesHookParser.subscribedEvents
        #expect(HermesHooksConfig.unapprovedEvents(allowlistJSON: nil, scriptPath: script) == all)
        let json = """
        {"approvals": [
          {"event": "pre_tool_call", "command": "\(script)", "approved_at": "2026-10-23T19:00:00Z"},
          {"event": "post_tool_call", "command": "\(script)"},
          {"event": "on_session_start", "command": "~/other.sh"}
        ]}
        """
        let missing = HermesHooksConfig.unapprovedEvents(allowlistJSON: Data(json.utf8), scriptPath: script)
        #expect(missing.count == all.count - 2)
        #expect(!missing.contains("pre_tool_call"))
        #expect(missing.contains("on_session_start"))
        // A broken file approves nothing.
        #expect(HermesHooksConfig.unapprovedEvents(allowlistJSON: Data("{".utf8), scriptPath: script) == all)
    }

    @Test func scriptIsSafe() {
        let text = HermesHooksConfig.script(socketPath: FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Mimamori/mimamori.sock")
        #expect(text.hasPrefix("#!/bin/sh"))
        #expect(text.contains("$HOME/Library/Application Support/Mimamori/mimamori.sock"))
        #expect(text.contains("/event/hermes"))
        #expect(text.contains("exit 0"))
    }
}

@Suite("Hook socket server", .serialized)
struct HookSocketServerTests {
    @Test func receivesEventsFromCurl() async throws {
        let path = NSTemporaryDirectory() + "mimamori-test-\(UUID().uuidString.prefix(8)).sock"
        let received = ReceivedEvents()
        let server = HookSocketServer(path: path) { event in received.append(event) }
        try server.start()
        defer { server.stop() }
        for _ in 0..<50 where !server.isListening { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.isListening)

        let curl = URL(fileURLWithPath: "/usr/bin/curl")
        let health = try await ProcessRunner.run(executable: curl, arguments: ["-s", "-m", "2", "--unix-socket", path, "http://mimamori/health"])
        #expect(health.stdoutText == "ok\n")

        let json = #"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/repo","tool_name":"Edit","tool_use_id":"t1","tool_input":{"file_path":"a.swift"}}"#
        let post = try await ProcessRunner.run(
            executable: curl,
            arguments: ["-s", "-m", "2", "-o", "/dev/null", "-w", "%{http_code}", "-H", "Expect:", "-H", "Content-Type: application/json",
                        "--unix-socket", path, "--data-binary", "@-", "http://mimamori/event"],
            stdin: Data(json.utf8))
        #expect(post.stdoutText == "204")
        for _ in 0..<50 where received.count == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(received.count == 1)
        #expect(received.first?.toolName == "Edit")
        #expect(received.first?.filePath == "/repo/a.swift")

        let bad = try await ProcessRunner.run(
            executable: curl,
            arguments: ["-s", "-m", "2", "-o", "/dev/null", "-w", "%{http_code}", "-H", "Expect:", "--unix-socket", path, "--data-binary", "{}", "http://mimamori/event"])
        #expect(bad.stdoutText == "400")
        #expect(server.receivedEvents == 1)
    }

    private final class ReceivedEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [HookEvent] = []
        func append(_ event: HookEvent) { lock.lock(); events.append(event); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return events.count }
        var first: HookEvent? { lock.lock(); defer { lock.unlock() }; return events.first }
    }
}

@Suite("Session placement")
struct SessionPlacementTests {
    @Test func aReadElsewhereDoesNotMoveAPlacedSession() {
        var placement = SessionPlacement()
        // Hermes edits in backend: firm.
        let edit = placement.place(session: "h1", cwdMatch: nil, pathMatch: "/p/backend", changesFiles: true)
        #expect(edit == .init(worktree: "/p/backend", movedFrom: nil))
        // It reads a file in frontend: stays in backend.
        let read = placement.place(session: "h1", cwdMatch: nil, pathMatch: "/p/frontend", changesFiles: false)
        #expect(read.worktree == "/p/backend")
        // An event with no path at all follows the session.
        #expect(placement.place(session: "h1", cwdMatch: nil, pathMatch: nil, changesFiles: false).worktree == "/p/backend")
    }

    @Test func changingFilesElsewhereMovesTheSession() {
        var placement = SessionPlacement()
        _ = placement.place(session: "h1", cwdMatch: nil, pathMatch: "/p/backend", changesFiles: true)
        let write = placement.place(session: "h1", cwdMatch: nil, pathMatch: "/p/frontend", changesFiles: true)
        #expect(write == .init(worktree: "/p/frontend", movedFrom: "/p/backend"))
    }

    @Test func aReadPlacesOnlyUntilSomethingFirmerArrives() {
        var placement = SessionPlacement()
        // First sign of the session is a read: place it there for now.
        #expect(placement.place(session: "h1", cwdMatch: nil, pathMatch: "/p/frontend", changesFiles: false).worktree == "/p/frontend")
        // A later read elsewhere may still move a tentative placement.
        let reread = placement.place(session: "h1", cwdMatch: nil, pathMatch: "/p/backend", changesFiles: false)
        #expect(reread == .init(worktree: "/p/backend", movedFrom: "/p/frontend"))
        // A working directory always wins and is firm.
        _ = placement.place(session: "h1", cwdMatch: "/p/mimamori", pathMatch: nil, changesFiles: false)
        #expect(placement.place(session: "h1", cwdMatch: nil, pathMatch: "/p/backend", changesFiles: false).worktree == "/p/mimamori")
    }

    @Test func eventsWithoutASessionStillPlaceByPath() {
        var placement = SessionPlacement()
        #expect(placement.place(session: nil, cwdMatch: nil, pathMatch: "/p/a", changesFiles: false).worktree == "/p/a")
        #expect(placement.place(session: nil, cwdMatch: nil, pathMatch: nil, changesFiles: true).worktree == nil)
    }

    @Test func theRecordedDirectoryPlacesASessionBeforeAnyTool() {
        var placement = SessionPlacement()
        // A turn starts: no path yet, but Hermes records the session working in backend.
        #expect(placement.place(session: "h1", cwdMatch: nil, pathMatch: nil, changesFiles: false, homeMatch: "/p/backend").worktree == "/p/backend")
        // A read elsewhere does not move it.
        #expect(placement.place(session: "h1", cwdMatch: nil, pathMatch: "/p/frontend", changesFiles: false, homeMatch: "/p/backend").worktree == "/p/backend")
        // A change elsewhere does, and sticks.
        let write = placement.place(session: "h1", cwdMatch: nil, pathMatch: "/p/frontend", changesFiles: true, homeMatch: "/p/backend")
        #expect(write == .init(worktree: "/p/frontend", movedFrom: "/p/backend"))
        #expect(placement.place(session: "h1", cwdMatch: nil, pathMatch: nil, changesFiles: false, homeMatch: "/p/backend").worktree == "/p/frontend")
    }

    @Test func theRecordedDirectoryIsLookedUpOnlyWhenNeeded() {
        var placement = SessionPlacement()
        var lookups = 0
        func home() -> String? { lookups += 1; return "/p/backend" }
        _ = placement.place(session: "h1", cwdMatch: "/p/mimamori", pathMatch: nil, changesFiles: false, homeMatch: home())
        _ = placement.place(session: "h1", cwdMatch: nil, pathMatch: nil, changesFiles: false, homeMatch: home())
        #expect(lookups == 0)
        // Nor for events that name no session.
        #expect(placement.place(session: nil, cwdMatch: nil, pathMatch: nil, changesFiles: false, homeMatch: home()).worktree == nil)
        #expect(lookups == 0)
        _ = placement.place(session: "h2", cwdMatch: nil, pathMatch: nil, changesFiles: false, homeMatch: home())
        #expect(lookups == 1)
    }
}

@Suite("Hermes session records")
struct HermesSessionTests {
    /// A database shaped like Hermes's state.db, as far as Mimamori reads it.
    private func database(_ statements: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mimamori-hermes-\(UUID().uuidString).db")
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        for statement in statements {
            try #require(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK, "\(statement)")
        }
        return url
    }

    @Test func readsWhereASessionWorks() throws {
        let url = try database([
            "PRAGMA journal_mode=WAL",
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, cwd TEXT, git_repo_root TEXT)",
            "INSERT INTO sessions VALUES ('20260903_173947_d73992', 'tui', '/Users/x/Projects/backend', '/Users/x/Projects/backend')",
            "INSERT INTO sessions VALUES ('repo-only', 'cli', NULL, '/Users/x/Projects/frontend')",
            "INSERT INTO sessions VALUES ('nowhere', 'local', '', NULL)",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(HermesSessions.directory(forSession: "20260903_173947_d73992", in: url) == "/Users/x/Projects/backend")
        #expect(HermesSessions.directory(forSession: "repo-only", in: url) == "/Users/x/Projects/frontend")
        #expect(HermesSessions.directory(forSession: "nowhere", in: url) == nil)
        // Not written yet: its first turn has not started.
        #expect(HermesSessions.directory(forSession: "new", in: url) == nil)
        // Quotes in an id are data, not SQL.
        #expect(HermesSessions.directory(forSession: "x' OR '1'='1", in: url) == nil)
    }

    @Test func anUnexpectedDatabaseReadsAsUnknown() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("mimamori-missing-\(UUID().uuidString).db")
        #expect(HermesSessions.directory(forSession: "s", in: missing) == nil)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let other = try database(["CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT)", "INSERT INTO sessions VALUES ('s', 't')"])
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(HermesSessions.directory(forSession: "s", in: other) == nil)
    }
}

@Suite("Agent turns")
struct AgentTurnTests {
    private func event(_ name: HookEvent.Name, tool: String? = nil, id: String? = nil, path: String? = nil,
                       message: String? = nil, agent: AgentKind = .claudeCode, at seconds: TimeInterval) -> HookEvent {
        HookEvent(name: name, rawName: name.rawValue, agent: agent, sessionID: "s", cwd: "/repo", toolName: tool, toolUseID: id,
                  filePath: path, summary: path, message: message, receivedAt: Date(timeIntervalSince1970: 1000 + seconds))
    }

    @Test func remembersTheTaskAndTheTurnsSteps() {
        var machine = AgentStatusMachine()
        _ = machine.apply(event(.userPromptSubmit, message: "first task", at: 0))
        _ = machine.apply(event(.preToolUse, tool: "Read", id: "r1", path: "/repo/a.swift", at: 1))
        _ = machine.apply(event(.stop, at: 2))
        _ = machine.apply(event(.userPromptSubmit, message: "add a discount", at: 10))
        _ = machine.apply(event(.preToolUse, tool: "Edit", id: "e1", path: "/repo/Cart.swift", at: 11))
        _ = machine.apply(event(.postToolUse, tool: "Edit", id: "e1", at: 12))
        _ = machine.apply(event(.preToolUse, tool: "Bash", id: "b1", at: 13))
        var status = machine.status!
        #expect(status.task == "add a discount")
        #expect(status.turnToolCalls.map(\.toolName) == ["Edit", "Bash"])

        // Once the turn ends its task and steps stay visible as the last turn's.
        _ = machine.apply(event(.stop, at: 20))
        status = machine.status!
        #expect(status.turnStartedAt == nil)
        #expect(status.task == "add a discount")
        #expect(status.turnToolCalls.map(\.toolName) == ["Edit", "Bash"])
    }

    @Test func joinsATurnAlreadyUnderWay() {
        // Mimamori (re)started mid-turn: no prompt, just tool calls.
        var machine = AgentStatusMachine()
        _ = machine.apply(event(.preToolUse, tool: "Read", id: "r1", path: "/repo/a.swift", at: 5))
        _ = machine.apply(event(.postToolUse, tool: "Read", id: "r1", at: 6))
        _ = machine.apply(event(.preToolUse, tool: "Edit", id: "e1", path: "/repo/a.swift", at: 7))
        var status = machine.status!
        #expect(status.turnStartedAt == Date(timeIntervalSince1970: 1005))
        #expect(status.toolCallsThisTurn == 2)
        #expect(status.turnToolCalls.map(\.toolName) == ["Read", "Edit"])
        #expect(status.task == nil)

        // The next prompt starts a turn of its own.
        _ = machine.apply(event(.stop, at: 8))
        _ = machine.apply(event(.userPromptSubmit, message: "next", at: 10))
        _ = machine.apply(event(.preToolUse, tool: "Bash", id: "b1", at: 11))
        status = machine.status!
        #expect(status.turnStartedAt == Date(timeIntervalSince1970: 1010))
        #expect(status.toolCallsThisTurn == 1)
        #expect(status.turnToolCalls.map(\.toolName) == ["Bash"])
    }

    @Test func repeatedModelCallsKeepTheTask() {
        var machine = AgentStatusMachine()
        _ = machine.apply(event(.userPromptSubmit, message: "theme the checkout", agent: .hermes, at: 0))
        _ = machine.apply(event(.preToolUse, tool: "terminal", id: "t1", agent: .hermes, at: 1))
        // Hermes fires its prompt hook before every model call; answering a question has no message.
        _ = machine.apply(event(.userPromptSubmit, message: "theme the checkout", agent: .hermes, at: 2))
        _ = machine.apply(event(.userPromptSubmit, agent: .hermes, at: 3))
        #expect(machine.status?.task == "theme the checkout")
        #expect(machine.status?.turnToolCalls.count == 1)
    }

    @Test func toolCategoriesSpanAgents() {
        #expect(AgentToolCategory(toolName: "Edit") == .edit)
        #expect(AgentToolCategory(toolName: "write_file") == .edit)
        #expect(AgentToolCategory(toolName: "Bash") == .command)
        #expect(AgentToolCategory(toolName: "terminal") == .command)
        #expect(AgentToolCategory(toolName: "Read") == .read)
        #expect(AgentToolCategory(toolName: "Grep") == .search)
        #expect(AgentToolCategory(toolName: "WebFetch") == .web)
        #expect(AgentToolCategory(toolName: "browser_navigate") == .web)
        #expect(AgentToolCategory(toolName: "Task") == .subagent)
        #expect(AgentToolCategory(toolName: "AskUserQuestion") == .question)
        #expect(AgentToolCategory(toolName: "mcp__notion__search") == .other)
    }

    @Test func findsTheParentProcess() {
        #expect(ProcessInspector.parentPID(of: getpid()) == getppid())
        #expect(ProcessInspector.parentPID(of: -1) == nil)
    }
}

@Suite("Permission requests")
struct PermissionRequestTests {
    private func event(_ name: HookEvent.Name, tool: String? = nil, id: String? = nil, summary: String? = nil,
                       message: String? = nil, type: String? = nil, agentID: String? = nil, batch: [String] = [],
                       at seconds: TimeInterval) -> HookEvent {
        HookEvent(name: name, rawName: name.rawValue, sessionID: "s1", cwd: "/repo", toolName: tool, toolUseID: id,
                  summary: summary, message: message, notificationType: type, agentID: agentID, batchToolUseIDs: batch,
                  receivedAt: Date(timeIntervalSince1970: 1000 + seconds))
    }

    /// A turn with `xcodebuild test` waiting on your permission.
    private func waitingMachine() -> AgentStatusMachine {
        var machine = AgentStatusMachine()
        _ = machine.apply(event(.userPromptSubmit, message: "run the tests", at: 0))
        _ = machine.apply(event(.preToolUse, tool: "Bash", id: "t1", summary: "xcodebuild test", at: 1))
        _ = machine.apply(event(.permissionRequest, tool: "Bash", summary: "xcodebuild test", at: 1.1))
        return machine
    }

    @Test func parsesTheEventsThatEndAToolCall() throws {
        let failure = try #require(HookEventParser.parse(Data(#"{"hook_event_name":"PostToolUseFailure","cwd":"/repo","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"swift test"},"error":"Exit code 1\nerror: no such module","is_interrupt":false,"agent_id":"a7"}"#.utf8)))
        #expect(failure.name == .postToolUseFailure)
        #expect(failure.toolUseID == "t1")
        #expect(failure.message == "Exit code 1")
        #expect(failure.agentID == "a7")
        #expect(!failure.isInterrupt)
        let batch = try #require(HookEventParser.parse(Data(#"{"hook_event_name":"PostToolBatch","cwd":"/repo","tool_calls":[{"tool_name":"Bash","tool_input":{},"tool_use_id":"t1"},{"tool_name":"Read","tool_input":{},"tool_use_id":"t2"}]}"#.utf8)))
        #expect(batch.name == .postToolBatch)
        #expect(batch.batchToolUseIDs == ["t1", "t2"])
        let stopFailure = try #require(HookEventParser.parse(Data(#"{"hook_event_name":"StopFailure","cwd":"/repo","error":"rate_limit"}"#.utf8)))
        #expect(stopFailure.name == .stopFailure)
        #expect(stopFailure.message == "rate_limit")
        let denied = try #require(HookEventParser.parse(Data(#"{"hook_event_name":"PermissionDenied","cwd":"/repo","tool_name":"Bash","tool_use_id":"t3","tool_input":{"command":"rm -rf build"},"reason":"destructive"}"#.utf8)))
        #expect(denied.name == .permissionDenied)
    }

    @Test func aRequestBelongsToTheCallThatAskedForIt() throws {
        let machine = waitingMachine()
        let status = try #require(machine.status)
        #expect(status.activity == .needsPermission(tool: "Bash", detail: "xcodebuild test"))
        #expect(status.pendingPermission?.callID == "t1")
        #expect(status.commandAwaitingPermission?.command == "xcodebuild test")
    }

    @Test func approvingShowsTheCommandRunning() {
        var machine = waitingMachine()
        // Claude Code's reminder six seconds in neither changes the details nor makes a second entry.
        let reminder = machine.apply(event(.notification, message: "Claude needs your permission to use Bash", type: "permission_prompt", at: 7))
        #expect(reminder.isEmpty)
        #expect(machine.status?.activity == .needsPermission(tool: "Bash", detail: "xcodebuild test"))
        let approved = machine.noteApproved(at: Date(timeIntervalSince1970: 1009))
        #expect(approved)
        #expect(machine.status?.activity == .working(tool: "Bash", detail: "xcodebuild test"))
        #expect(machine.status?.pendingPermission == nil)
        #expect(machine.status?.commandAwaitingPermission == nil)
        let again = machine.noteApproved()
        #expect(!again)
    }

    @Test func aFailedCommandSettlesThePermission() throws {
        var machine = waitingMachine()
        _ = machine.apply(event(.postToolUseFailure, tool: "Bash", id: "t1", message: "Exit code 65", at: 40))
        #expect(machine.status?.activity == .working(tool: nil, detail: nil))
        let call = try #require(machine.status?.recentToolCalls.last)
        #expect(call.finishedAt != nil && call.failed)
    }

    @Test func aDeniedCallIsSettledByItsBatch() throws {
        var machine = waitingMachine()
        _ = machine.apply(event(.postToolBatch, batch: ["t1"], at: 5))
        #expect(machine.status?.activity == .working(tool: nil, detail: nil))
        let call = try #require(machine.status?.recentToolCalls.last)
        #expect(call.finishedAt != nil && !call.failed)
    }

    @Test func otherSubagentsDoNotSettleIt() {
        var machine = AgentStatusMachine()
        _ = machine.apply(event(.userPromptSubmit, at: 0))
        _ = machine.apply(event(.preToolUse, tool: "Bash", id: "a-1", summary: "git push", agentID: "a", at: 1))
        _ = machine.apply(event(.permissionRequest, tool: "Bash", summary: "git push", agentID: "a", at: 1.1))
        // Subagent b keeps working while a waits on you.
        _ = machine.apply(event(.preToolUse, tool: "Read", id: "b-1", summary: "README.md", agentID: "b", at: 2))
        _ = machine.apply(event(.postToolUse, tool: "Read", id: "b-1", agentID: "b", at: 3))
        _ = machine.apply(event(.postToolBatch, agentID: "b", batch: ["b-1"], at: 3.1))
        #expect(machine.status?.activity.needsAttention == true)
        #expect(machine.status?.recentToolCalls.first { $0.id == "b-1" }?.finishedAt != nil)
        _ = machine.apply(event(.postToolUse, tool: "Bash", id: "a-1", agentID: "a", at: 9))
        #expect(machine.status?.activity == .working(tool: nil, detail: nil))
    }

    @Test func theSameAgentMovingOnSettlesIt() {
        var machine = waitingMachine()
        // An install without the batch event: the agent's next call still shows it was answered.
        _ = machine.apply(event(.preToolUse, tool: "Read", id: "t2", summary: "Package.swift", at: 5))
        #expect(machine.status?.activity == .working(tool: "Read", detail: "Package.swift"))
        #expect(machine.status?.pendingPermission == nil)
    }

    @Test func aReminderAloneNamesTheTool() {
        var machine = AgentStatusMachine()
        _ = machine.apply(event(.notification, message: "Claude needs your permission to use Write", type: "permission_prompt", at: 0))
        #expect(machine.status?.activity == .needsPermission(tool: "Write", detail: "Claude needs your permission to use Write"))
        // Not a shell command Mimamori can look for.
        #expect(machine.status?.commandAwaitingPermission == nil)
    }

    @Test func aTurnEndingOnAnErrorIsReady() throws {
        var machine = AgentStatusMachine()
        _ = machine.apply(event(.userPromptSubmit, at: 0))
        _ = machine.apply(event(.preToolUse, tool: "Bash", id: "t1", summary: "swift build", at: 1))
        let notes = machine.apply(event(.stopFailure, message: "rate_limit", at: 20))
        #expect(machine.status?.activity == .ready)
        #expect(notes.first?.title.contains("error") == true)
        #expect(notes.first?.detail?.contains("rate limit") == true)
        #expect(try #require(machine.status?.recentToolCalls.last).finishedAt != nil)
    }

    @Test func aNewTurnClosesStepsAnInterruptLeftOpen() throws {
        var machine = waitingMachine()
        // Pressing Esc ends the turn without a Stop; the next prompt starts afresh.
        _ = machine.apply(event(.userPromptSubmit, message: "never mind", at: 30))
        #expect(machine.status?.activity == .working(tool: nil, detail: nil))
        #expect(try #require(machine.status?.recentToolCalls.first).finishedAt != nil)
    }
}

@Suite("Approved command probe")
struct ClaudeCommandProbeTests {
    @Test func needleMatchesHowClaudeCodeQuotesTheCommand() {
        let line = "git commit -m 'it'\"'\"'s done' && echo ok"
        let needle = ClaudeCommandProbe.needle(forFirstLine: "cat <<'EOF' > notes.txt")
        #expect(needle == #"eval 'cat <<'"'"'EOF'"'"' > notes.txt"#)
        let script = #"source ~/.claude/shell-snapshots/snapshot-zsh-1.sh && eval 'cat <<'"'"'EOF'"'"' > notes.txt"# + "\nhi\nEOF' < /dev/null && pwd -P >| /tmp/claude-1a2b-cwd"
        #expect(ClaudeCommandProbe.isRunning(needle, arguments: ["/bin/zsh", "-c", script]))
        #expect(!ClaudeCommandProbe.isRunning(needle, arguments: ["/bin/zsh", script]))
        #expect(!ClaudeCommandProbe.isRunning(ClaudeCommandProbe.needle(forFirstLine: line), arguments: ["/bin/zsh", "-c", script]))
    }

    @Test func findsARunningShellStartedAfterTheRequest() throws {
        let line = "sleep 3; echo mimamori-probe-\(UUID().uuidString.prefix(8))"
        let asked = Date().addingTimeInterval(-0.5)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-c", "eval '\(line)' < /dev/null"]
        shell.standardOutput = FileHandle.nullDevice
        try shell.run()
        defer { shell.terminate() }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(ClaudeCommandProbe.running([line: asked]) == [line])
        // A request made after the shell started is not answered by it.
        #expect(ClaudeCommandProbe.running([line: Date().addingTimeInterval(5)]).isEmpty)
        #expect(ClaudeCommandProbe.running([:]).isEmpty)
    }
}

@Suite("Claude hooks updates")
struct ClaudeHooksUpdateTests {
    let command = ClaudeHooksConfig.command(socketPath: "/Users/someone/Library/Application Support/Mimamori/mimamori.sock")

    @Test func anOlderInstallIsOutdated() {
        var older = ClaudeHooksConfig.install(into: [:], command: command)
        var hooks = older["hooks"] as! [String: Any]
        for name in ["PostToolUseFailure", "PostToolBatch", "PermissionDenied", "StopFailure"] { hooks.removeValue(forKey: name) }
        older["hooks"] = hooks
        #expect(ClaudeHooksConfig.isOutdated(in: older, command: command))
        let updated = ClaudeHooksConfig.install(into: older, command: command)
        #expect(ClaudeHooksConfig.isInstalled(in: updated))
        #expect(!ClaudeHooksConfig.isOutdated(in: updated, command: command))
        // Hooks aimed at another socket (another Mimamori, a test run) are not ours to update.
        let other = ClaudeHooksConfig.command(socketPath: "/tmp/elsewhere/mimamori.sock")
        #expect(!ClaudeHooksConfig.isOutdated(in: older, command: other))
        #expect(!ClaudeHooksConfig.isOutdated(in: [:], command: command))
    }
}

@Suite("Claude session files")
struct ClaudeSessionFileTests {
    private func record(_ json: String) -> ClaudeSessionRecord? {
        ClaudeSessionFiles.parse(Data(json.utf8))
    }

    @Test func readsWhatClaudeCodeRecords() throws {
        let busy = try #require(record(#"{"pid":27738,"sessionId":"4cb4b3ff","cwd":"/Users/me/acme-store","startedAt":1793028052343,"kind":"interactive","status":"busy","updatedAt":1793074792322,"statusUpdatedAt":1793074792000}"#))
        #expect(busy.pid == 27738)
        #expect(busy.sessionID == "4cb4b3ff")
        #expect(busy.statusUpdatedAt == Date(timeIntervalSince1970: 1_793_074_792))
        #expect(busy.startedAt == Date(timeIntervalSince1970: 1_793_028_052.343))
        #expect(busy.activity == .working(tool: nil, detail: nil))
        #expect(record(#"{"pid":1,"sessionId":"s","status":"idle"}"#)?.activity == .ready)
        #expect(record(#"{"pid":1,"sessionId":"s","status":"waiting","waitingFor":"permission prompt"}"#)?.activity == .needsPermission(tool: "", detail: nil))
        #expect(record(#"{"pid":1,"sessionId":"s","status":"waiting","waitingFor":"input needed"}"#)?.activity == .askedQuestion(detail: nil))
        // Older versions record no status; the session still ties to its process.
        let quiet = try #require(record(#"{"pid":1,"sessionId":"s","updatedAt":1000}"#))
        #expect(quiet.activity == nil)
        #expect(quiet.statusUpdatedAt == Date(timeIntervalSince1970: 1))
        #expect(record(#"{"pid":1,"status":"idle"}"#) == nil)
        #expect(record(#"{"sessionId":"s","status":"idle"}"#) == nil)
        #expect(record("not json") == nil)
    }

    @Test func ignoresAFileLeftByAnEarlierProcess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimamori-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"pid":4242,"sessionId":"s1","startedAt":1000000,"status":"idle"}"#.utf8)
            .write(to: directory.appendingPathComponent("4242.json"))
        #expect(ClaudeSessionFiles.record(for: 4242, startedAt: Date(timeIntervalSince1970: 999), in: directory)?.sessionID == "s1")
        // The pid now belongs to a process started long after that session.
        #expect(ClaudeSessionFiles.record(for: 4242, startedAt: Date(timeIntervalSince1970: 5000), in: directory) == nil)
        #expect(ClaudeSessionFiles.record(for: 4243, startedAt: nil, in: directory) == nil)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func scannerTiesAClaudeProcessToItsSession() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mimamori-scan-\(UUID().uuidString)")
        let worktree = base.appendingPathComponent("repo")
        let sessions = base.appendingPathComponent("sessions")
        let package = base.appendingPathComponent("claude-code")
        for directory in [worktree, sessions, package] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: base) }
        // A stand-in for Claude Code: a script in a claude-code package is taken for it, as
        // `node …/claude-code/cli.js` is. (A copied system binary is killed on launch.)
        let script = package.appendingPathComponent("cli.py")
        try Data("import time\ntime.sleep(30)\n".utf8).write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]
        process.currentDirectoryURL = worktree
        try process.run()
        defer { process.terminate() }
        let pid = process.processIdentifier
        let now = Int(Date().timeIntervalSince1970 * 1000)
        try Data(#"{"pid":\#(pid),"sessionId":"s-scan","startedAt":\#(now),"status":"busy","statusUpdatedAt":\#(now)}"#.utf8)
            .write(to: sessions.appendingPathComponent("\(pid).json"))
        try await Task.sleep(for: .milliseconds(500))

        let scanner = AgentScanner(claudeSessions: sessions)
        // As the process reports it: /private/var, not /var.
        let directory = try #require(ProcessInspector.currentDirectory(of: pid))
        #expect(directory.hasSuffix("/repo"))
        // Python can take a while to start on a busy machine; scan until it shows.
        var inside = await scanner.scan(worktrees: [directory])
        for _ in 0..<50 where inside.byWorktree[directory]?.contains(where: { $0.pid == pid }) != true {
            try await Task.sleep(for: .milliseconds(100))
            inside = await scanner.scan(worktrees: [directory])
        }
        let found = try #require(inside.byWorktree[directory]?.first { $0.pid == pid },
                                 "\(pid) runs \(ProcessInspector.executablePath(of: pid) ?? "?") \(ProcessInspector.arguments(of: pid))")
        #expect(found.kind == .claudeCode)
        #expect(found.claudeSession?.sessionID == "s-scan")
        // Outside every watched worktree it is still found, to follow its session.
        let outside = await scanner.scan(worktrees: ["/nonexistent/path"])
        #expect(outside.elsewhere.first { $0.pid == pid }?.claudeSession?.sessionID == "s-scan")
    }
}

@Suite("Session processes")
struct SessionProcessTests {
    private func process(_ pid: Int32, in directory: String, session: String? = nil) -> AgentProcess {
        AgentProcess(pid: pid, kind: .claudeCode, executable: "/usr/local/bin/claude", workingDirectory: directory,
                     startedAt: Date(timeIntervalSince1970: 0), cpuLoad: 0,
                     claudeSession: session.map { ClaudeSessionRecord(pid: pid, sessionID: $0, status: "idle") })
    }

    @Test func aProcessCountsWhereItsSessionWorks() {
        // The session started in the repository and moved into one of its worktrees.
        let scan = AgentScan(byWorktree: ["/repo": [process(1, in: "/repo", session: "moved"), process(2, in: "/repo", session: "stayed"),
                                                    process(3, in: "/repo")]],
                             elsewhere: [process(4, in: "/scratch", session: "visiting"), process(5, in: "/scratch", session: "away")])
        let found = scan.attributed(homes: ["moved": "/repo/.claude/worktrees/fix", "stayed": "/repo", "visiting": "/repo"])
        #expect(found["/repo"]?.map(\.pid).sorted() == [2, 3, 4])
        #expect(found["/repo/.claude/worktrees/fix"]?.map(\.pid) == [1])
        #expect(!found.values.contains { $0.contains { $0.pid == 5 } })
    }
}

@Suite("Session file statuses")
struct SessionFileStatusTests {
    private func record(_ status: String, waitingFor: String? = nil, session: String = "s1", at seconds: TimeInterval) -> ClaudeSessionRecord {
        ClaudeSessionRecord(pid: 7, sessionID: session, status: status, waitingFor: waitingFor,
                            statusUpdatedAt: Date(timeIntervalSince1970: 1000 + seconds))
    }

    private func event(_ name: HookEvent.Name, session: String = "s1", tool: String? = nil, at seconds: TimeInterval) -> HookEvent {
        HookEvent(name: name, rawName: name.rawValue, sessionID: session, cwd: "/repo", toolName: tool, toolUseID: tool.map { "\($0)-1" },
                  summary: nil, message: nil, receivedAt: Date(timeIntervalSince1970: 1000 + seconds))
    }

    @Test func takesTheRecordedStatusUntilHooksReport() throws {
        var machine = AgentStatusMachine()
        let changed1 = machine.adopt(record("idle", at: 0))
        #expect(changed1)
        var status = try #require(machine.status)
        #expect(status.activity == .ready)
        #expect(status.fromSessionFile)
        #expect(status.sessionID == "s1")
        #expect(status.since == Date(timeIntervalSince1970: 1000))
        let changed2 = machine.adopt(record("idle", at: 0))
        #expect(!changed2)
        // Follows the record while the hooks stay silent.
        let changed3 = machine.adopt(record("waiting", waitingFor: "permission prompt", at: 5))
        #expect(changed3)
        #expect(machine.status?.activity == .needsPermission(tool: "", detail: nil))
        #expect(machine.status?.activity.title == "needs permission")
        let changed4 = machine.noteApproved(at: Date(timeIntervalSince1970: 1006))
        #expect(changed4)
        #expect(machine.status?.activity == .working(tool: nil, detail: nil))
        // The session's first hook event takes over, and the record no longer overrides it.
        _ = machine.apply(event(.preToolUse, tool: "Bash", at: 10))
        status = try #require(machine.status)
        #expect(!status.fromSessionFile)
        #expect(status.activity == .working(tool: "Bash", detail: nil))
        let changed5 = machine.adopt(record("idle", at: 11))
        #expect(!changed5)
        #expect(machine.status?.activity == .working(tool: "Bash", detail: nil))
    }

    @Test func anotherSessionsRecordReplacesTheStatus() {
        var machine = AgentStatusMachine()
        _ = machine.apply(event(.sessionEnd, session: "old", at: 0))
        let changed6 = machine.adopt(record("busy", session: "new", at: 1))
        #expect(changed6)
        #expect(machine.status?.sessionID == "new")
        #expect(machine.status?.fromSessionFile == true)
        #expect(machine.status?.activity == .working(tool: nil, detail: nil))
        // A status Mimamori does not know changes nothing.
        let changed7 = machine.adopt(ClaudeSessionRecord(pid: 7, sessionID: "other", status: "parked"))
        #expect(!changed7)
        #expect(machine.status?.sessionID == "new")
    }
}
