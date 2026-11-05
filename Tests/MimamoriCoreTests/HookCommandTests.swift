import Foundation
import Testing
@testable import MimamoriCore

@Suite("Hook commands")
struct HookCommandTests {
    private let home = "/Users/sample"
    private var socket: String { home + "/Library/Application Support/Mimamori/mimamori.sock" }

    /// Exactly what Mimamori 1.0.0 and 1.1.0 wrote into settings.json.
    private static let command100 = "curl -s -m 1 -H 'Expect:' -H 'Content-Type: application/json' --unix-socket \"$HOME/Library/Application Support/Mimamori/mimamori.sock\" --data-binary @- http://mimamori/event >/dev/null 2>&1 || true"
    private static let permission100 = "curl -s -m 595 -H 'Expect:' -H 'Content-Type: application/json' --unix-socket \"$HOME/Library/Application Support/Mimamori/mimamori.sock\" --data-binary @- http://mimamori/permission 2>/dev/null || true"

    private func settings(command: String, permission: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in ClaudeHooksConfig.events {
            let waits = event.name == "PermissionRequest"
            var entry: [String: Any] = ["hooks": [["type": "command", "command": waits ? permission : command, "timeout": waits ? 600 : 5]]]
            if let matcher = event.matcher { entry["matcher"] = matcher }
            hooks[event.name] = [entry]
        }
        // One of the user's own, which stays.
        hooks["Stop"] = (hooks["Stop"] as? [[String: Any]] ?? []) + [["hooks": [["type": "command", "command": "say done"]]]]
        return ["model": "opus", "hooks": hooks]
    }

    private func commands(in settings: [String: Any]) -> [String] {
        (settings["hooks"] as? [String: Any] ?? [:]).values.flatMap { value in
            (value as? [[String: Any]] ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        }
    }

    @Test func readsTheSocketAndVersionBack() {
        let command = ClaudeHooksConfig.command(socketPath: socket, home: home)
        #expect(command.contains("--unix-socket \"$HOME/Library/Application Support/Mimamori/mimamori.sock\""))
        #expect(HookCommand.parse(command, home: home) == HookCommand.Installed(socketPath: socket, version: HookCommand.version))
        #expect(HookCommand.parse(Self.command100, home: home) == HookCommand.Installed(socketPath: socket, version: 1))
        #expect(HookCommand.parse(Self.permission100, home: home)?.version == 1)
        #expect(HookCommand.parse("curl --unix-socket ${HOME}/a/mimamori.sock -H 'Mimamori-Hook: 7'", home: home)
            == HookCommand.Installed(socketPath: home + "/a/mimamori.sock", version: 7))
        #expect(HookCommand.parse("curl --unix-socket '/tmp/odd \"name\"/mimamori.sock'", home: home)?.socketPath == "/tmp/odd \"name\"/mimamori.sock")
        #expect(HookCommand.parse("say done", home: home) == nil)
        // A path with characters the shell treats specially comes back as it went in.
        let odd = "/tmp/a \"b\" $c `d`/mimamori.sock"
        #expect(HookCommand.parse(HookCommand.event(socketPath: odd, home: home), home: home)?.socketPath == odd)
    }

    @Test func everyCommandIsBuiltTheSameWay() {
        let event = HookCommand.event(socketPath: socket, home: home)
        #expect(ClaudeHooksConfig.command(socketPath: socket, home: home) == event)
        #expect(event == "curl -s -m 1 -H 'Expect:' -H 'Content-Type: application/json' -H 'Mimamori-Hook: \(HookCommand.version)' --unix-socket \"$HOME/Library/Application Support/Mimamori/mimamori.sock\" --data-binary @- http://mimamori/event >/dev/null 2>&1 || true")
        #expect(ClaudeHooksConfig.permissionCommand(socketPath: socket, home: home).hasSuffix("http://mimamori/permission 2>/dev/null || true"))
        #expect(AgentHookRecipe.command(socketPath: socket, agent: "codex", home: home)
            == HookCommand.event(socketPath: socket, address: "/event?agent=codex", home: home))
        #expect(HermesHooksConfig.script(socketPath: socket, home: home)
            .contains(HookCommand.curl(socketPath: socket, address: "/event/hermes", timeout: 1, home: home) + " >/dev/null 2>&1\nexit 0\n"))
    }

    // MARK: Upgrading hooks an older Mimamori installed

    @Test func hooksFrom100AreRecognisedAndUpgraded() {
        let socket = HookCommand.defaultHome + "/Library/Application Support/Mimamori/mimamori.sock"
        let command = ClaudeHooksConfig.command(socketPath: socket)
        let permission = ClaudeHooksConfig.permissionCommand(socketPath: socket)
        let old = settings(command: Self.command100, permission: Self.permission100)

        #expect(ClaudeHooksConfig.isInstalled(in: old))
        #expect(ClaudeHooksConfig.answersPermissions(in: old))
        #expect(ClaudeHooksConfig.isOutdated(in: old, command: command, permissionCommand: permission))
        #expect(ClaudeHooksConfig.isOutdated(in: old, command: command))

        let upgraded = ClaudeHooksConfig.install(into: old, command: command, permissionCommand: permission)
        let all = commands(in: upgraded)
        #expect(!all.contains(Self.command100) && !all.contains(Self.permission100))
        #expect(all.filter { $0 == command }.count == ClaudeHooksConfig.events.count - 1)
        #expect(all.filter { $0 == permission }.count == 1)
        #expect(all.contains("say done"))
        #expect(upgraded["model"] as? String == "opus")
        #expect(!ClaudeHooksConfig.isOutdated(in: upgraded, command: command, permissionCommand: permission))
    }

    @Test func hooksForAnotherSocketOrANewerVersionAreLeftAlone() {
        let socket = HookCommand.defaultHome + "/Library/Application Support/Mimamori/mimamori.sock"
        let elsewhere = ClaudeHooksConfig.command(socketPath: "/tmp/scratch-copy/mimamori.sock")
        let old = settings(command: Self.command100, permission: Self.permission100)
        #expect(!ClaudeHooksConfig.isOutdated(in: old, command: elsewhere))

        // A later Mimamori wrote these; going back to an older one does not undo them.
        let newer = ClaudeHooksConfig.command(socketPath: socket).replacingOccurrences(of: "Mimamori-Hook: \(HookCommand.version)", with: "Mimamori-Hook: 99")
        let later = settings(command: newer, permission: newer.replacingOccurrences(of: "/event", with: "/permission"))
        #expect(!ClaudeHooksConfig.isOutdated(in: later, command: ClaudeHooksConfig.command(socketPath: socket),
                                               permissionCommand: ClaudeHooksConfig.permissionCommand(socketPath: socket)))
    }
}

/// Runs every command Mimamori writes the way an agent does, with `/bin/sh` and the event on
/// standard input, against a real socket: the commands always succeed, so only this shows that
/// they work.
@Suite("Hook commands, run", .serialized)
struct HookCommandRunTests {
    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [HookEvent] = []
        func append(_ event: HookEvent) { lock.withLock { events.append(event) } }
        var all: [HookEvent] { lock.withLock { events } }
    }

    /// A home folder of its own, so the commands' `$HOME` is tested too. Socket paths are short.
    private struct Place {
        let home = NSTemporaryDirectory() + "mh-\(UUID().uuidString.prefix(8))"
        var socket: String { home + "/s/mimamori.sock" }
        init() throws { try FileManager.default.createDirectory(atPath: home + "/s", withIntermediateDirectories: true) }
        func remove() { try? FileManager.default.removeItem(atPath: home) }
    }

    private func start(_ place: Place) async throws -> (HookSocketServer, Received) {
        let received = Received()
        let server = HookSocketServer(path: place.socket) { received.append($0) }
        try server.start()
        for _ in 0..<50 where !server.isListening { try await Task.sleep(for: .milliseconds(20)) }
        try #require(server.isListening)
        return (server, received)
    }

    private func run(_ command: String, input: String, home: String) async throws -> ProcessResult {
        try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command],
                                    environment: ["HOME": home, "PATH": "/usr/bin:/bin"], stdin: Data(input.utf8), timeout: .seconds(20))
    }

    private func waitFor(_ count: Int, in received: Received) async throws {
        for _ in 0..<100 where received.all.count < count { try await Task.sleep(for: .milliseconds(20)) }
    }

    private static let preToolUse = #"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/repo","tool_name":"Edit","tool_input":{"file_path":"a.swift"}}"#

    @Test func claudeCodesCommandDeliversTheEvent() async throws {
        let place = try Place()
        defer { place.remove() }
        let (server, received) = try await start(place)
        defer { server.stop() }
        let command = ClaudeHooksConfig.command(socketPath: place.socket, home: place.home)
        #expect(command.contains("\"$HOME/s/mimamori.sock\""))

        let result = try await run(command, input: Self.preToolUse, home: place.home)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        try await waitFor(1, in: received)
        let event = try #require(received.all.first)
        #expect(event.name == .preToolUse)
        #expect(event.agent == .claudeCode)
        #expect(event.sessionID == "s1")
        #expect(event.filePath == "/repo/a.swift")
    }

    @Test func thePermissionCommandPrintsTheAnswer() async throws {
        let place = try Place()
        defer { place.remove() }
        let (server, received) = try await start(place)
        defer { server.stop() }
        server.answersPermissions = true
        let command = ClaudeHooksConfig.permissionCommand(socketPath: place.socket, home: place.home)
        let request = #"{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/repo","tool_name":"Bash","tool_input":{"command":"npm run migrate"}}"#

        async let result = run(command, input: request, home: place.home)
        for _ in 0..<100 where received.all.last?.permissionRequestID == nil { try await Task.sleep(for: .milliseconds(20)) }
        let id = try #require(received.all.last?.permissionRequestID)
        #expect(server.permissions.answer(id, .allow))
        let finished = try await result
        #expect(finished.status == 0)
        #expect(finished.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == PermissionAnswer.allow.hookResponse)
        #expect(received.all.last?.name == .permissionRequest)
    }

    @Test func theHermesScriptDeliversTheEvent() async throws {
        let place = try Place()
        defer { place.remove() }
        let (server, received) = try await start(place)
        defer { server.stop() }
        let script = URL(fileURLWithPath: place.home + "/mimamori.sh")
        try HermesHooksConfig.script(socketPath: place.socket, home: place.home).write(to: script, atomically: true, encoding: .utf8)
        let json = #"{"hook_event_name":"pre_tool_call","session_id":"h1","cwd":"/repo","tool_name":"terminal","tool_input":{"command":"ls"},"extra":{"tool_call_id":"c1"}}"#

        let result = try await run("/bin/sh \"$HOME/mimamori.sh\"", input: json, home: place.home)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        try await waitFor(1, in: received)
        #expect(received.all.first?.agent == .hermes)
        #expect(received.all.first?.sessionID == "h1")
    }

    @Test func everyOtherAgentsCommandDeliversTheEvent() async throws {
        let place = try Place()
        defer { place.remove() }
        let (server, received) = try await start(place)
        defer { server.stop() }
        for (index, recipe) in AgentHookRecipe.allCases.enumerated() {
            let command = AgentHookRecipe.command(socketPath: place.socket, agent: recipe.agentName, home: place.home)
            let result = try await run(command, input: Self.preToolUse, home: place.home)
            #expect(result.status == 0)
            try await waitFor(index + 1, in: received)
            #expect(received.all.last?.agent.id == AgentKind.named(recipe.agentName)?.id, "\(recipe.title)")
        }
        #expect(received.all.count == AgentHookRecipe.allCases.count)
    }

    @Test func withMimamoriNotRunningEveryCommandStillSucceedsAtOnce() async throws {
        let place = try Place()
        defer { place.remove() }
        let script = place.home + "/mimamori.sh"
        try HermesHooksConfig.script(socketPath: place.socket, home: place.home).write(toFile: script, atomically: true, encoding: .utf8)
        let commands = [
            ClaudeHooksConfig.command(socketPath: place.socket, home: place.home),
            ClaudeHooksConfig.permissionCommand(socketPath: place.socket, home: place.home),
            AgentHookRecipe.command(socketPath: place.socket, agent: "codex", home: place.home),
            "/bin/sh \"$HOME/mimamori.sh\"",
        ]
        for command in commands {
            let started = Date()
            let result = try await run(command, input: Self.preToolUse, home: place.home)
            #expect(result.status == 0, "\(command)")
            #expect(result.stdout.isEmpty)
            #expect(Date().timeIntervalSince(started) < 5)
        }
    }
}
