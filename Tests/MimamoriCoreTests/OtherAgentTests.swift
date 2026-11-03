import AppKit
import Foundation
import Testing
@testable import MimamoriCore

@Suite("Other agents' events")
struct AgentEventTranslatorTests {
    private func translate(_ json: String, agent: AgentKind? = nil, caller: HookCaller? = nil, eventName: String? = nil) -> HookEvent? {
        AgentEventTranslator.translate(Data(json.utf8), agent: agent, caller: caller, eventName: eventName)
    }

    @Test func codexUsesClaudeCodesNames() throws {
        let pre = try #require(translate(#"{"hook_event_name":"PreToolUse","session_id":"thr_1","turn_id":"t9","cwd":"/repo","tool_name":"apply_patch","tool_use_id":"c1","tool_input":{"command":"*** Begin Patch\n*** Update File: Sources/App.swift\n@@\n-old\n+new\n*** End Patch"}}"#))
        #expect(pre.agent == .codex)
        #expect(pre.name == .preToolUse)
        #expect(pre.filePath == "/repo/Sources/App.swift")
        #expect(pre.isMutatingTool)
        let interrupt = try #require(translate(#"{"hook_event_name":"Interrupt","session_id":"thr_1","turn_id":"t9","cwd":"/repo"}"#))
        #expect(interrupt.name == .stop)
        #expect(interrupt.rawName == "Interrupt")
    }

    /// What Codex 0.166 sends for a command that runs past its first wait: one PreToolUse from
    /// exec_command, nothing while write_stdin polls it, then one PostToolUse with exec_command's id
    /// once a poll sees it exit (Codex's own test: post_tool_use_blocks_when_exec_session_completes_via_write_stdin).
    @Test func codexLongCommandStaysRunningUntilItsOnePostToolUse() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func codex(_ json: String, at seconds: TimeInterval) throws -> HookEvent {
            try #require(AgentEventTranslator.translate(Data(json.utf8), agent: .codex, receivedAt: start.addingTimeInterval(seconds)))
        }
        let session = #""session_id":"thr_1","turn_id":"t1","cwd":"/repo""#
        var machine = AgentStatusMachine()
        _ = machine.apply(try codex(#"{"hook_event_name":"UserPromptSubmit",\#(session),"prompt":"Build it"}"#, at: 0))
        _ = machine.apply(try codex(#"{"hook_event_name":"PreToolUse",\#(session),"tool_name":"Bash","tool_use_id":"exec-1","tool_input":{"command":"swift build"}}"#, at: 1))

        // Ten minutes of polls send nothing: still working on the build, its step open, not quiet.
        var status = try #require(machine.status)
        #expect(status.activity == .working(tool: "Bash", detail: "swift build"))
        #expect(status.turnToolCalls.map(\.finishedAt) == [nil])
        let underway = TurnTimeline(calls: status.turnToolCalls, turnStartedAt: status.turnStartedAt, end: start.addingTimeInterval(601))
        #expect(underway.quietFor == nil)

        _ = machine.apply(try codex(#"{"hook_event_name":"PostToolUse",\#(session),"tool_name":"Bash","tool_use_id":"exec-1","tool_input":{"command":"swift build"},"tool_response":"Build complete!"}"#, at: 601))
        status = try #require(machine.status)
        #expect(status.turnToolCalls.count == 1)
        #expect(status.turnToolCalls.first?.finishedAt == start.addingTimeInterval(601))
        #expect(status.turnToolCalls.first?.failed == false)
        #expect(status.activity == .working(tool: nil, detail: nil))
    }

    /// A command still running when Codex's turn ends finishes in a later turn, when a poll there
    /// sees it exit: the turn's end closes the step, and the late PostToolUse changes nothing.
    @Test func codexCommandOutlivingItsTurnFinishesQuietly() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func codex(_ json: String, at seconds: TimeInterval) throws -> HookEvent {
            try #require(AgentEventTranslator.translate(Data(json.utf8), agent: .codex, receivedAt: start.addingTimeInterval(seconds)))
        }
        var machine = AgentStatusMachine()
        _ = machine.apply(try codex(#"{"hook_event_name":"UserPromptSubmit","session_id":"thr_1","turn_id":"t1","cwd":"/repo","prompt":"Start the server"}"#, at: 0))
        _ = machine.apply(try codex(#"{"hook_event_name":"PreToolUse","session_id":"thr_1","turn_id":"t1","cwd":"/repo","tool_name":"Bash","tool_use_id":"exec-1","tool_input":{"command":"npm run dev"}}"#, at: 1))
        _ = machine.apply(try codex(#"{"hook_event_name":"Stop","session_id":"thr_1","turn_id":"t1","cwd":"/repo"}"#, at: 20))
        #expect(machine.status?.activity == .ready)
        #expect(machine.status?.recentToolCalls.first?.finishedAt == start.addingTimeInterval(20))

        _ = machine.apply(try codex(#"{"hook_event_name":"UserPromptSubmit","session_id":"thr_1","turn_id":"t2","cwd":"/repo","prompt":"Stop the server"}"#, at: 300))
        _ = machine.apply(try codex(#"{"hook_event_name":"PostToolUse","session_id":"thr_1","turn_id":"t2","cwd":"/repo","tool_name":"Bash","tool_use_id":"exec-1","tool_input":{"command":"npm run dev"},"tool_response":"stopped"}"#, at: 310))
        let status = try #require(machine.status)
        #expect(status.activity == .working(tool: nil, detail: nil))
        #expect(status.recentToolCalls.count == 1)
        #expect(status.recentToolCalls.first?.finishedAt == start.addingTimeInterval(20))
        #expect(status.turnToolCalls.isEmpty)
    }

    @Test func geminiEventsMapOntoTheSameMoments() throws {
        let prompt = try #require(translate(#"{"hook_event_name":"BeforeAgent","session_id":"g1","cwd":"/repo","prompt":"add a login page\nwith tests"}"#))
        #expect(prompt.agent == .gemini)
        #expect(prompt.name == .userPromptSubmit)
        #expect(prompt.message == "add a login page")

        let before = try #require(translate(#"{"hook_event_name":"BeforeTool","session_id":"g1","cwd":"/repo","tool_name":"replace","tool_input":{"file_path":"/repo/a.swift"}}"#))
        #expect(before.name == .preToolUse)
        #expect(before.filePath == "/repo/a.swift")
        #expect(before.isMutatingTool)

        let failed = try #require(translate(#"{"hook_event_name":"AfterTool","session_id":"g1","cwd":"/repo","tool_name":"run_shell_command","tool_input":{"command":"make"},"tool_response":{"llmContent":"","error":"exit status 2"}}"#))
        #expect(failed.name == .postToolUseFailure)
        #expect(failed.message == "exit status 2")
        let succeeded = try #require(translate(#"{"hook_event_name":"AfterTool","session_id":"g1","cwd":"/repo","tool_name":"read_file","tool_input":{},"tool_response":{"llmContent":"ok"}}"#))
        #expect(succeeded.name == .postToolUse)

        let done = try #require(translate(#"{"hook_event_name":"AfterAgent","session_id":"g1","cwd":"/repo","prompt":"x","prompt_response":"done"}"#))
        #expect(done.name == .stop)
    }

    @Test func geminiPermissionAlertsNeedYou() throws {
        let before = try #require(translate(#"{"hook_event_name":"BeforeTool","session_id":"g1","cwd":"/repo","tool_name":"run_shell_command","tool_input":{"command":"rm -rf build"}}"#))
        let alert = try #require(translate(#"{"hook_event_name":"Notification","session_id":"g1","cwd":"/repo","notification_type":"ToolPermission","message":"Allow shell command?","details":{"tool_name":"run_shell_command","command":"rm -rf build"}}"#, agent: .gemini))
        let after = try #require(translate(#"{"hook_event_name":"AfterTool","session_id":"g1","cwd":"/repo","tool_name":"run_shell_command","tool_input":{"command":"rm -rf build"},"tool_response":{"llmContent":"ok"}}"#))
        var machine = AgentStatusMachine()
        _ = machine.apply(before)
        _ = machine.apply(alert)
        #expect(machine.status?.activity == .needsPermission(tool: "run_shell_command", detail: "rm -rf build"))
        #expect(machine.status?.agent == .gemini)
        // The step that waits is the one that asked.
        #expect(machine.status?.pendingPermission?.callID == machine.status?.recentToolCalls.last?.id)
        _ = machine.apply(after)
        #expect(machine.status?.activity == .working(tool: nil, detail: nil))
    }

    @Test func cursorEventsAreTranslated() throws {
        let common = #""conversation_id":"conv-1","generation_id":"gen-1","cursor_version":"2.4.0","workspace_roots":["/repo"]"#
        let pre = try #require(translate(#"{"hook_event_name":"preToolUse",\#(common),"tool_name":"Shell","tool_use_id":"u1","cwd":"/repo/sub","tool_input":{"command":"npm test"}}"#))
        #expect(pre.agent == .cursor)
        #expect(pre.name == .preToolUse)
        #expect(pre.sessionID == "conv-1")
        #expect(pre.cwd == "/repo/sub")
        #expect(pre.summary == "npm test")
        #expect(pre.isMutatingTool)

        let shell = try #require(translate(#"{"hook_event_name":"beforeShellExecution",\#(common),"command":"git status","cwd":"/repo","sandbox":false}"#))
        #expect(shell.name == .preToolUse)
        #expect(shell.toolName == "Shell")
        #expect(shell.summary == "git status")

        let mcp = try #require(translate(#"{"hook_event_name":"beforeMCPExecution",\#(common),"tool_name":"search","tool_input":"{\"query\":\"login bug\"}","mcp_server_name":"linear"}"#))
        #expect(mcp.summary == "login bug")

        let failedTurn = try #require(translate(#"{"hook_event_name":"stop",\#(common),"status":"error","loop_count":0}"#))
        #expect(failedTurn.name == .stopFailure)
        #expect(failedTurn.cwd == "/repo")
        let finished = try #require(translate(#"{"hook_event_name":"stop",\#(common),"status":"completed","loop_count":0}"#))
        #expect(finished.name == .stop)

        let edit = try #require(translate(#"{"hook_event_name":"afterFileEdit",\#(common),"file_path":"/repo/a.ts","edits":[]}"#))
        #expect(edit.name == .other)
    }

    @Test func plainNamesWorkForAnyAgent() throws {
        let named = try #require(AgentKind.named("My Agent"))
        let start = try #require(translate(#"{"event":"turn_start","session_id":"m1","cwd":"/repo","prompt":"tidy up"}"#, agent: named))
        #expect(start.agent.id == "my-agent")
        #expect(start.agent.displayName == "My Agent")
        #expect(start.name == .userPromptSubmit)
        #expect(start.message == "tidy up")

        let tool = try #require(translate(#"{"event":"tool_start","session_id":"m1","cwd":"/repo","tool":"edit","file_path":"src/a.py"}"#, agent: named))
        #expect(tool.name == .preToolUse)
        #expect(tool.toolName == "edit")
        #expect(tool.filePath == "/repo/src/a.py")

        let question = try #require(translate(#"{"event":"question","session_id":"m1","cwd":"/repo","message":"Which branch?"}"#, agent: named))
        var machine = AgentStatusMachine()
        _ = machine.apply(question)
        #expect(machine.status?.activity == .askedQuestion(detail: "Which branch?"))

        let unnamed = try #require(translate(#"{"event":"turn_end","cwd":"/repo"}"#))
        #expect(unnamed.agent == .unnamed)
        #expect(unnamed.name == .stop)
    }

    @Test func anotherSessionTakingOverStartsClean() throws {
        var machine = AgentStatusMachine()
        let codex = #""session_id":"codex-1","turn_id":"t1","cwd":"/repo""#
        _ = machine.apply(try #require(translate(#"{"hook_event_name":"UserPromptSubmit",\#(codex),"prompt":"Tighten the README"}"#, agent: .codex)))
        _ = machine.apply(try #require(translate(#"{"hook_event_name":"PreToolUse",\#(codex),"tool_name":"Bash","tool_use_id":"c1","tool_input":{"command":"make"}}"#, agent: .codex)))
        #expect(machine.status?.task == "Tighten the README")

        let cursor = #""conversation_id":"cur-1","cursor_version":"2.4.0","workspace_roots":["/repo"]"#
        _ = machine.apply(try #require(translate(#"{"hook_event_name":"preToolUse",\#(cursor),"tool_name":"Shell","tool_use_id":"u1","tool_input":{"command":"npm test"}}"#)))
        let status = try #require(machine.status)
        #expect(status.agent == .cursor)
        #expect(status.task == nil)
        #expect(status.turnToolCalls.map(\.toolName) == ["Shell"])
        #expect(status.recentToolCalls.first?.finishedAt != nil)  // Codex's step, kept for attribution
        #expect(status.activity == .working(tool: "Shell", detail: "npm test"))

        // A different agent counts as another session even when it names none.
        _ = machine.apply(try #require(translate(#"{"event":"turn_end","cwd":"/repo"}"#, agent: AgentKind.named("my-agent"))))
        #expect(machine.status?.agent.id == "my-agent")
        #expect(machine.status?.sessionID == nil)
        #expect(machine.status?.turnToolCalls.isEmpty == true)
    }

    @Test func anEventWithoutJSONTakesItsNameAndFolderFromTheCall() throws {
        let caller = HookCaller(pid: 4242, directory: "/repo")
        let event = try #require(AgentEventTranslator.translate(Data(), agent: AgentKind.named("aider"), caller: caller, eventName: "turn_end"))
        #expect(event.name == .stop)
        #expect(event.cwd == "/repo")
        #expect(event.agent == .aider)
        #expect(AgentEventTranslator.translate(Data(), caller: caller) == nil)
        #expect(AgentEventTranslator.translate(Data("not json".utf8), eventName: "turn_end") == nil)
    }

    @Test func decidesWhichAgentSentAnEvent() throws {
        let claudeShaped = #"{"hook_event_name":"PreToolUse","session_id":"s","cwd":"/repo","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        #expect(translate(claudeShaped)?.agent == .claudeCode)
        // The agent process that ran the hook beats a guess from the names…
        let gemini = HookCaller(pid: 10, agent: .gemini, agentPID: 9)
        #expect(translate(claudeShaped, caller: gemini)?.agent == .gemini)
        // …but only an agent that uses these names: Claude Code never sends BeforeTool, so a
        // Gemini-named event run from inside a Claude Code terminal is not Claude Code's.
        let geminiShaped = #"{"hook_event_name":"BeforeTool","session_id":"g","cwd":"/repo","tool_name":"read_file","tool_input":{}}"#
        #expect(translate(geminiShaped, caller: HookCaller(pid: 10, agent: .claudeCode))?.agent == .gemini)
        #expect(translate(#"{"event":"turn_end","cwd":"/repo"}"#, caller: HookCaller(pid: 10, agent: .claudeCode))?.agent == .unnamed)
        #expect(translate(#"{"event":"turn_end","cwd":"/repo"}"#, caller: HookCaller(pid: 10, agent: AgentKind(id: "foo", displayName: "foo")))?.agent.id == "foo")
        // …and the name the hook gives beats both.
        #expect(translate(claudeShaped, agent: .codex, caller: gemini)?.agent == .codex)
        // A payload that proves its agent beats the caller.
        let cursor = #"{"hook_event_name":"stop","conversation_id":"c","cursor_version":"2.4.0","workspace_roots":["/repo"],"status":"completed"}"#
        #expect(translate(cursor, caller: HookCaller(pid: 10, agent: .claudeCode))?.agent == .cursor)
        // The event name in the address beats the payload's.
        #expect(translate(claudeShaped, eventName: "turn_end")?.name == .stop)
    }

    @Test func hermesEventsStillTranslate() throws {
        let event = try #require(translate(#"{"hook_event_name":"pre_tool_call","session_id":"h1","cwd":"/Users/me/.hermes","tool_name":"write_file","tool_input":{"path":"/repo/a.md"},"extra":{"tool_call_id":"call_1"}}"#))
        #expect(event.agent == .hermes)
        #expect(event.name == .preToolUse)
        #expect(event.toolUseID == "call_1")
        #expect(event.rawName == "pre_tool_call")
    }

    @Test func namesResolveToKnownAgents() {
        #expect(AgentKind.named("codex") == .codex)
        #expect(AgentKind.named("Claude Code") == .claudeCode)
        #expect(AgentKind.named("claude-code") == .claudeCode)
        #expect(AgentKind.named("gemini-cli") == .gemini)
        #expect(AgentKind.named("Cursor") == .cursor)
        #expect(AgentKind.named("  ") == nil)
        #expect(AgentKind.named("ampersand")?.id == "ampersand")
    }
}

@Suite("Hook callers")
struct HookCallerTests {
    @Test func findsTheNearestAgentAmongAncestors() {
        // curl (40) ← sh (30) ← agent (20) ← launchd (1)
        let parents: [Int32: Int32] = [40: 30, 30: 20, 20: 1]
        let agents: [Int32: String] = [20: "agent", 1: "launchd"]
        let found = ProcessInspector.nearest(from: 40, parent: { parents[$0] }, match: { agents[$0] })
        #expect(found?.pid == 20)
        #expect(found?.kind == "agent")
        #expect(ProcessInspector.nearest(from: 40, limit: 1, parent: { parents[$0] }, match: { agents[$0] }) == nil)
        #expect(ProcessInspector.nearest(from: 40, parent: { parents[$0] }, match: { _ -> String? in nil }) == nil)
    }

    @Test func identifiesItsOwnProcessAsAnAgent() throws {
        let name = try #require(ProcessInspector.executablePath(of: getpid())).split(separator: "/").last.map(String.init) ?? ""
        let caller = HookCaller.identify(pid: getpid(), classifier: AgentClassifier(customNames: [name]))
        #expect(caller.agentPID == getpid())
        #expect(caller.agent?.id == name.lowercased())
        #expect(caller.directory == ProcessInspector.currentDirectory(of: getpid()))
    }
}

@Suite("Hook socket server, other agents", .serialized)
struct OtherAgentServerTests {
    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [HookEvent] = []
        func append(_ event: HookEvent) { lock.lock(); events.append(event); lock.unlock() }
        var all: [HookEvent] { lock.lock(); defer { lock.unlock() }; return events }
    }

    private func post(_ body: String, to url: String, socket: String) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: ["-s", "-m", "2", "-o", "/dev/null", "-w", "%{http_code}", "-H", "Expect:", "-H", "Content-Type: application/json",
                        "--unix-socket", socket, "--data-binary", "@-", url],
            stdin: Data(body.utf8))
        return result.stdoutText
    }

    @Test func namesTheAgentThatCalled() async throws {
        let path = NSTemporaryDirectory() + "mimamori-test-\(UUID().uuidString.prefix(8)).sock"
        let received = Received()
        let server = HookSocketServer(path: path) { received.append($0) }
        // curl runs as this test's child, so this test process stands in for the agent.
        let name = try #require(ProcessInspector.executablePath(of: getpid())).split(separator: "/").last.map(String.init) ?? ""
        server.classifier = AgentClassifier(customNames: [name])
        try server.start()
        defer { server.stop() }
        #expect(server.isListening)
        var info = stat()
        #expect(stat(path, &info) == 0 && info.st_mode & 0o777 == 0o600)

        let claudeShaped = #"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/repo","tool_name":"Edit","tool_input":{"file_path":"a.swift"}}"#
        #expect(try await post(claudeShaped, to: "http://mimamori/event", socket: path) == "204")
        #expect(try await post(claudeShaped, to: "http://mimamori/event?agent=codex", socket: path) == "204")
        #expect(try await post("", to: "http://mimamori/event?agent=aider&event=turn_end", socket: path) == "204")
        #expect(try await post("", to: "http://mimamori/event?agent=aider", socket: path) == "400")
        #expect(try await post("{}", to: "http://mimamori/nowhere", socket: path) == "404")
        for _ in 0..<50 where received.all.count < 3 { try await Task.sleep(for: .milliseconds(20)) }

        let events = received.all
        #expect(events.count == 3)
        #expect(events.first?.agent.id == name.lowercased())
        #expect(events.first?.filePath == "/repo/a.swift")
        #expect(events.dropFirst().first?.agent == .codex)
        let last = try #require(events.last)
        #expect(last.agent == .aider)
        #expect(last.name == .stop)
        #expect(last.cwd == ProcessInspector.currentDirectory(of: getpid()))
        #expect(server.receivedEvents == 3)
    }
}

@Suite("Hook setups for other agents")
struct AgentHookRecipeTests {
    private let socket = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Mimamori/mimamori.sock"

    @Test func everySetupIsValidAndCoversItsEvents() throws {
        for recipe in AgentHookRecipe.allCases where recipe != .other {
            let text = recipe.setup(socketPath: socket)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let hooks = try #require(object["hooks"] as? [String: Any])
            #expect(Set(hooks.keys) == Set(recipe.events))
            #expect(text.contains("?agent=\(recipe.agentName)"))
            // Every event name the setup subscribes to is one Mimamori understands.
            for event in recipe.events {
                let translated = AgentEventTranslator.translate(["hook_event_name": event, "cwd": "/repo"], agent: AgentKind.named(recipe.agentName))
                #expect(translated?.name != .other, "\(recipe.title) \(event)")
            }
        }
        #expect(AgentHookRecipe.cursor.setup(socketPath: socket).contains("\"version\" : 1"))
    }

    @Test func theCommandIsPortableQuotedAndNeverFails() {
        let command = AgentHookRecipe.command(socketPath: socket, agent: "Weird Name!")
        #expect(command.contains("\"$HOME/Library/Application Support/Mimamori/mimamori.sock\""))
        #expect(command.contains("'http://mimamori/event?agent=weird-name'"))
        #expect(command.hasSuffix("|| true"))
        #expect(AgentHookRecipe.other.setup(socketPath: socket, agent: "") .contains("?agent=agent'"))
    }
}

@Suite("Agent glyphs")
struct AgentGlyphTests {
    @Test func everyAgentHasASymbolThatExists() {
        let custom = [AgentKind.named("my-agent"), AgentKind.unnamed, AgentKind(id: "42", displayName: "42")].compactMap { $0 }
        for kind in AgentKind.known + custom {
            #expect(NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil) != nil, "\(kind.displayName): \(kind.symbolName)")
        }
        // Known agents each get their own.
        #expect(Set(AgentKind.known.map(\.symbolName)).count == AgentKind.known.count)
        #expect(AgentKind.named("my-agent")?.symbolName == "m.circle")
        #expect(AgentKind.symbolName(forDisplayName: "Codex") == "curlybraces")
        #expect(AgentKind.symbolName(forDisplayName: "Zed Agent") == "z.circle")
    }
}
