import Foundation
import Testing
@testable import MimamoriShared

/// The iPhone's background log, which says when and why the app stopped running.
@Suite("The companion's background log")
struct CompanionEventLogTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func keepsTheNewestWithinItsLimits() {
        var log = CompanionEventLog()
        for index in 0..<(CompanionEventLog.maxEntries + 20) {
            log.add(.audio, "entry \(index)", at: start.addingTimeInterval(Double(index)))
        }
        #expect(log.entries.count == CompanionEventLog.maxEntries)
        #expect(log.entries.first?.text == "entry 20")
        // Anything older than three days goes when the next entry comes.
        log.add(.app, "much later", at: start.addingTimeInterval(CompanionEventLog.maxAge + 1000))
        #expect(log.entries.map(\.text) == ["much later"])
    }

    @Test func aLongSilenceInTheBackgroundIsAGap() throws {
        var log = CompanionEventLog()
        log.heartbeat(at: start)
        log.heartbeat(at: start.addingTimeInterval(60))
        let back = start.addingTimeInterval(60 + 2 * 3600 + 7 * 60)
        let found = log.cameToFront(at: back)
        #expect(found)
        let entry = try #require(log.entries.last)
        #expect(entry.kind == .app)
        #expect(entry.text.contains("2 h 7 min"))
        #expect(entry.text.hasPrefix("Wasn't running from "))
        // In front, it doesn't beat: the next return finds nothing.
        #expect(log.lastHeartbeat == nil)
        let again = log.cameToFront(at: back.addingTimeInterval(9999))
        #expect(!again)
    }

    @Test func aShortWaitIsNoGap() {
        var log = CompanionEventLog()
        log.heartbeat(at: start)
        let found = log.cameToFront(at: start.addingTimeInterval(CompanionEventLog.gapAfter - 1))
        #expect(!found)
        #expect(log.entries.isEmpty)
    }

    @Test func comingBackWithoutBeatingIsNoGap() {
        // It never ran in the background (staying connected off): nothing to report.
        var log = CompanionEventLog()
        let found = log.cameToFront(at: start)
        #expect(!found)
        #expect(log.entries.isEmpty)
    }

    @Test func startingAfterRunningInTheBackgroundSaysItWasEnded() {
        var log = CompanionEventLog()
        log.heartbeat(at: start)
        log.started(at: start.addingTimeInterval(40 * 60), version: "1.5.0 (9)")
        #expect(log.entries.count == 2)
        #expect(log.entries[0].text.hasPrefix("Started afresh."))
        #expect(log.entries[0].text.contains("40 min ago"))
        #expect(log.entries[1].text == "Started (1.5.0 (9))")
        #expect(log.lastHeartbeat == nil)
    }

    @Test func durationsReadNaturally() {
        #expect(CompanionEventLog.duration(42) == "42 s")
        #expect(CompanionEventLog.duration(12 * 60 + 5) == "12 min")
        #expect(CompanionEventLog.duration(2 * 3600) == "2 h")
        #expect(CompanionEventLog.duration(2 * 3600 + 7 * 60 + 30) == "2 h 7 min")
    }

    @Test func survivesTheTripThroughItsFile() throws {
        var log = CompanionEventLog()
        log.add(.keepAlive, "Playing silence", at: start)
        log.heartbeat(at: start.addingTimeInterval(60))
        let data = try JSONEncoder().encode(log)
        #expect(try JSONDecoder().decode(CompanionEventLog.self, from: data) == log)
    }

    @Test func sharesAsTextOldestFirst() {
        var log = CompanionEventLog()
        log.add(.audio, "Interruption began", at: start)
        log.add(.audio, "Interruption ended", at: start.addingTimeInterval(5))
        let lines = log.text(timeZone: TimeZone(identifier: "UTC")!).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("[audio]  Interruption began"))
        #expect(lines[0].hasPrefix("2026-"))
    }
}
