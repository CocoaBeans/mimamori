import Foundation
import Testing
@testable import VigilCore

@Suite("Activity log")
struct ActivityLogTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vigil-activity-\(UUID().uuidString)")
            .appendingPathComponent("activity.jsonl")
    }

    private func entry(_ title: String, at date: Date, kind: ActivityKind = .modified) -> ActivityEntry {
        ActivityEntry(date: date, worktreePath: "/w", kind: kind, path: "a.swift", title: title, detail: "d",
                      additions: 1, deletions: 2, severity: .warning)
    }

    @Test func entriesSurviveAReload() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date()
        let log = ActivityLog(url: url, retention: 86_400)
        #expect(log.load(now: now).isEmpty)
        log.append([entry("one", at: now.addingTimeInterval(-20)), entry("two", at: now.addingTimeInterval(-10))])
        log.append([entry("three", at: now)])
        log.flush()

        let reloaded = ActivityLog(url: url, retention: 86_400).load(now: now)
        #expect(reloaded.map(\.title) == ["one", "two", "three"])
        #expect(reloaded.first?.severity == .warning)
        #expect(reloaded.first?.additions == 1)
        #expect(abs((reloaded.last?.date.timeIntervalSince(now)) ?? 99) < 0.01)
    }

    @Test func oldEntriesAndOverflowAreDroppedAndTheFileCompacted() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date()
        let log = ActivityLog(url: url, retention: 3_600, maxEntries: 3)
        _ = log.load(now: now)
        log.append([entry("stale", at: now.addingTimeInterval(-7_200))]
                   + (1...4).map { entry("recent \($0)", at: now.addingTimeInterval(Double($0))) })
        log.flush()

        let kept = ActivityLog(url: url, retention: 3_600, maxEntries: 3).load(now: now)
        #expect(kept.map(\.title) == ["recent 2", "recent 3", "recent 4"])
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
    }

    @Test func damagedLinesAreSkipped() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date()
        let log = ActivityLog(url: url, retention: 86_400)
        _ = log.load(now: now)
        log.append([entry("good", at: now)])
        log.flush()
        // A line cut short, as a crash mid-write would leave it.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"title\":\"cut".utf8))
        try handle.close()

        let reloaded = ActivityLog(url: url, retention: 86_400).load(now: now)
        #expect(reloaded.map(\.title) == ["good"])
    }

    @Test func replaceAllRewritesAndClears() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date()
        let log = ActivityLog(url: url, retention: 86_400)
        _ = log.load(now: now)
        log.append([entry("a", at: now), entry("b", at: now)])
        log.replaceAll(with: [entry("b", at: now)])
        log.flush()
        #expect(ActivityLog(url: url, retention: 86_400).load(now: now).map(\.title) == ["b"])
        log.replaceAll(with: [])
        log.flush()
        #expect(ActivityLog(url: url, retention: 86_400).load(now: now).isEmpty)
    }

    @Test func compactsWhileRunning() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date()
        let log = ActivityLog(url: url, retention: 86_400, maxEntries: 10)
        _ = log.load(now: now)
        for index in 0..<16 {
            log.append([entry("e\(index)", at: now.addingTimeInterval(Double(index)))])
        }
        log.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count <= 15)   // compacted down to 10 once it passed 15, then appended to
        #expect(lines.last?.contains("e15") == true)
    }
}

@Suite("Activity entries")
struct ActivityEntryTests {
    @Test func agentWorkCoversEventsAndAttributedChanges() {
        let event = ActivityEntry(worktreePath: "/w", kind: .agentTool, title: "Claude Code: Edit")
        let attributed = ActivityEntry(worktreePath: "/w", kind: .modified, path: "a.swift", title: "a.swift", agent: "Claude Code")
        let plain = ActivityEntry(worktreePath: "/w", kind: .modified, path: "b.swift", title: "b.swift")
        #expect(event.isAgentWork)
        #expect(attributed.isAgentWork)
        #expect(!plain.isAgentWork)
    }

    @Test func entriesSavedBeforeTheAgentFieldStillLoad() throws {
        // A line written by a Vigil that had no agent field.
        let line = #"{"date":1792824429,"id":"984CEC4A-FEDE-49B3-9566-4CB2A703D231","kind":"modified","title":"a.swift","worktreePath":"/w"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let entry = try decoder.decode(ActivityEntry.self, from: Data(line.utf8))
        #expect(entry.agent == nil)
        #expect(entry.title == "a.swift")
    }
}
