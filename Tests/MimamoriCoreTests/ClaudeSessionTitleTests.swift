import Foundation
import Testing
@testable import MimamoriCore

@Suite("Claude Code session titles")
struct ClaudeSessionTitleTests {
    private func transcript(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mimamori-title-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let message = #"{"type":"user","message":{"role":"user","content":"go"},"sessionId":"s1"}"#

    @Test func aTitleYouGaveWinsOverClaudeCodesOwn() throws {
        let url = try transcript([
            #"{"type":"ai-title","aiTitle":"Disk usage check","sessionId":"s1"}"#,
            message,
            #"{"type":"custom-title","customTitle":"Weekly disk cleanup check","sessionId":"s1"}"#,
            #"{"type":"agent-name","agentName":"Weekly disk cleanup check","sessionId":"s1"}"#,
            #"{"type":"ai-title","aiTitle":"Remove archived caches","sessionId":"s1"}"#,
            message,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClaudeSessionTitle.read(transcript: url) == "Weekly disk cleanup check")
    }

    @Test func withoutOneTheNewestOfClaudeCodesOwnIsUsed() throws {
        let url = try transcript([
            #"{"type":"ai-title","aiTitle":"First idea","sessionId":"s1"}"#,
            message,
            #"{"type":"ai-title","aiTitle":"Hermes permission prompt false positives","sessionId":"s1"}"#,
            message,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClaudeSessionTitle.read(transcript: url) == "Hermes permission prompt false positives")
    }

    @Test func noTitleOrNoFileReadsAsNone() throws {
        let url = try transcript([message, message])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClaudeSessionTitle.read(transcript: url) == nil)
        #expect(ClaudeSessionTitle.read(transcript: url.appendingPathExtension("missing")) == nil)
        let blank = try transcript([#"{"type":"custom-title","customTitle":"  ","sessionId":"s1"}"#])
        defer { try? FileManager.default.removeItem(at: blank) }
        #expect(ClaudeSessionTitle.read(transcript: blank) == nil)
    }

    @Test func onlyTheEndOfALongTranscriptIsRead() throws {
        // A title cut through by the start of the window is skipped, not misread.
        let title = #"{"type":"custom-title","customTitle":"Old title","sessionId":"s1"}"#
        let filler = String(repeating: message + "\n", count: 400)
        let url = try transcript([title, filler, #"{"type":"ai-title","aiTitle":"Recent","sessionId":"s1"}"#, message])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClaudeSessionTitle.read(transcript: url) == "Old title")
        #expect(ClaudeSessionTitle.read(transcript: url, tailLength: 4096) == "Recent")
        let cut = Data(title.utf8).dropFirst(10) + Data("\n".utf8)
        #expect(ClaudeSessionTitle.title(inTail: Data(cut), fromStart: false) == nil)
    }

    @Test func aTitleIsKeptToOneShortLine() throws {
        let long = String(repeating: "word ", count: 40)
        let url = try transcript([#"{"type":"custom-title","customTitle":"Two\nlines","sessionId":"s1"}"#, message])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ClaudeSessionTitle.read(transcript: url) == "Two lines")
        let longURL = try transcript([#"{"type":"ai-title","aiTitle":"\#(long)","sessionId":"s1"}"#])
        defer { try? FileManager.default.removeItem(at: longURL) }
        let read = try #require(ClaudeSessionTitle.read(transcript: longURL))
        #expect(read.count == ClaudeSessionTitle.maxLength)
        #expect(read.hasSuffix("…"))
    }

    @Test func theStatusKeepsTheTitle() {
        var machine = AgentStatusMachine()
        let early = machine.setTitle("Before any event")
        #expect(!early)  // nothing to title yet
        _ = machine.apply(HookEvent(name: .userPromptSubmit, rawName: "UserPromptSubmit", agent: .claudeCode,
                                    sessionID: "s1", cwd: "/repo", message: "go"))
        let first = machine.setTitle("Weekly disk cleanup check")
        let again = machine.setTitle("Weekly disk cleanup check")
        #expect(first)
        #expect(!again)
        #expect(machine.status?.title == "Weekly disk cleanup check")
    }
}
