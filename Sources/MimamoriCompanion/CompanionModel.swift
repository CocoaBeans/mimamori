import Foundation
import MimamoriShared
import Network
import Observation
import UIKit

/// A Mac this phone is paired with. Its key is in the Keychain, under `pairingID`.
struct PairedMac: Codable, Hashable, Identifiable {
    /// What the Mac advertises itself by in its Bonjour record.
    var macID: String
    var name: String
    var pairingID: String
    var id: String { macID }
}

/// Finds the paired Macs on the network, connects to one and keeps its agents.
///
/// Only paired Macs: the connection is TLS keyed by the pairing's secret, which the Mac checks.
/// iOS suspends the app in the background, which drops the connection, so coming back reconnects.
@MainActor @Observable
final class CompanionModel {
    enum Status: Equatable {
        /// No Mac is paired yet.
        case unpaired
        case searching
        case connecting(String)
        case connected(String)
        /// Why it can't connect or browse, in a sentence.
        case unavailable(String)
    }

    /// A connection that hasn't come up by now is stuck, such as one tried over the USB cable.
    private static let connectTimeout: TimeInterval = 10
    private static let pairedMacsKey = "pairedMacs"
    private static let chosenMacKey = "chosenMac"

    private(set) var pairedMacs: [PairedMac] = []
    /// The paired Macs found on the network now, by Mac id, with the service name to connect to.
    private(set) var foundMacs: [String: String] = [:]
    /// Every Mimamori on the network, by service name, for when the chosen Mac's id isn't among
    /// them: a record the phone still holds from before, or a Mac whose id changed.
    @ObservationIgnored private var allServices: [String] = []
    /// Attempts at the chosen Mac since it last connected, to try the next service each time.
    @ObservationIgnored private var attempts = 0
    private(set) var status: Status = .unpaired
    private(set) var snapshot: AgentWidgetSnapshot?
    /// When the last snapshot arrived, and how long after the Mac wrote it.
    private(set) var receivedAt: Date?
    private(set) var delay: TimeInterval?
    /// The Mac a pairing link just paired, once this phone has reached it, to say so.
    private(set) var justPaired: PairedMac?
    /// The Mac a pairing link named, until this phone first reaches it with the new key.
    private(set) var pairing: PairedMac?
    /// Allow and Deny sent from this phone, by request id, until the snapshot settles them.
    var answers: [String: AnswerState] = [:]
    /// Answers waiting for the Mac to say what became of them, by request id.
    @ObservationIgnored var answerWaiters: [String: [CheckedContinuation<CompanionMessage.AnswerResult?, Never>]] = [:]
    /// What the Mac said of an answer before anything waited for it.
    @ObservationIgnored var earlyAnswerResults: [String: CompanionMessage.AnswerResult] = [:]
    #if DEBUG
    /// Requests the `-debugAnswer` launch argument has answered already.
    @ObservationIgnored var debugAnswered: Set<String> = []
    #endif

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var reader = CompanionLineReader()
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var restartBrowser: Task<Void, Never>?
    @ObservationIgnored private let keychain = CompanionKeychain.standard
    /// Tells you as agents change.
    @ObservationIgnored let notifier = AgentNotifier()
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// The Mac to show: the one last chosen, or the first paired.
    private(set) var chosen: PairedMac?

    var connectedMac: String? {
        if case .connected(let name) = status { name } else { nil }
    }

    init() {
        if let data = defaults.data(forKey: Self.pairedMacsKey),
           let macs = try? JSONDecoder().decode([PairedMac].self, from: data) {
            pairedMacs = macs
        }
        chosen = pairedMacs.first { $0.macID == defaults.string(forKey: Self.chosenMacKey) } ?? pairedMacs.first
        status = chosen == nil ? .unpaired : .searching
        notifier.answer = { [weak self] requestID, allow in
            await self?.answerFromNotification(requestID: requestID, allow: allow) ?? "Mimamori wasn't ready to answer."
        }
    }

    /// Starts browsing, which asks for local network access the first time.
    func start() {
        guard browser == nil else { return }
        restartBrowser?.cancel()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: CompanionMessage.serviceType, domain: nil), using: .tcp)
        // Handlers run on the main queue, where this object lives.
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.browserChanged(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.found(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// The app came back to the front: connect afresh. A connection kept from before iOS
    /// suspended the app may be dead without knowing it yet, showing old states as current.
    /// `keptAlive`: the app stayed running in the background, so its connection is current and
    /// only needs asking for what's new.
    func resume(keptAlive: Bool = false) {
        if keptAlive, connection != nil, case .connected = status {
            refresh()
            return
        }
        attempts = 0
        // What went wrong before the app left the front is old news.
        if case .unavailable = status { status = chosen == nil ? .unpaired : .searching }
        start()
        connectToChosen()
    }

    /// The app went to the background, where iOS suspends it: say goodbye, so the Mac lets go at
    /// once rather than when TCP notices.
    func suspend() {
        retry?.cancel()
        disconnect()
        // A suspended app's link to Bonjour dies with it (DefunctConnection), and a browser on it
        // finds nothing again: stop it now, and start a new one on return.
        stopBrowsing()
        if case .connected = status { status = .searching }
    }

    /// Asks the Mac for a snapshot now.
    func refresh() {
        send(CompanionMessage(wantsSnapshot: true))
    }

    func choose(_ mac: PairedMac) {
        chosen = mac
        defaults.set(mac.macID, forKey: Self.chosenMacKey)
        disconnect()
        snapshot = nil
        connectToChosen()
    }

    // MARK: Pairing

    /// Opens a pairing link from the Mac's code: keeps its key and connects. False if it isn't one.
    @discardableResult
    func pair(with url: URL) -> Bool {
        guard let code = CompanionPairingCode(url: url) else { return false }
        do {
            try keychain.save(code.key)
        } catch {
            status = .unavailable("Couldn't keep the pairing: \(error.localizedDescription)")
            return true
        }
        // Pairing again with a Mac replaces the old pairing.
        if let old = pairedMacs.first(where: { $0.macID == code.macID }), old.pairingID != code.key.identity {
            keychain.delete(old.pairingID)
        }
        let mac = PairedMac(macID: code.macID, name: code.macName, pairingID: code.key.identity)
        pairedMacs.removeAll { $0.macID == mac.macID }
        pairedMacs.append(mac)
        savePairedMacs()
        pairing = mac
        justPaired = nil
        choose(mac)
        return true
    }

    func dismissJustPaired() {
        justPaired = nil
    }

    /// Forgets `mac`: its key goes, and the Mac's list keeps the phone until it's removed there.
    func forget(_ mac: PairedMac) {
        keychain.delete(mac.pairingID)
        pairedMacs.removeAll { $0.macID == mac.macID }
        savePairedMacs()
        if pairing?.macID == mac.macID { pairing = nil }
        if chosen?.macID == mac.macID {
            disconnect()
            snapshot = nil
            chosen = pairedMacs.first
            if chosen == nil { status = .unpaired } else { connectToChosen() }
        }
    }

    private func savePairedMacs() {
        defaults.set(try? JSONEncoder().encode(pairedMacs), forKey: Self.pairedMacsKey)
    }

    // MARK: Browsing

    private func stopBrowsing() {
        restartBrowser?.cancel()
        browser?.cancel()
        browser = nil
        foundMacs = [:]
        allServices = []
    }

    private func browserChanged(_ state: NWBrowser.State) {
        switch state {
        case .waiting(let error):
            if Self.isLocalNetworkDenied(error) { status = .unavailable(Self.localNetworkDenied) }
        case .failed(let error):
            // A failed browser finds nothing more, whatever went wrong: start another shortly.
            status = .unavailable(Self.isLocalNetworkDenied(error) ? Self.localNetworkDenied
                                  : "Lost track of the network (\(error.localizedDescription)). Looking again…")
            stopBrowsing()
            restartBrowser = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.start()
                self.connectToChosen()
            }
        case .ready:
            if case .unavailable = status, connection == nil { connectToChosen() }
        default:
            break
        }
    }

    private static let localNetworkDenied = "Mimamori can't look for your Mac: turn it on in "
        + "Settings › Privacy & Security › Local Network."

    /// kDNSServiceErr_PolicyDenied: local network access is off for the app.
    private static func isLocalNetworkDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65570 }
        return false
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        var macs: [String: String] = [:]
        var names: Set<String> = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            names.insert(name)
            if case .bonjour(let record) = result.metadata, let macID = record[CompanionBonjour.macIDKey] {
                macs[macID] = name
            }
        }
        foundMacs = macs
        allServices = names.sorted()
        if connection == nil { connectToChosen() }
    }

    // MARK: The connection

    private func connectToChosen() {
        guard let mac = chosen else {
            status = .unpaired
            return
        }
        // The Mac by its id; failing that, each Mimamori in turn: TLS lets in only the one that
        // holds this pairing's key.
        let candidates = foundMacs[mac.macID].map { [$0] } ?? allServices
        guard !candidates.isEmpty else {
            if case .unavailable = status { return }
            status = .searching
            return
        }
        let service = candidates[attempts % candidates.count]
        guard let key = keychain.key(for: mac.pairingID) else {
            status = .unavailable("This iPhone has lost its pairing with \(mac.name). Pair it again from the Mac.")
            return
        }
        retry?.cancel()
        disconnect()
        reader = CompanionLineReader()
        notifier.reset()
        status = .connecting(mac.name)
        // The service by name, not the browse result's endpoint, which is tied to the interface it
        // was found on: found over a USB cable, that connection never came up.
        let endpoint = NWEndpoint.service(name: service, type: CompanionMessage.serviceType, domain: "local.", interface: nil)
        let connection = NWConnection(to: endpoint, using: CompanionTLS.parameters(keys: [key]))
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.connectionChanged(state, connection: connection, mac: mac) }
        }
        connection.start(queue: .main)
        self.connection = connection
        receive(on: connection)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectTimeout))
            guard !Task.isCancelled, let self, connection === self.connection, connection.state != .ready else { return }
            self.lost(connection, mac: mac, reason: "Can't reach \(mac.name). Trying again…")
        }
    }

    private func disconnect() {
        timeout?.cancel()
        connection?.cancel()
        connection = nil
    }

    private func connectionChanged(_ state: NWConnection.State, connection: NWConnection, mac: PairedMac) {
        guard connection === self.connection else { return }
        switch state {
        case .ready:
            timeout?.cancel()
            attempts = 0
            status = .connected(mac.name)
            if pairing?.macID == mac.macID {
                pairing = nil
                justPaired = mac
            }
            Task { await notifier.requestAuthorizationIfNeeded() }
            send(CompanionMessage(hello: .init(pairingID: mac.pairingID, deviceName: UIDevice.current.name,
                                               model: Self.model)))
        case .waiting(let error), .failed(let error):
            lost(connection, mac: mac, reason: reason(for: error, mac: mac))
        case .cancelled:
            if status == .connected(mac.name) { lost(connection, mac: mac, reason: "Disconnected from \(mac.name).") }
        default:
            break
        }
    }

    /// Drops `connection` and tries again shortly, while the Mac is still found.
    private func lost(_ connection: NWConnection, mac: PairedMac, reason: String) {
        guard connection === self.connection else { return }
        status = .unavailable(reason)
        attempts += 1
        disconnect()
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.connection == nil else { return }
            self.connectToChosen()
        }
    }

    /// A failed handshake most likely means the Mac no longer has this phone's key.
    private func reason(for error: NWError, mac: PairedMac) -> String {
        if case .tls = error {
            if pairing?.macID == mac.macID {
                return "\(mac.name) didn't accept the pairing. On the Mac, choose Pair iPhone… and scan the new code: each works only while its window is open."
            }
            return "\(mac.name) didn't accept this iPhone. If you removed it there, pair it again."
        }
        return "Can't reach \(mac.name): \(error.localizedDescription)"
    }

    private func send(_ message: CompanionMessage) {
        guard let connection, let line = try? message.line() else { return }
        connection.send(content: line, completion: .contentProcessed { _ in })
    }

    /// Sends `message` on the open connection, if there is one that's up; false if not, or if it
    /// couldn't be sent, so nothing claims an answer went that didn't.
    func sendNow(_ message: CompanionMessage) async -> Bool {
        guard let connection, connection.state == .ready, case .connected = status,
              let line = try? message.line() else { return false }
        return await withCheckedContinuation { continuation in
            connection.send(content: line, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, connection === self.connection else { return }
                if let data, !data.isEmpty { self.read(data) }
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection)
                }
            }
        }
    }

    private func read(_ data: Data) {
        for line in reader.lines(adding: data) {
            guard let message = try? CompanionMessage(line: line) else { continue }
            if let result = message.answerResult { answerResultArrived(result) }
            guard let snapshot = message.snapshot else { continue }
            let now = Date()
            self.snapshot = snapshot
            notifier.update(snapshot)
            receivedAt = now
            delay = now.timeIntervalSince(snapshot.writtenAt)
            settleAnswers(with: snapshot)
        }
    }

    /// "iPhone14,7": the model, for the Mac's list.
    private static let model: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()
}
