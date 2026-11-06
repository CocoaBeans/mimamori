import Foundation
import MimamoriCore
import Network

/// Advertises Mimamori over Bonjour and streams the agents to paired iPhones on the network, as
/// lines of JSON (`CompanionMessage`), over TLS keyed by each pairing's secret: a phone without a
/// paired key can't connect, and nobody else on the network can read what is sent.
///
/// It sends the snapshot the desktop widgets get, on their rules: at once when who needs you
/// changes, or a permission request comes or goes, otherwise at most every 10 s, and only when
/// something shown changed. A phone that connects, or asks, gets what's current, which starts no
/// polling.
@MainActor
final class CompanionPublisher {
    private static let minimumInterval: TimeInterval = 10

    /// A phone said who it is: which pairing it connected with, and its name.
    var onHello: ((CompanionMessage.Hello) -> Void)?
    /// A phone answered a permission request, with the pairing it proved it is, if it has: what
    /// became of it goes back to that phone.
    var onAnswer: ((CompanionMessage.Answer, _ pairingID: String?) -> CompanionMessage.AnswerResult)?
    /// The secret paired under a pairing id, to check a phone's proof with; nil for an id that
    /// isn't paired.
    var secret: ((String) -> Data?)?
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
        /// The pairing it said hello with: a claim, good for the paired phones' list.
        var pairingID: String?
        /// The pairing it proved it is, against this connection's own nonce: what answers go by.
        var identity = CompanionConnectionIdentity()
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
        Log.companion.notice("Companion listener: \(String(describing: state), privacy: .public)")
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
        let waiting = CompanionMessage.urgentKeys(agents)
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

    private func sendToAll() {
        pending?.cancel()
        pending = nil
        sent = latest
        needingYou = CompanionMessage.urgentKeys(latest)
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
                    // TLS has checked the phone's key by now, but not which pairing's: the
                    // challenge asks it to prove that.
                    Log.companion.notice("Companion connected: \(String(describing: connection.endpoint), privacy: .public)")
                    if let nonce = self?.phones[id]?.identity.nonce,
                       let challenge = try? CompanionMessage(challenge: .init(nonce: nonce)).line() {
                        self?.send(challenge, to: connection)
                    }
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
        guard var reader = phones[id]?.reader else { return }
        let lines = reader.lines(adding: data)
        phones[id]?.reader = reader
        // In order, so a proof counts for an answer that follows it in the same piece.
        for line in lines {
            guard phones[id] != nil, let message = try? CompanionMessage(line: line) else { continue }
            if let hello = message.hello {
                phones[id]?.pairingID = hello.pairingID
                onHello?(hello)
            }
            if let proof = message.proof { check(proof, from: id) }
            if message.wantsSnapshot == true, let reply = currentLine() { send(reply, to: connection) }
            // Only a phone connected with a paired key gets this far; the pairing it proved it is,
            // not the one it claims, decides whether the answer counts.
            if let answer = message.answer, let result = onAnswer?(answer, phones[id]?.identity.verifiedPairingID),
               let reply = try? CompanionMessage(answerResult: result).line() {
                send(reply, to: connection)
            }
        }
    }

    /// A proof that doesn't hold is logged and leaves the connection unverified, but open: it
    /// still gets snapshots, and the answer check turns down its answers.
    private func check(_ proof: CompanionMessage.Proof, from id: ObjectIdentifier) {
        guard var identity = phones[id]?.identity else { return }
        let outcome = identity.check(proof, secret: secret?(proof.pairingID))
        phones[id]?.identity = identity
        switch outcome {
        case .verified(let pairing):
            Log.companion.notice("A companion proved it is pairing \(pairing, privacy: .public)")
        case .alreadyVerified:
            break
        case .conflicting, .unknownPairing, .mismatch:
            Log.companion.error("Turned down a companion's proof for pairing \(proof.pairingID, privacy: .public): \(String(describing: outcome), privacy: .public)")
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
        Log.companion.notice("Companion disconnected: \(String(describing: connection.endpoint), privacy: .public)")
    }
}

// MARK: Cards

extension AppModel {
    /// Lets paired phones answer permission requests through `AgentHub.answerPermission`, and
    /// sends them each request as it comes and goes.
    func connectCompanionToPermissions() {
        companion.permissionRequests = { [weak self] in
            guard let self else { return (false, []) }
            return (self.settings.answerPermissionsInMimamori, Set(self.agentHub.pendingPermissions.values.map(\.id)))
        }
        companion.onAnswer = { [weak self] id, allow, phone in
            self?.agentHub.answerPermission(id, allow: allow, phone: phone)
        }
        agentHub.onPermissionsChange = { [weak self] in
            self?.companion.updateSoon { [weak self] in self?.companionAgents() ?? [] }
        }
    }

    /// The agents as the widgets draw them, each with its Agents window card.
    func companionAgents() -> [AgentWidgetSnapshot.Agent] {
        let details = settings.showTasksInWidgets
        return agentRows.map { row in
            var agent = widgetAgent(for: row, details: details)
            agent.card = companionCard(for: row, details: details)
            agent.permissionRequest = companionPermissionRequest(for: row)
            return agent
        }
    }

    /// The request the phone can answer for `row`, while Mimamori answers requests. Its detail goes
    /// whatever "Show tasks and steps in widgets" says: the status line carries it anyway, and
    /// nobody should allow a command they can't see.
    private func companionPermissionRequest(for row: AgentRow) -> AgentWidgetSnapshot.PermissionRequest? {
        guard settings.answerPermissionsInMimamori, let id = row.presence.permissionRequestID,
              let pending = agentHub.pendingPermissions.values.first(where: { $0.id == id }) else { return nil }
        let detail = CompanionAnswerCheck.clipped(pending.command ?? pending.detail)
        let autoAnswer = pending.autoAnswer.map { AgentWidgetSnapshot.PermissionRequest.AutoAnswer(allow: $0.allow, at: $0.at) }
        return AgentWidgetSnapshot.PermissionRequest(id: pending.id, tool: pending.tool, detail: detail, since: pending.since,
                                                     autoAnswer: autoAnswer)
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
