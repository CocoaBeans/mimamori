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
    /// When the code shown was made, so the sheet can say what to check if no phone comes.
    private(set) var pairingStartedAt: Date?
    /// Phones connected now, by pairing id.
    private(set) var connected: Set<String> = []
    /// What's keeping phones from connecting, in a sentence; nil while all is well.
    private(set) var problem: String?

    /// Whether Mimamori answers permission requests, the ids of those waiting now, and the
    /// questions' texts of those that ask some: what an answer from a phone is checked against.
    /// Set by AppModel.
    @ObservationIgnored var permissionRequests: () -> (answering: Bool, pending: Set<String>, questions: [String: Set<String>])
        = { (false, [], [:]) }
    /// Settles a request a paired phone answered, with the phone's name; set by AppModel.
    @ObservationIgnored var onAnswer: (_ requestID: String, _ allow: Bool, _ phone: String) -> Void = { _, _, _ in }
    /// Answers a request's questions with a paired phone's answers, with the phone's name; set by AppModel.
    @ObservationIgnored var onAnswerQuestions: (_ requestID: String, _ answers: [String: String], _ phone: String) -> Void
        = { _, _, _ in }

    @ObservationIgnored private var pendingUpdate: Task<Void, Never>?
    @ObservationIgnored private let publisher = CompanionPublisher()
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let keychain: CompanionKeychain

    init(url: URL = Persistence.companionURL, keychain: CompanionKeychain = Persistence.companionKeychain) {
        self.url = url
        self.keychain = keychain
        pairings = CompanionPairings.load(from: url)
        publisher.onHello = { [weak self] hello in self?.said(hello) }
        publisher.secret = { [weak self] pairingID in self?.secret(for: pairingID) }
        publisher.onAnswer = { [weak self] answer, pairingID in
            self?.answered(answer, pairingID: pairingID)
                ?? CompanionMessage.AnswerResult(requestID: answer.requestID, accepted: false)
        }
        publisher.onGoodbye = { [weak self] id in self?.left(id) }
        publisher.onProblem = { [weak self] problem in self?.problem = problem }
    }

    /// An agent's list of actions, by worktree, for a phone showing it.
    var actionsFor: ((String) -> AgentActions?)? {
        get { publisher.actionsFor }
        set { publisher.actionsFor = newValue }
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

    /// The agents once the change under way is done: a request coming or going changes the
    /// agents' state in more than one step, and the phone should get the end of it.
    func updateSoon(_ agents: @escaping @MainActor () -> [AgentWidgetSnapshot.Agent]) {
        guard isOn, pendingUpdate == nil else { return }
        pendingUpdate = Task { [weak self] in
            guard let self else { return }
            self.pendingUpdate = nil
            self.update(agents())
        }
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
        pairingStartedAt = Date()
        justPaired = nil
        restart()
    }

    /// The pairing sheet closed: a code no phone used stops working.
    func endPairing() {
        guard let code = pairingCode else { return }
        pairingCode = nil
        pairingStartedAt = nil
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

    /// The secret a phone proves `pairingID` with: a paired phone's, or the code's on show. Nil for
    /// any other id, such as a phone removed here whose key is gone.
    private func secret(for pairingID: String) -> Data? {
        let paired = pairings.phones.contains { $0.id == pairingID }
        guard paired || pairingCode?.key.identity == pairingID else { return nil }
        return keychain.key(for: pairingID)?.secret
    }

    /// A phone's Allow or Deny, or its answers to a request's questions: settled only if it comes
    /// from a phone that proved it's paired, for a request that still waits (`CompanionAnswerCheck`).
    private func answered(_ answer: CompanionMessage.Answer, pairingID: String?) -> CompanionMessage.AnswerResult {
        let requests = permissionRequests()
        let phones = Dictionary(pairings.phones.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let verdict = CompanionAnswerCheck.verdict(for: answer, pairingID: pairingID, phones: phones,
                                                   answering: requests.answering, pending: requests.pending,
                                                   questions: requests.questions)
        switch verdict {
        case .answer(let id, let allow, let phone):
            onAnswer(id, allow, phone)
            return CompanionMessage.AnswerResult(requestID: id, accepted: true)
        case .answers(let id, let answers, let phone):
            onAnswerQuestions(id, answers, phone)
            return CompanionMessage.AnswerResult(requestID: id, accepted: true)
        case .refuse(let reason):
            Log.companion.notice("Turned down an answer from an iPhone: \(reason, privacy: .public)")
            return CompanionMessage.AnswerResult(requestID: answer.requestID, accepted: false, reason: reason)
        }
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
