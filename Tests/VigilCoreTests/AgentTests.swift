import Foundation
import Testing
@testable import VigilCore

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
        let found = await scanner.scan(worktrees: [parent, cwd])
        // Longest prefix wins: the exact cwd, not its parent.
        #expect(found[cwd]?.contains { $0.pid == pid } == true)
        #expect(found[parent]?.contains { $0.pid == pid } != true)
        let none = await scanner.scan(worktrees: ["/nonexistent/path"])
        #expect(none.isEmpty)
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
        #expect(pre.filePath == "/repo/src/a.py")
        #expect(pre.isMutatingTool)

        let llm = try #require(parse(#"{"hook_event_name":"pre_llm_call","tool_name":null,"tool_input":null,"session_id":"sess_1","cwd":"/repo","extra":{"user_message":"fix the build"}}"#))
        #expect(llm.name == .userPromptSubmit)
        #expect(llm.message == "fix the build")

        let approval = try #require(parse(#"{"hook_event_name":"pre_approval_request","tool_name":"terminal","tool_input":{"command":"git push"},"cwd":"/repo","extra":{}}"#))
        #expect(approval.name == .permissionRequest)
        #expect(approval.summary == "git push")

        let human = try #require(parse(#"{"hook_event_name":"on_human_input_request","cwd":"/repo","extra":{"prompt":"Which branch?"}}"#))
        #expect(human.name == .notification)
        #expect(human.message?.contains("waiting for your input") == true)

        let verify = try #require(parse(#"{"hook_event_name":"pre_verify","cwd":"/repo","extra":{}}"#))
        #expect(verify.name == .stop)
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
        #expect(machine.status?.activity == .waitingForInput)
    }
}

@Suite("Agent status machine")
struct AgentStatusMachineTests {
    private func event(_ name: HookEvent.Name, tool: String? = nil, id: String? = nil, path: String? = nil,
                       message: String? = nil, at seconds: TimeInterval) -> HookEvent {
        HookEvent(name: name, rawName: name.rawValue, sessionID: "s1", cwd: "/repo", toolName: tool, toolUseID: id,
                  filePath: path, summary: path, message: message, receivedAt: Date(timeIntervalSince1970: 1000 + seconds))
    }

    @Test func followsATurn() {
        var machine = AgentStatusMachine()
        _ = machine.apply(event(.sessionStart, at: 0))
        #expect(machine.status?.activity == .waitingForInput)
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
        #expect(machine.status?.activity == .waitingForInput)
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
        _ = machine.apply(event(.notification, message: "Claude is waiting for your input", at: 0))
        #expect(machine.status?.activity == .waitingForInput)
        _ = machine.apply(event(.notification, tool: "Bash", message: "Claude needs your permission to use Bash", at: 1))
        if case .needsPermission(let tool, _) = machine.status!.activity { #expect(tool == "Bash") } else { Issue.record("expected needsPermission") }
    }
}

@Suite("Claude hooks config")
struct ClaudeHooksConfigTests {
    let command = ClaudeHooksConfig.command(socketPath: FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Vigil/vigil.sock")

    @Test func commandIsPortableAndSafe() {
        #expect(command.contains("$HOME/Library/Application Support/Vigil/vigil.sock"))
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
    let script = "~/.hermes/agent-hooks/vigil.sh"

    @Test func appendsAndRemovesADelimitedBlock() throws {
        let original = "model:\n  default: foo\nhooks_auto_accept: false\n"
        let installed = try #require(HermesHooksConfig.install(into: original, scriptPath: script))
        #expect(installed.hasPrefix(original))
        #expect(installed.contains("\nhooks:\n  on_session_start:\n    - command: \"\(script)\"\n"))
        #expect(installed.contains("  pre_tool_call:\n    - command: \"\(script)\"\n      timeout: 5\n"))
        #expect(HermesHooksConfig.isInstalled(in: installed))
        // Vigil's own block does not count as a user-owned hooks: key.
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

    @Test func scriptIsSafe() {
        let text = HermesHooksConfig.script(socketPath: FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Vigil/vigil.sock")
        #expect(text.hasPrefix("#!/bin/sh"))
        #expect(text.contains("$HOME/Library/Application Support/Vigil/vigil.sock"))
        #expect(text.contains("/event/hermes"))
        #expect(text.contains("exit 0"))
    }
}

@Suite("Hook socket server", .serialized)
struct HookSocketServerTests {
    @Test func receivesEventsFromCurl() async throws {
        let path = NSTemporaryDirectory() + "vigil-test-\(UUID().uuidString.prefix(8)).sock"
        let received = ReceivedEvents()
        let server = HookSocketServer(path: path) { event in received.append(event) }
        try server.start()
        defer { server.stop() }
        for _ in 0..<50 where !server.isListening { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.isListening)

        let curl = URL(fileURLWithPath: "/usr/bin/curl")
        let health = try await ProcessRunner.run(executable: curl, arguments: ["-s", "-m", "2", "--unix-socket", path, "http://vigil/health"])
        #expect(health.stdoutText == "ok\n")

        let json = #"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/repo","tool_name":"Edit","tool_use_id":"t1","tool_input":{"file_path":"a.swift"}}"#
        let post = try await ProcessRunner.run(
            executable: curl,
            arguments: ["-s", "-m", "2", "-o", "/dev/null", "-w", "%{http_code}", "-H", "Expect:", "-H", "Content-Type: application/json",
                        "--unix-socket", path, "--data-binary", "@-", "http://vigil/event"],
            stdin: Data(json.utf8))
        #expect(post.stdoutText == "204")
        for _ in 0..<50 where received.count == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(received.count == 1)
        #expect(received.first?.toolName == "Edit")
        #expect(received.first?.filePath == "/repo/a.swift")

        let bad = try await ProcessRunner.run(
            executable: curl,
            arguments: ["-s", "-m", "2", "-o", "/dev/null", "-w", "%{http_code}", "-H", "Expect:", "--unix-socket", path, "--data-binary", "{}", "http://vigil/event"])
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
