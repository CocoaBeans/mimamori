// Debug builds only, for now: the iPhone companion's first step (docs/plans/iphone-companion.md).
#if DEBUG
import Foundation
import MimamoriCore
import Network

/// Advertises Mimamori over Bonjour and streams the agents to iPhones on the same network, as
/// lines of JSON (`CompanionMessage`). With MIMAMORI_DEBUG_FLAGS=companion only.
///
/// A spike: anything on the network can connect and read, with no pairing or encryption yet. It
/// sends the snapshot the desktop widgets get, on their rules: at once when who needs you changes,
/// otherwise at most every 10 s, and only when something shown changed. A phone that connects, or
/// asks, gets what's current, which starts no polling.
@MainActor
final class CompanionPublisher {
    private static let minimumInterval: TimeInterval = 10

    private var listener: NWListener?
    private var phones: [ObjectIdentifier: Phone] = [:]
    private var latest: [AgentWidgetSnapshot.Agent] = []
    private var sent: [AgentWidgetSnapshot.Agent]?
    private var needingYou: Set<String> = []
    private var lastSentAt = Date.distantPast
    private var pending: Task<Void, Never>?

    private struct Phone {
        let connection: NWConnection
        var reader = CompanionLineReader()
    }

    /// Starts listening on a port the system picks, advertised under the Mac's name.
    func start() {
        guard listener == nil else { return }
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            Log.companion.error("Could not listen for the companion: \(error.localizedDescription, privacy: .public)")
            return
        }
        listener.service = NWListener.Service(type: CompanionMessage.serviceType)
        // Handlers run on the main queue, where this object lives.
        listener.stateUpdateHandler = { state in
            Log.companion.info("Companion listener: \(String(describing: state), privacy: .public)")
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    /// The agents as they are now, the most pressing first.
    func update(_ agents: [AgentWidgetSnapshot.Agent]) {
        latest = agents
        guard agents != sent else { return }
        let waiting = Self.waiting(agents)
        if waiting != needingYou || sent == nil {
            sendToAll()
            return
        }
        guard pending == nil else { return }
        let wait = max(0, Self.minimumInterval - Date().timeIntervalSince(lastSentAt))
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.sendToAll()
        }
    }

    private static func waiting(_ agents: [AgentWidgetSnapshot.Agent]) -> Set<String> {
        Set(agents.filter { $0.state == .needsYou || $0.collision != nil }.map(\.id))
    }

    private func sendToAll() {
        pending?.cancel()
        pending = nil
        sent = latest
        needingYou = Self.waiting(latest)
        lastSentAt = Date()
        guard !phones.isEmpty, let line = currentLine() else { return }
        for phone in phones.values { send(line, to: phone.connection) }
    }

    private func currentLine() -> Data? {
        let snapshot = AgentWidgetSnapshot(writtenAt: Date(), agents: latest)
        do {
            return try CompanionMessage(snapshot: snapshot).line()
        } catch {
            Log.companion.error("Could not encode the companion snapshot: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        phones[id] = Phone(connection: connection)
        Log.companion.info("Companion connected: \(String(describing: connection.endpoint), privacy: .public)")
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    if let line = self?.currentLine() { self?.send(line, to: connection) }
                case .failed, .cancelled:
                    self?.drop(connection)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty { self.read(data, from: connection) }
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection)
                }
            }
        }
    }

    private func read(_ data: Data, from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard var phone = phones[id] else { return }
        let lines = phone.reader.lines(adding: data)
        phones[id] = phone
        for line in lines {
            guard let message = try? CompanionMessage(line: line) else { continue }
            if message.wantsSnapshot == true, let reply = currentLine() { send(reply, to: connection) }
        }
    }

    private func send(_ line: Data, to connection: NWConnection) {
        connection.send(content: line, completion: .contentProcessed { error in
            if error != nil { connection.cancel() }
        })
    }

    private func drop(_ connection: NWConnection) {
        guard phones.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        Log.companion.info("Companion disconnected: \(String(describing: connection.endpoint), privacy: .public)")
    }
}
#endif
