import Foundation
import Network
import Testing
@testable import MimamoriCore

/// Real connections on loopback: only a phone holding a paired key gets through.
@Suite("Companion TLS", .serialized)
struct CompanionTLSTests {
    private let queue = DispatchQueue(label: "companion-tls-tests")

    /// Resumes a continuation once, whichever handler gets there first.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?
        init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
        func resume(_ value: T) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }

    /// A listener that sends back whatever line a connection sends it.
    private func echoListener(keys: [CompanionKey]) async throws -> (NWListener, UInt16) {
        let listener = try NWListener(using: CompanionTLS.parameters(keys: keys), on: .any)
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
        }
        let port: UInt16? = await withCheckedContinuation { continuation in
            let once = Once<UInt16?>(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(listener.port?.rawValue)
                case .failed, .cancelled: once.resume(nil)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return (listener, try #require(port))
    }

    /// Connects with `key`, sends a line and returns what came back, or nil if TLS refused it.
    private func roundTrip(port: UInt16, key: CompanionKey) async -> String? {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                      using: CompanionTLS.parameters(keys: [key]))
        defer { connection.cancel() }
        let queue = self.queue
        return await withCheckedContinuation { continuation in
            let once = Once<String?>(continuation)
            queue.asyncAfter(deadline: .now() + 5) { once.resume(nil) }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data("hello\n".utf8), completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                        once.resume(data.map { String(decoding: $0, as: UTF8.self) })
                    }
                case .failed, .waiting, .cancelled:
                    once.resume(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    @Test func aPairedKeyConnects() async throws {
        let key = CompanionKey(identity: "pairing-1", secret: CompanionKey.newSecret())
        let (listener, port) = try await echoListener(keys: [key])
        defer { listener.cancel() }
        #expect(await roundTrip(port: port, key: key) == "hello\n")
    }

    @Test func aWrongSecretIsRefused() async throws {
        let key = CompanionKey(identity: "pairing-1", secret: CompanionKey.newSecret())
        let (listener, port) = try await echoListener(keys: [key])
        defer { listener.cancel() }
        let impostor = CompanionKey(identity: "pairing-1", secret: CompanionKey.newSecret())
        #expect(await roundTrip(port: port, key: impostor) == nil)
    }

    @Test func anUnknownPairingIsRefused() async throws {
        let key = CompanionKey(identity: "pairing-1", secret: CompanionKey.newSecret())
        let (listener, port) = try await echoListener(keys: [key])
        defer { listener.cancel() }
        let stranger = CompanionKey(identity: "pairing-2", secret: CompanionKey.newSecret())
        #expect(await roundTrip(port: port, key: stranger) == nil)
    }

    @Test func eachPairedPhoneConnectsWithItsOwnKey() async throws {
        let keys = (1...3).map { CompanionKey(identity: "pairing-\($0)", secret: CompanionKey.newSecret()) }
        let (listener, port) = try await echoListener(keys: keys)
        defer { listener.cancel() }
        for key in keys {
            #expect(await roundTrip(port: port, key: key) == "hello\n")
        }
    }
}

@Suite("Companion pairing codes")
struct CompanionPairingCodeTests {
    @Test func aCodeSurvivesTheTripThroughItsLink() throws {
        let code = CompanionPairingCode(macID: "7F3A", macName: "Kevin's MacBook Pro & Co",
                                        key: CompanionKey(identity: "pairing-1", secret: CompanionKey.newSecret()))
        let url = code.url
        #expect(url.scheme == "mimamori-companion")
        // Base64 made safe for a URL: no characters that need escaping.
        let key = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "key" }?.value)
        #expect(!key.contains("+") && !key.contains("/") && !key.contains("="))
        #expect(CompanionPairingCode(url: url) == code)
    }

    @Test func otherLinksAreNotCodes() {
        let secret = CompanionPairingCode(macID: "m", macName: "Mac", key: .init(identity: "p", secret: CompanionKey.newSecret()))
        var components = URLComponents(url: secret.url, resolvingAgainstBaseURL: false)!
        #expect(CompanionPairingCode(url: URL(string: "https://example.com/pair?v=1")!) == nil)
        #expect(CompanionPairingCode(url: URL(string: "mimamori://worktree?path=/x")!) == nil)
        // A newer format, a short key and a missing id are all turned away.
        components.queryItems = components.queryItems!.map { $0.name == "v" ? URLQueryItem(name: "v", value: "2") : $0 }
        #expect(CompanionPairingCode(url: components.url!) == nil)
        components.queryItems = components.queryItems!.map { $0.name == "v" ? URLQueryItem(name: "v", value: "1") : $0 }
            .map { $0.name == "key" ? URLQueryItem(name: "key", value: "c2hvcnQ") : $0 }
        #expect(CompanionPairingCode(url: components.url!) == nil)
        components.queryItems = components.queryItems!.filter { $0.name != "id" }
        #expect(CompanionPairingCode(url: components.url!) == nil)
    }

    @Test func aHelloSurvivesTheTrip() throws {
        let message = CompanionMessage(hello: .init(pairingID: "p1", deviceName: "iPhone", model: "iPhone14,7"))
        var reader = CompanionLineReader()
        let line = try #require(reader.lines(adding: try message.line()).first)
        #expect(try CompanionMessage(line: line).hello == message.hello)
    }
}

@Suite("Companion pairings file")
struct CompanionPairingsTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("companion-\(UUID().uuidString)/companion.json")
    }

    @Test func pairingsSurviveTheTripThroughTheFile() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pairings = CompanionPairings(macID: "mac-1", phones: [
            .init(id: "p1", name: "iPhone", model: "iPhone14,7", pairedAt: Date(timeIntervalSince1970: 1_800_000_000),
                  lastSeen: Date(timeIntervalSince1970: 1_800_000_600)),
        ])
        try pairings.save(to: url)
        #expect(CompanionPairings.load(from: url) == pairings)
    }

    @Test func aMissingOrUnreadableFileStartsAfreshWithAMacID() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fresh = CompanionPairings.load(from: url)
        #expect(fresh.phones.isEmpty && !fresh.macID.isEmpty)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(CompanionPairings.load(from: url).phones.isEmpty)
        // A phone that can't be read is dropped; the Mac keeps its id and the rest.
        try Data(#"{"macID":"mac-1","phones":[{"id":"p1","name":"iPhone","pairedAt":"2026-11-05T09:00:00Z"},{"id":7}]}"#.utf8).write(to: url)
        let partial = CompanionPairings.load(from: url)
        #expect(partial.macID == "mac-1")
        #expect(partial.phones.map(\.id) == ["p1"])
    }
}
