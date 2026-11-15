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
    /// Where to reach it away from its network, as it last said; nil from a Mac with no tailnet
    /// address, or one from before.
    var reach: CompanionReach?
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
    private(set) var status: Status = .unpaired {
        didSet { if status != oldValue { updateLiveActivity() } }
    }
    private(set) var snapshot: AgentWidgetSnapshot? {
        didSet { updateLiveActivity() }
    }
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
    /// The worktree whose agent's actions are on screen, and those actions once they arrive.
    private(set) var watching: String?
    private(set) var actions: AgentActions?
    /// The sample Mac shown instead of a real one, to try the app without a Mac: for App Review,
    /// and for screenshots. Nothing goes over the network while it's on.
    private(set) var demo: CompanionDemo?
    /// Moves the demo's agents on, once a second.
    @ObservationIgnored private var demoTicker: Task<Void, Never>?

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var reader = CompanionLineReader()
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var restartBrowser: Task<Void, Never>?
    @ObservationIgnored private let keychain = CompanionKeychain.standard
    /// Tells you as agents change.
    @ObservationIgnored let notifier = AgentNotifier()
    /// Shows the agents on the Lock Screen and in the Dynamic Island, in builds kept running.
    @ObservationIgnored let liveActivity = LiveActivityController()
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// The Mac to show: the one last chosen, or the first paired.
    private(set) var chosen: PairedMac?
    /// The connection goes over the Mac's tailnet address rather than this network.
    private(set) var isAway = false
    /// When browsing started, to give Bonjour its moment before going the long way.
    @ObservationIgnored private var browsingSince: Date?

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
        guard browser == nil, demo == nil else { return }
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
        browsingSince = Date()
    }

    /// The app came back to the front: connect afresh. A connection kept from before iOS
    /// suspended the app may be dead without knowing it yet, showing old states as current.
    /// `keptAlive`: the app stayed running in the background, so its connection is current and
    /// only needs asking for what's new.
    func resume(keptAlive: Bool = false) {
        if demo != nil {
            publishDemo()
            return
        }
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
        guard demo == nil else { return }
        retry?.cancel()
        disconnect()
        // A suspended app's link to Bonjour dies with it (DefunctConnection), and a browser on it
        // finds nothing again: stop it now, and start a new one on return.
        stopBrowsing()
        if case .connected = status { status = .searching }
    }

    /// Asks the Mac for a snapshot now.
    func refresh() {
        if demo != nil {
            publishDemo()
        } else {
            send(CompanionMessage(wantsSnapshot: true))
        }
    }

    /// Shows `worktree`'s agent's actions: the Mac sends them now and as they change. Nil stops.
    func watch(_ worktree: String?) {
        guard worktree != watching else { return }
        watching = worktree
        if actions?.worktreePath != worktree { actions = nil }
        if let demo {
            actions = worktree.flatMap { demo.actions(for: $0) }
            return
        }
        send(CompanionMessage(watchActions: worktree ?? ""))
    }

    func choose(_ mac: PairedMac) {
        endDemo(reconnecting: false)
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
        let mac = PairedMac(macID: code.macID, name: code.macName, pairingID: code.key.identity, reach: code.reach)
        pairedMacs.removeAll { $0.macID == mac.macID }
        pairedMacs.append(mac)
        savePairedMacs()
        pairing = mac
        justPaired = nil
        choose(mac)
        return true
    }

    /// Brings the Live Activity in line with the Mac on screen: the demo's or the chosen one's,
    /// marked out of touch while not connected.
    func updateLiveActivity() {
        let connected = if case .connected = status { true } else { false }
        let macName = status == .unpaired ? nil : demo?.macName ?? chosen?.name
        liveActivity.show(macName: macName, snapshot: snapshot, connected: connected)
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

    /// Where the connected Mac says it can be reached away from its network, for next time.
    private func remember(_ reach: CompanionReach) {
        guard let mac = chosen, mac.reach != reach,
              let index = pairedMacs.firstIndex(where: { $0.macID == mac.macID }) else { return }
        pairedMacs[index].reach = reach
        chosen = pairedMacs[index]
        savePairedMacs()
    }

    private func savePairedMacs() {
        defaults.set(try? JSONEncoder().encode(pairedMacs), forKey: Self.pairedMacsKey)
    }

    // MARK: The demo

    /// Shows the sample Mac's agents in place of a real Mac's, which it lets go of meanwhile.
    /// `.screenshots` is the App Store screenshots' own Mac, which looks like any connected Mac.
    func startDemo(_ sample: CompanionDemo.Sample = .tryIt) {
        guard demo == nil else { return }
        retry?.cancel()
        disconnect()
        stopBrowsing()
        answers = [:]
        actions = nil
        notifier.reset()
        let demo = CompanionDemo(sample: sample)
        self.demo = demo
        status = .connected(demo.macName)
        // A connected Mac's status line says how quickly changes arrive.
        delay = sample == .screenshots ? 0.014 : nil
        publishDemo()
        Task { await notifier.requestAuthorizationIfNeeded() }
        demoTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.publishDemo()
            }
        }
    }

    /// Back to the paired Mac, if there is one. `reconnecting` false leaves connecting to the caller.
    func endDemo(reconnecting: Bool = true) {
        guard demo != nil else { return }
        demoTicker?.cancel()
        demoTicker = nil
        demo = nil
        snapshot = nil
        actions = nil
        answers = [:]
        receivedAt = nil
        delay = nil
        notifier.reset()
        status = chosen == nil ? .unpaired : .searching
        guard reconnecting else { return }
        start()
        connectToChosen()
    }

    /// Settles an answer in the demo, as the Mac would. Nil once taken; otherwise why not.
    func answerDemo(requestID: String, allow: Bool) -> String? {
        guard demo != nil else { return "The demo has ended." }
        let refusal = demo?.answer(requestID: requestID, allow: allow)
        publishDemo()
        return refusal
    }

    /// The demo's agents as they stand now, when they've changed, as a snapshot from the Mac is taken.
    private func publishDemo() {
        guard let demo else { return }
        let now = Date()
        if let watching {
            let current = demo.actions(for: watching, at: now)
            if current != actions { actions = current }
        }
        let next = demo.snapshot(at: now)
        guard next.agents != snapshot?.agents else { return }
        snapshot = next
        notifier.update(next)
        receivedAt = now
        settleAnswers(with: next)
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
        guard demo == nil else { return }
        guard let mac = chosen else {
            status = .unpaired
            return
        }
        guard let key = keychain.key(for: mac.pairingID) else {
            status = .unavailable("This iPhone has lost its pairing with \(mac.name). Pair it again from the Mac.")
            return
        }
        let browsing = Date().timeIntervalSince(browsingSince ?? .distantPast)
        switch CompanionRoute.next(own: foundMacs[mac.macID], others: allServices, reach: mac.reach,
                                   attempts: attempts, browsing: browsing) {
        case .service(let service):
            // The service by name, not the browse result's endpoint, which is tied to the interface
            // it was found on: found over a USB cable, that connection never came up.
            open(.service(name: service, type: CompanionMessage.serviceType, domain: "local.", interface: nil),
                 to: mac, key: key, away: false)
        case .away(let host, let port):
            // Not on this network: the long way, over the tailnet.
            open(.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any),
                 to: mac, key: key, away: true)
        case .wait(let seconds):
            // Bonjour gets its moment to find the Mac here first.
            if case .unavailable = status {} else { status = .searching }
            retry?.cancel()
            retry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self, self.connection == nil else { return }
                self.connectToChosen()
            }
        case .none:
            if case .unavailable = status { return }
            status = .searching
        }
    }

    /// Connects to `mac` at `endpoint`: a Bonjour service on this network, or, `away`, its tailnet address.
    private func open(_ endpoint: NWEndpoint, to mac: PairedMac, key: CompanionKey, away: Bool) {
        retry?.cancel()
        disconnect()
        reader = CompanionLineReader()
        notifier.reset()
        isAway = away
        status = .connecting(mac.name)
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
            self.lost(connection, mac: mac, reason: away
                      ? "Can't reach \(mac.name) here or over Tailscale. Is Tailscale on, on both? Trying again…"
                      : "Can't reach \(mac.name). Trying again…")
        }
    }

    private func disconnect() {
        timeout?.cancel()
        connection?.cancel()
        connection = nil
        isAway = false
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
            // A new connection starts with nothing watched on the Mac's side.
            if let watching { send(CompanionMessage(watchActions: watching)) }
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
            if let challenge = message.challenge { prove(challenge) }
            if let result = message.answerResult { answerResultArrived(result) }
            if let reach = message.reach { remember(reach) }
            if let actions = message.actions, actions.worktreePath == watching { self.actions = actions }
            guard let snapshot = message.snapshot else { continue }
            let now = Date()
            self.snapshot = snapshot
            notifier.update(snapshot)
            receivedAt = now
            delay = now.timeIntervalSince(snapshot.writtenAt)
            settleAnswers(with: snapshot)
        }
    }

    /// Answers the Mac's challenge with an HMAC of its nonce under this pairing's secret, so the Mac
    /// knows which paired phone this is before it takes an answer from it. A Mac from before
    /// challenges sends none, and goes by the hello alone.
    private func prove(_ challenge: CompanionMessage.Challenge) {
        guard let mac = chosen, let key = keychain.key(for: mac.pairingID) else { return }
        #if DEBUG
        // For scripted runs: `-debugProof withhold` sends no proof, and `-debugProof other` one for
        // another pairing id, so the Mac's refusal of an unproved phone's answers can be shown.
        let debugProof = UserDefaults.standard.string(forKey: "debugProof")
        if debugProof == "withhold" { return }
        let pairingID = debugProof == "other" ? UUID().uuidString : mac.pairingID
        #else
        let pairingID = mac.pairingID
        #endif
        let code = CompanionProof.mac(secret: key.secret, nonce: challenge.nonce, pairingID: pairingID)
        send(CompanionMessage(proof: .init(pairingID: pairingID, mac: code)))
    }

    /// "iPhone14,7": the model, for the Mac's list.
    private static let model: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()
}
