import Foundation
import Testing
@testable import MimamoriCore

@Suite("Answering permission requests", .serialized)
struct PermissionTests {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [HookEvent] = []
        func append(_ event: HookEvent) { lock.withLock { events.append(event) } }
        var last: HookEvent? { lock.withLock { events.last } }
        var count: Int { lock.withLock { events.count } }
    }

    private func start() async throws -> (HookSocketServer, Events, String) {
        let path = NSTemporaryDirectory() + "mimamori-test-\(UUID().uuidString.prefix(8)).sock"
        let events = Events()
        let server = HookSocketServer(path: path) { events.append($0) }
        try server.start()
        for _ in 0..<50 where !server.isListening { try await Task.sleep(for: .milliseconds(20)) }
        return (server, events, path)
    }

    /// What the hook prints: the body of the reply, as Claude Code reads it.
    private func request(socket: String) async throws -> String {
        let body = #"{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/repo","tool_name":"Bash","tool_input":{"command":"npm run migrate"}}"#
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: ["-s", "-m", "10", "-H", "Expect:", "-H", "Content-Type: application/json",
                        "--unix-socket", socket, "--data-binary", "@-", "http://mimamori/permission"],
            stdin: Data(body.utf8))
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func answered(_ answer: PermissionAnswer?) async throws -> (printed: String, event: HookEvent?) {
        let (server, events, path) = try await start()
        defer { server.stop() }
        server.answersPermissions = true
        async let printed = request(socket: path)
        for _ in 0..<100 where events.last?.permissionRequestID == nil { try await Task.sleep(for: .milliseconds(20)) }
        let id = try #require(events.last?.permissionRequestID)
        server.permissions.answer(id, answer)
        server.permissions.answer(id, .allow)  // a second answer does not count
        return (try await printed, events.last)
    }

    @Test func allowingPrintsClaudeCodesAllowDecision() async throws {
        let (printed, event) = try await answered(.allow)
        #expect(printed == PermissionAnswer.allow.hookResponse)
        #expect(event?.name == .permissionRequest)
        #expect(event?.toolName == "Bash")
    }

    @Test func denyingPrintsTheDenyDecision() async throws {
        let (printed, _) = try await answered(.deny)
        #expect(printed == PermissionAnswer.deny.hookResponse)
        #expect(printed.contains(#""behavior":"deny""#))
    }

    @Test func lettingGoPrintsNothing() async throws {
        let (printed, _) = try await answered(nil)
        #expect(printed.isEmpty)
    }

    @Test func turnedOffItAnswersAtOnceWithNoDecision() async throws {
        let (server, events, path) = try await start()
        defer { server.stop() }
        server.answersPermissions = false
        let printed = try await request(socket: path)
        #expect(printed.isEmpty)
        #expect(events.count == 1)
        #expect(events.last?.permissionRequestID == nil)
        #expect(server.permissions.openCount == 0)
    }

    @Test func onlyPermissionRequestWaitsForAnAnswer() {
        let command = ClaudeHooksConfig.command(socketPath: "/tmp/mimamori.sock")
        let waiting = ClaudeHooksConfig.permissionCommand(socketPath: "/tmp/mimamori.sock")
        #expect(!waiting.contains(" >/dev/null") && waiting.contains("2>/dev/null"))  // its reply is the decision; only errors are silenced
        let old = ClaudeHooksConfig.install(into: [:], command: command)
        #expect(ClaudeHooksConfig.isInstalled(in: old))
        #expect(!ClaudeHooksConfig.answersPermissions(in: old))
        #expect(ClaudeHooksConfig.isOutdated(in: old, command: command, permissionCommand: waiting))
        #expect(!ClaudeHooksConfig.isOutdated(in: old, command: command))

        let new = ClaudeHooksConfig.install(into: old, command: command, permissionCommand: waiting)
        #expect(ClaudeHooksConfig.answersPermissions(in: new))
        #expect(!ClaudeHooksConfig.isOutdated(in: new, command: command, permissionCommand: waiting))
        let hooks = new["hooks"] as! [String: Any]
        let permission = (hooks["PermissionRequest"] as! [[String: Any]]).flatMap { $0["hooks"] as! [[String: Any]] }
        #expect(permission.count == 1)
        #expect(permission.first?["command"] as? String == waiting)
        #expect(permission.first?["timeout"] as? Int == 600)
        let stop = (hooks["Stop"] as! [[String: Any]]).flatMap { $0["hooks"] as! [[String: Any]] }
        #expect(stop.first?["command"] as? String == command)
        // Uninstalling removes the waiting command too.
        #expect(ClaudeHooksConfig.uninstall(from: new)["hooks"] == nil)
    }
}

@Suite("Claude Code ask rules")
struct ClaudePermissionRulesTests {
    let rules = ClaudePermissionRules(ask: [
        "Bash(git push *--force*)", "Bash(git reset --hard *)", "Bash(npm publish:*)", "WebFetch", "Edit(src/secrets/**)",
    ])

    @Test func shellCommandsMatchByWildcardOrPrefix() {
        #expect(rules.matchingAskRule(tool: "Bash", command: "git push origin main --force") == "Bash(git push *--force*)")
        #expect(rules.matchingAskRule(tool: "Bash", command: "git reset --hard HEAD~1") == "Bash(git reset --hard *)")
        #expect(rules.matchingAskRule(tool: "Bash", command: "npm publish --access public") == "Bash(npm publish:*)")
        #expect(rules.matchingAskRule(tool: "Bash", command: "git push origin main") == nil)
        #expect(rules.matchingAskRule(tool: "Bash", command: "npm test") == nil)
    }

    @Test func compoundCommandsMatchPartByPart() {
        #expect(rules.matchingAskRule(tool: "Bash", command: "cd repo && git push origin main --force") != nil)
        #expect(rules.matchingAskRule(tool: "Bash", command: "npm test; git reset --hard origin/main") != nil)
        #expect(rules.matchingAskRule(tool: "Bash", command: "echo ok\ngit push -u origin x --force-with-lease") != nil)
        #expect(rules.matchingAskRule(tool: "Bash", command: "cd repo && npm test | tee out.txt") == nil)
    }

    @Test func otherToolsMatchByNameAndErrTowardsWaiting() {
        #expect(rules.matchingAskRule(tool: "WebFetch", command: nil) == "WebFetch")
        // A specifier Mimamori doesn't read counts for every call of that tool.
        #expect(rules.matchingAskRule(tool: "Edit", command: nil) == "Edit(src/secrets/**)")
        #expect(rules.matchingAskRule(tool: "Write", command: nil) == nil)
        #expect(ClaudePermissionRules(ask: ["Bash"]).matchingAskRule(tool: "Bash", command: "ls") == "Bash")
    }

    @Test func readsTheAskRulesFromSettings() {
        let settings: [String: Any] = ["permissions": ["allow": ["Bash(ls)"], "ask": ["Bash(git clean *)"]], "model": "opus"]
        #expect(ClaudePermissionRules.askRules(in: settings) == ["Bash(git clean *)"])
        #expect(ClaudePermissionRules.askRules(in: [:]).isEmpty)
    }
}
