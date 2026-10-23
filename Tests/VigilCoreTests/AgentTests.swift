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
