import Foundation
import MimamoriShared
import Network
import Observation

/// Finds Macs running Mimamori on the network, connects to one and keeps its agents.
///
/// The first step of the companion (docs/plans/iphone-companion.md): no pairing or encryption
/// yet, and only while the app is open. iOS suspends it in the background, which drops the
/// connection, so coming back reconnects.
@MainActor @Observable
final class CompanionModel {
    enum Status: Equatable {
        case searching
        case connecting(String)
        case connected(String)
        /// Why it can't connect or browse, in a sentence.
        case unavailable(String)
    }

    struct Mac: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    private(set) var macs: [Mac] = []
    private(set) var status: Status = .searching
    private(set) var snapshot: AgentWidgetSnapshot?
    /// When the last snapshot arrived, and how long after the Mac wrote it: how quickly changes
    /// reach the phone. The two clocks can differ by a little.
    private(set) var receivedAt: Date?
    private(set) var delay: TimeInterval?

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var reader = CompanionLineReader()
    @ObservationIgnored private var chosen: Mac?

    var connectedMac: String? {
        if case .connected(let name) = status { name } else { nil }
    }

    /// Starts browsing, which asks for local network access the first time.
    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: CompanionMessage.serviceType, domain: nil), using: .tcp)
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

    /// The app came back to the front: reconnect if the connection was lost, else ask for
    /// what's current.
    func resume() {
        if connection == nil, let mac = chosen ?? macs.first {
            connect(to: mac)
        } else {
            refresh()
        }
    }

    func connect(to mac: Mac) {
        connection?.cancel()
        chosen = mac
        reader = CompanionLineReader()
        status = .connecting(mac.name)
        let connection = NWConnection(to: mac.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.connectionChanged(state, connection: connection, mac: mac) }
        }
        connection.start(queue: .main)
        self.connection = connection
        receive(on: connection)
    }

    /// Asks the Mac for a snapshot now.
    func refresh() {
        guard let connection, let line = try? CompanionMessage(wantsSnapshot: true).line() else { return }
        connection.send(content: line, completion: .contentProcessed { _ in })
    }

    // MARK: Browsing

    private func browserChanged(_ state: NWBrowser.State) {
        switch state {
        case .waiting(let error), .failed(let error):
            // Most often local network access turned off for the app in Settings.
            status = .unavailable("Can't look for Macs on this network (\(error.localizedDescription)). "
                                  + "Check Settings › Privacy & Security › Local Network.")
        default:
            break
        }
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        macs = results.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            return Mac(name: name, endpoint: result.endpoint)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // The first Mac found, until there is pairing to say which one is yours.
        if connection == nil, let mac = macs.first { connect(to: mac) }
    }

    // MARK: The connection

    private func connectionChanged(_ state: NWConnection.State, connection: NWConnection, mac: Mac) {
        guard connection === self.connection else { return }
        switch state {
        case .ready:
            status = .connected(mac.name)
        case .waiting(let error), .failed(let error):
            status = .unavailable("Can't reach \(mac.name): \(error.localizedDescription)")
            connection.cancel()
            self.connection = nil
        case .cancelled:
            self.connection = nil
            if status == .connected(mac.name) { status = .unavailable("Disconnected from \(mac.name).") }
        default:
            break
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
            guard let message = try? CompanionMessage(line: line), let snapshot = message.snapshot else { continue }
            let now = Date()
            self.snapshot = snapshot
            receivedAt = now
            delay = now.timeIntervalSince(snapshot.writtenAt)
        }
    }
}
