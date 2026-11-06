import Foundation
import MimamoriCore
import Observation

/// The iPhone companion on the Mac: whether it's on, the paired phones, and pairing a new one.
/// Off, nothing listens or advertises. On, `CompanionPublisher` accepts the paired phones' keys,
/// plus the key of a pairing code while one is shown.
@MainActor @Observable
final class CompanionController {
    private(set) var pairings: CompanionPairings
    private(set) var isOn = false
    /// The code shown while you pair a phone; nil otherwise.
    private(set) var pairingCode: CompanionPairingCode?
    /// The phone that paired with the code shown, so the sheet can say so.
    private(set) var justPaired: CompanionPairings.Phone?
    /// Phones connected now, by pairing id.
    private(set) var connected: Set<String> = []
    /// What's keeping phones from connecting, in a sentence; nil while all is well.
    private(set) var problem: String?

    @ObservationIgnored private let publisher = CompanionPublisher()
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let keychain: CompanionKeychain

    init(url: URL = Persistence.companionURL, keychain: CompanionKeychain = Persistence.companionKeychain) {
        self.url = url
        self.keychain = keychain
        pairings = CompanionPairings.load(from: url)
        publisher.onHello = { [weak self] hello in self?.said(hello) }
        publisher.onGoodbye = { [weak self] id in self?.left(id) }
        publisher.onProblem = { [weak self] problem in self?.problem = problem }
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        if on {
            restart()
        } else {
            publisher.stop()
            endPairing()
            connected.removeAll()
            problem = nil
        }
    }

    /// The agents as they are now, for the phones.
    func update(_ agents: [AgentWidgetSnapshot.Agent]) {
        guard isOn else { return }
        publisher.update(agents)
    }

    // MARK: Pairing

    /// Makes a code for a new phone, and listens for it.
    func startPairing() {
        let key = CompanionKey(identity: UUID().uuidString, secret: CompanionKey.newSecret())
        do {
            try keychain.save(key)
            // The Mac's id is in the code, so it must outlast this launch.
            try pairings.save(to: url)
        } catch {
            problem = "Couldn't make a pairing code: \(error.localizedDescription)"
            return
        }
        if let old = pairingCode { forget(unusedCode: old) }
        pairingCode = CompanionPairingCode(macID: pairings.macID, macName: Host.current().localizedName ?? "Mac", key: key)
        justPaired = nil
        restart()
    }

    /// The pairing sheet closed: a code no phone used stops working.
    func endPairing() {
        guard let code = pairingCode else { return }
        pairingCode = nil
        justPaired = nil
        if forget(unusedCode: code) { restart() }
    }

    /// Forgets `code`'s key unless a phone paired with it; true if it did.
    @discardableResult
    private func forget(unusedCode code: CompanionPairingCode) -> Bool {
        guard !pairings.phones.contains(where: { $0.id == code.key.identity }) else { return false }
        keychain.delete(code.key.identity)
        return true
    }

    /// Unpairs `phone`: its key is deleted, and it is cut off at once.
    func remove(_ phone: CompanionPairings.Phone) {
        pairings.phones.removeAll { $0.id == phone.id }
        keychain.delete(phone.id)
        connected.remove(phone.id)
        save()
        restart()
    }

    /// Every pairing's secret and the list, as Uninstall removes them.
    func removeAll() {
        setOn(false)
        keychain.deleteAll()
        pairings.phones.removeAll()
    }

    // MARK: Phones

    private var keys: [CompanionKey] {
        var keys = pairings.phones.compactMap { keychain.key(for: $0.id) }
        if let code = pairingCode, !keys.contains(code.key) { keys.append(code.key) }
        return keys
    }

    private func restart() {
        guard isOn else { return }
        connected.removeAll()
        publisher.start(macID: pairings.macID, keys: keys)
    }

    private func said(_ hello: CompanionMessage.Hello) {
        let now = Date()
        if let index = pairings.phones.firstIndex(where: { $0.id == hello.pairingID }) {
            pairings.phones[index].name = hello.deviceName
            pairings.phones[index].model = hello.model
            pairings.phones[index].lastSeen = now
        } else if pairingCode?.key.identity == hello.pairingID {
            let phone = CompanionPairings.Phone(id: hello.pairingID, name: hello.deviceName, model: hello.model,
                                                pairedAt: now, lastSeen: now)
            pairings.phones.append(phone)
            justPaired = phone
        } else {
            // TLS let it in, so it holds a paired key, but it names another pairing.
            return
        }
        connected.insert(hello.pairingID)
        save()
    }

    private func left(_ id: String) {
        connected.remove(id)
        guard let index = pairings.phones.firstIndex(where: { $0.id == id }) else { return }
        pairings.phones[index].lastSeen = Date()
        save()
    }

    private func save() {
        do {
            try pairings.save(to: url)
        } catch {
            Log.companion.error("Could not save the companion's pairings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
