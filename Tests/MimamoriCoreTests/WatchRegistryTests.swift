import Foundation
import Testing
@testable import MimamoriCore

@MainActor
private final class FakeWatch {
    var ended = false
}

/// Holds a watch's start at its await until the test opens it.
@MainActor
private final class Gate {
    private var isOpen = false
    private var hasArrived = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    /// The start waits here until the gate opens.
    func pass() async {
        hasArrived = true
        arrivals.forEach { $0.resume() }
        arrivals = []
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Returns once a start is waiting at the gate.
    func arrival() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

@Suite("Watching repositories")
@MainActor
struct WatchRegistryTests {
    private func makeRegistry() -> WatchRegistry<String, FakeWatch> {
        WatchRegistry { $0.ended = true }
    }

    @Test func keepsTheWatchAStartMakes() async {
        let registry = makeRegistry()
        let watch = FakeWatch()
        await registry.start("garden") { watch }.value
        #expect(registry.watchedKeys == ["garden"])
        #expect(!registry.isStarting("garden"))
        #expect(!watch.ended)
    }

    @Test func aStartThatFindsNothingWatchesNothing() async {
        let registry = makeRegistry()
        await registry.start("garden") { nil }.value
        #expect(registry.watchedKeys.isEmpty)
        #expect(!registry.isStarting("garden"))
    }

    // A repository removed while its watch was being made: the watch must not outlive it.
    @Test func aWatchMadeForAKeyStoppedMeanwhileIsEnded() async {
        let registry = makeRegistry()
        let gate = Gate()
        let watch = FakeWatch()
        let start = registry.start("garden") {
            await gate.pass()
            return watch
        }
        await gate.arrival()
        #expect(registry.isStarting("garden"))
        registry.stop("garden")
        gate.open()
        await start.value
        #expect(watch.ended)
        #expect(registry.watchedKeys.isEmpty)
        #expect(!registry.isStarting("garden"))
    }

    @Test func stoppingEndsTheWatch() async {
        let registry = makeRegistry()
        let watch = FakeWatch()
        await registry.start("garden") { watch }.value
        registry.stop("garden")
        #expect(watch.ended)
        #expect(registry.watchedKeys.isEmpty)
    }

    @Test func startingAgainEndsTheWatchBefore() async {
        let registry = makeRegistry()
        let first = FakeWatch()
        let second = FakeWatch()
        await registry.start("garden") { first }.value
        await registry.start("garden") { second }.value
        #expect(first.ended)
        #expect(!second.ended)
        #expect(registry.watchedKeys == ["garden"])
    }

    @Test func aStartReplacedOnItsWayIsEnded() async {
        let registry = makeRegistry()
        let gate = Gate()
        let first = FakeWatch()
        let second = FakeWatch()
        let firstStart = registry.start("garden") {
            await gate.pass()
            return first
        }
        await gate.arrival()
        await registry.start("garden") { second }.value
        gate.open()
        await firstStart.value
        #expect(first.ended)
        #expect(!second.ended)
        registry.stop("garden")
        #expect(second.ended)
    }

    @Test func stoppingEverythingEndsWatchesAndStartsOnTheirWay() async {
        let registry = makeRegistry()
        let gate = Gate()
        let kept = FakeWatch()
        let late = FakeWatch()
        await registry.start("garden") { kept }.value
        let start = registry.start("atlas") {
            await gate.pass()
            return late
        }
        await gate.arrival()
        registry.stopAll()
        gate.open()
        await start.value
        #expect(kept.ended)
        #expect(late.ended)
        #expect(registry.watchedKeys.isEmpty)
        #expect(!registry.isStarting("atlas"))
    }
}
