import Foundation
import Testing
@testable import MimamoriCore

@Suite("Hook troubleshooting", .serialized)
struct HookDiagnosticsTests {
    private final class Notes: @unchecked Sendable {
        private let lock = NSLock()
        private var notes: [HookSocketServer.Note] = []
        private var events = 0
        func append(_ note: HookSocketServer.Note) { lock.lock(); notes.append(note); lock.unlock() }
        func received() { lock.lock(); events += 1; lock.unlock() }
        var all: [HookSocketServer.Note] { lock.lock(); defer { lock.unlock() }; return notes }
        var eventCount: Int { lock.lock(); defer { lock.unlock() }; return events }
    }

    private func post(_ body: String, to url: String, socket: String) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: ["-s", "-m", "2", "-o", "/dev/null", "-w", "%{http_code}", "-H", "Expect:", "-H", "Content-Type: application/json",
                        "--unix-socket", socket, "--data-binary", "@-", url],
            stdin: Data(body.utf8))
        return result.stdoutText
    }

    @Test func theSocketReportsWhatItTurnsDownAndTests() async throws {
        let path = NSTemporaryDirectory() + "mimamori-test-\(UUID().uuidString.prefix(8)).sock"
        let notes = Notes()
        let server = HookSocketServer(path: path) { _ in notes.received() }
        server.onNote = { notes.append($0) }
        try server.start()
        defer { server.stop() }
        for _ in 0..<50 where !server.isListening { try await Task.sleep(for: .milliseconds(20)) }

        // The wrong shape: JSON, but no event in it. Its keys are kept, never their values.
        #expect(try await post(#"{"payload":{"prompt":"secret plans"},"when":1}"#, to: "http://mimamori/event", socket: path) == "400")
        #expect(try await post("{}", to: "http://mimamori/events", socket: path) == "404")
        // A test goes through like a hook's post and is answered, but is no agent's event.
        #expect(try await post(#"{"hook_event_name":"MimamoriTest","mimamori_test":"t-42"}"#, to: "http://mimamori/event", socket: path) == "204")
        for _ in 0..<50 where notes.all.count < 3 { try await Task.sleep(for: .milliseconds(20)) }

        let rejections = notes.all.compactMap { if case .rejected(let r) = $0 { r } else { nil } }
        #expect(rejections.map(\.status) == [400, 404])
        #expect(rejections.first?.keys == ["payload", "when"])
        #expect(rejections.first?.target == "/event")
        #expect(rejections.last?.target == "POST /events")
        let tokens = notes.all.compactMap { if case .test(let token) = $0 { token } else { nil } }
        #expect(tokens == ["t-42"])
        #expect(notes.eventCount == 0)
        #expect(server.receivedEvents == 0)
    }

    @Test func entriesSayWhatBecameOfEachRequest() {
        let home = "/Users/someone"
        let at = Date(timeIntervalSince1970: 0)
        let placed = HookLogEntry(at: at, agent: .claudeCode, event: "PostToolUse", tool: "Bash",
                                  outcome: .placed(worktree: "/Users/someone/Projects/shop"))
        #expect(placed.title == "Claude Code · PostToolUse · Bash")
        #expect(placed.detail(home: home) == "→ ~/Projects/shop")
        #expect(!placed.isProblem)

        let unplaced = HookLogEntry(at: at, agent: .codex, event: "UserPromptSubmit",
                                    outcome: .unplaced(directory: "/Users/someone/elsewhere", held: true))
        #expect(unplaced.detail(home: home) == "Not placed: no watched worktree holds ~/elsewhere; held until the session's next event places it")
        #expect(unplaced.isProblem)

        let rejected = HookLogEntry(at: at, agent: nil, event: "",
                                    outcome: .rejected(HookRejection(status: 400, reason: "not a hook event", target: "/event?agent=aider", keys: [])))
        #expect(rejected.title == "Rejected request")
        #expect(rejected.detail(home: home) == "400: not a hook event (/event?agent=aider); the JSON is empty")
    }

    @Test func theReportShortensHomeAndListsRecentRequests() {
        var report = HookDiagnostics()
        report.app = "Mimamori 1.0 (1)"
        report.system = "macOS 26.4"
        report.socketPath = "/Users/someone/Library/Application Support/Mimamori/mimamori.sock"
        report.listening = true
        report.eventsReceived = 12
        report.eventsUnplaced = 2
        report.hooks = [("Claude Code", "installed in /Users/someone/.claude/settings.json")]
        report.detection = "on, every 3 s"
        report.watched = "2 repositories, 3 worktrees"
        report.contacts = [.init(agent: "Codex", events: 5, lastEventAt: Date(), lastEvent: "Stop", lastWorktree: nil)]
        report.recent = [HookLogEntry(at: Date(), agent: .codex, event: "Stop", outcome: .unplaced(directory: "/Users/someone/x", held: false))]
        let text = report.text(home: "/Users/someone")
        #expect(text.contains("Socket: listening at ~/Library/Application Support/Mimamori/mimamori.sock"))
        #expect(text.contains("Events: 12 since launch, 2 not placed in a watched worktree"))
        #expect(text.contains("Claude Code hooks: installed in ~/.claude/settings.json"))
        #expect(text.contains("Codex: 5 events, last Stop at"))
        #expect(text.contains("Not placed: no watched worktree holds ~/x"))
        #expect(!text.contains("/Users/someone"))
        // Only the home folder itself or what is inside it is shortened.
        #expect(HookDiagnostics.shorten("/Users/someoneelse/a", home: "/Users/someone") == "/Users/someoneelse/a")
        #expect(HookDiagnostics.shorten("/Users/someone", home: "/Users/someone") == "~")
    }
}

@Suite("Offering to watch repositories agents work in")
struct UnwatchedRepositoryFilterTests {
    @Test func skipsHomeTemporaryAndAgentFolders() {
        let filter = UnwatchedRepositoryFilter(home: "/Users/someone")
        #expect(filter.allows("/Users/someone/Projects/new-app"))
        #expect(filter.allows("/Users/someone/Projects/new-app/src"))
        #expect(filter.allows("/Volumes/Work/shop"))
        #expect(!filter.allows("/Users/someone"))
        #expect(!filter.allows("/Users"))
        #expect(!filter.allows("/"))
        #expect(!filter.allows("/Users/someone/.hermes"))
        #expect(!filter.allows("/Users/someone/.claude/projects/x"))
        #expect(!filter.allows("/tmp/experiment"))
        #expect(!filter.allows("/private/var/folders/7v/x/T/scratch"))
        #expect(!filter.allows("relative/path"))
        // Only the home folder's own dot folders: a dot folder deeper in is a project's own.
        #expect(filter.allows("/Users/someone/Projects/app/.github"))
    }
}
