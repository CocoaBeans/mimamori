import Foundation
import MimamoriCore
import Network

/// Advertises Mimamori over Bonjour and streams the agents to paired iPhones on the network, as
/// lines of JSON (`CompanionMessage`), over TLS keyed by each pairing's secret: a phone without a
/// paired key can't connect, and nobody else on the network can read what is sent.
///
/// It sends the snapshot the desktop widgets get, on their rules: at once when who needs you
/// changes, otherwise at most every 10 s, and only when something shown changed. A phone that
/// connects, or asks, gets what's current, which starts no polling.
@MainActor
final class CompanionPublisher {
    private static let minimumInterval: TimeInterval = 10

    /// A phone said who it is: which pairing it connected with, and its name.
    var onHello: ((CompanionMessage.Hello) -> Void)?
    /// A phone that had said hello went away, with its pairing's id.
    var onGoodbye: ((String) -> Void)?
    /// The listener's state, in a sentence for Settings; nil while all is well.
    var onProblem: ((String?) -> Void)?

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
        /// The pairing it said hello with.
        var pairingID: String?
    }

    var isRunning: Bool { listener != nil }

    /// Listens on a port the system picks, advertised under the Mac's name with `macID` in its
    /// record, accepting phones that hold one of `keys`. Starting again with other keys drops the
    /// phones connected so far, so a removed phone is cut off; the others reconnect at once.
    func start(macID: String, keys: [CompanionKey]) {
        stop()
        let listener: NWListener
        do {
            listener = try NWListener(using: CompanionTLS.parameters(keys: keys))
        } catch {
            Log.companion.error("Could not listen for the companion: \(error.localizedDescription, privacy: .public)")
            onProblem?("Mimamori couldn't listen for your iPhone: \(error.localizedDescription)")
            return
        }
        listener.service = NWListener.Service(type: CompanionMessage.serviceType,
                                              txtRecord: NWTXTRecord([CompanionBonjour.macIDKey: macID]))
        // Handlers run on the main queue, where this object lives.
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    /// Stops listening and advertising, and drops every phone.
    func stop() {
        listener?.cancel()
        listener = nil
        let gone = phones.values.compactMap(\.pairingID)
        for phone in phones.values { phone.connection.cancel() }
        phones.removeAll()
        for id in gone { onGoodbye?(id) }
    }

    private func listenerChanged(_ state: NWListener.State) {
        Log.companion.info("Companion listener: \(String(describing: state), privacy: .public)")
        switch state {
        case .ready:
            onProblem?(nil)
        case .waiting(let error), .failed(let error):
            // Most often local network access turned off for Mimamori in System Settings.
            onProblem?("Your iPhone can't reach Mimamori (\(error.localizedDescription)). "
                       + "Check System Settings › Privacy & Security › Local Network.")
        default:
            break
        }
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
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    // TLS has checked the phone's key by now.
                    Log.companion.info("Companion connected: \(String(describing: connection.endpoint), privacy: .public)")
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
        for line in lines {
            guard let message = try? CompanionMessage(line: line), let hello = message.hello else { continue }
            phone.pairingID = hello.pairingID
        }
        phones[id] = phone
        for line in lines {
            guard let message = try? CompanionMessage(line: line) else { continue }
            if let hello = message.hello { onHello?(hello) }
            if message.wantsSnapshot == true, let reply = currentLine() { send(reply, to: connection) }
        }
    }

    private func send(_ line: Data, to connection: NWConnection) {
        connection.send(content: line, completion: .contentProcessed { error in
            if error != nil { connection.cancel() }
        })
    }

    private func drop(_ connection: NWConnection) {
        guard let phone = phones.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        if let id = phone.pairingID { onGoodbye?(id) }
        Log.companion.info("Companion disconnected: \(String(describing: connection.endpoint), privacy: .public)")
    }
}

// MARK: Cards

extension AppModel {
    /// The agents as the widgets draw them, each with its Agents window card.
    func companionAgents() -> [AgentWidgetSnapshot.Agent] {
        let details = settings.showTasksInWidgets
        return agentRows.map { row in
            var agent = widgetAgent(for: row, details: details)
            agent.card = companionCard(for: row, details: details)
            return agent
        }
    }

    /// What the Agents window's card shows for `row`. Without `details`, the steps keep their kind
    /// and times but lose their targets, and the files stay off, as tasks and steps do.
    private func companionCard(for row: AgentRow, details: Bool) -> AgentWidgetSnapshot.Card {
        let presence = row.presence
        let worktree = row.session.id
        func call(_ call: AgentToolCall) -> AgentToolCall {
            var copy = call
            copy.summary = details ? call.summary.map { AgentText.shortenPaths($0, in: worktree) } : nil
            copy.filePath = nil
            return copy
        }
        let underway: Bool = switch presence.activity {
        case .working, .needsPermission, .askedQuestion: true
        case .ready, .idle: false
        }
        let hooks = presence.source == .hooks
        let changes = row.session.changes
        return AgentWidgetSnapshot.Card(
            reportsSteps: hooks, turnUnderway: hooks && underway, turnStartedAt: presence.turnStartedAt,
            calls: hooks ? presence.turnSteps.map(call) : [], callsThisTurn: presence.toolCallsThisTurn,
            waitingCallID: presence.awaitingCallID, lastCall: hooks ? presence.lastToolCall.map(call) : nil,
            files: details ? row.files.map { file in
                AgentWidgetSnapshot.Card.File(path: file.path, additions: file.isBinary ? nil : file.additions,
                                              deletions: file.isBinary ? nil : file.deletions, flagged: file.isFlagged)
            } : [],
            changes: .init(files: changes.count, toReview: row.session.unreviewedCount, flagged: changes.flaggedCount,
                           additions: changes.totalAdditions, deletions: changes.totalDeletions),
            others: presence.others.map { other in
                .init(agent: other.kind.displayName, symbol: other.kind.symbolName, state: other.widgetState,
                      status: AgentText.shortenPaths(other.statusText, in: worktree), since: other.since)
            })
    }
}
