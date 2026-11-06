import Foundation
import LocalAuthentication
import MimamoriShared
import os
import UIKit

/// Where an answer from this phone stands, for the card to show.
enum AnswerState: Equatable {
    /// Waiting for Face ID, or for the connection.
    case sending(allow: Bool)
    /// The Mac took it; the next snapshot settles the request.
    case sent(allow: Bool)
    /// It didn't reach the Mac, or the Mac turned it down, in a sentence.
    case failed(String)
}

/// Allow and Deny from the phone. Allow runs a command on the Mac, so it asks for Face ID or the
/// passcode first; Deny is one tap. Either goes over the open connection, and the Mac settles the
/// request only if it still waits.
extension CompanionModel {
    private static let log = Logger(subsystem: "com.kevinross.Mimamori.Companion", category: "answers")
    /// How long to wait for the Mac to say what became of an answer.
    private static let resultTimeout: Duration = .seconds(5)
    /// How long a notification's action waits for the connection to come back: finding the Mac
    /// again can take one failed try of 10 s, and iOS gives an action about 30 s.
    private static let reconnectTimeout: TimeInterval = 20

    /// Answers `request` from its card.
    func answer(_ request: AgentWidgetSnapshot.PermissionRequest, allow: Bool) async {
        answers[request.id] = .sending(allow: allow)
        if allow, let refusal = await PermissionAuthentication.confirmAllow(tool: request.tool) {
            // Cancelled, or Face ID failed: nothing was sent.
            if refusal.isEmpty { answers[request.id] = nil } else { answers[request.id] = .failed(refusal) }
            return
        }
        if let failure = await send(requestID: request.id, allow: allow) {
            answers[request.id] = .failed(failure)
        } else {
            answers[request.id] = .sent(allow: allow)
        }
    }

    /// A notification's Allow or Deny. iOS has had the phone unlocked for Allow already. The
    /// connection may be down, if iOS suspended the app: reconnect for a moment, then let go again.
    /// Nil once the Mac took it; otherwise why not.
    func answerFromNotification(requestID: String, allow: Bool) async -> String? {
        let wasConnected = connectedMac != nil
        if !wasConnected {
            resume()
            let deadline = Date().addingTimeInterval(Self.reconnectTimeout)
            while connectedMac == nil, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        let failure = await send(requestID: requestID, allow: allow)
        if failure == nil { answers[requestID] = .sent(allow: allow) }
        // Woken in the background just for this: let go of the Mac again, as suspending does.
        if !wasConnected, UIApplication.shared.applicationState == .background { suspend() }
        return failure
    }

    /// Sends the answer and waits for the Mac's word on it. Nil once the Mac took it.
    private func send(requestID: String, allow: Bool) async -> String? {
        let mac = chosen?.name ?? "your Mac"
        guard connectedMac != nil else { return "Not connected to \(mac), so your answer wasn't sent." }
        guard await sendNow(CompanionMessage(answer: .init(requestID: requestID, allow: allow))) else {
            return "Couldn't reach \(mac), so your answer wasn't sent."
        }
        Self.log.notice("Sent \(allow ? "Allow" : "Deny", privacy: .public) for request \(requestID, privacy: .public)")
        guard let result = await result(for: requestID) else {
            return "\(mac) didn't say whether it took your answer. Check the agent on the Mac."
        }
        Self.log.notice("The Mac \(result.accepted ? "took" : "turned down", privacy: .public) the answer: \(result.reason ?? "-", privacy: .public)")
        return result.accepted ? nil : result.reason ?? "\(mac) didn't take your answer."
    }

    /// The Mac's word on `requestID`'s answer, or nil if it doesn't come in time.
    private func result(for requestID: String) async -> CompanionMessage.AnswerResult? {
        // It can come before this starts waiting.
        if let early = earlyAnswerResults.removeValue(forKey: requestID) { return early }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.resultTimeout)
            guard !Task.isCancelled else { return }
            self?.finishWaiting(for: requestID, with: nil)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            answerWaiters[requestID, default: []].append(continuation)
        }
    }

    func answerResultArrived(_ result: CompanionMessage.AnswerResult) {
        if answerWaiters[result.requestID] == nil {
            earlyAnswerResults[result.requestID] = result
        } else {
            finishWaiting(for: result.requestID, with: result)
        }
    }

    private func finishWaiting(for requestID: String, with result: CompanionMessage.AnswerResult?) {
        for waiter in answerWaiters.removeValue(forKey: requestID) ?? [] { waiter.resume(returning: result) }
    }

    /// A request the snapshot no longer has is settled: what was sent for it is done with.
    func settleAnswers(with snapshot: AgentWidgetSnapshot) {
        let waiting = Set(snapshot.agents.compactMap(\.permissionRequest?.id))
        for id in answers.keys where !waiting.contains(id) { answers[id] = nil }
        #if DEBUG
        debugAnswer(snapshot)
        #endif
    }

    #if DEBUG
    /// For scripted runs: `-debugAnswer allow` (or `deny`) answers each request that appears, as
    /// its card's button does, Face ID included, after `-debugAnswerDelay` seconds (2 by default).
    /// `-debugAnswerVia notification` answers as the notification's action does instead, after
    /// letting go of the Mac, as iOS suspending the app would.
    private func debugAnswer(_ snapshot: AgentWidgetSnapshot) {
        let defaults = UserDefaults.standard
        guard let choice = defaults.string(forKey: "debugAnswer"), choice == "allow" || choice == "deny" else { return }
        let delay = defaults.object(forKey: "debugAnswerDelay") == nil ? 2 : defaults.double(forKey: "debugAnswerDelay")
        let viaNotification = defaults.string(forKey: "debugAnswerVia") == "notification"
        for request in snapshot.agents.compactMap(\.permissionRequest) where !debugAnswered.contains(request.id) {
            debugAnswered.insert(request.id)
            Self.log.notice("Debug: answering \(request.id, privacy: .public) with \(choice, privacy: .public) in \(delay) s")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                if viaNotification {
                    self.suspend()
                    let failure = await self.answerFromNotification(requestID: request.id, allow: choice == "allow")
                    Self.log.notice("Debug: notification answer \(failure ?? "taken", privacy: .public)")
                } else {
                    await self.answer(request, allow: choice == "allow")
                    Self.log.notice("Debug: card answer \(String(describing: self.answers[request.id]), privacy: .public)")
                }
            }
        }
    }
    #endif
}

/// Face ID, Touch ID or the passcode, before Allow from a card.
enum PermissionAuthentication {
    /// Nil to go ahead; otherwise why not, empty when you cancelled.
    @MainActor
    static func confirmAllow(tool: String) async -> String? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // With no passcode set there is nothing to ask for, as for a notification's Allow,
            // which iOS lets through on such a phone too.
            if (error as? LAError)?.code == .passcodeNotSet { return nil }
            return "Allow needs Face ID or your passcode: \(error?.localizedDescription ?? "not available")"
        }
        let reason = "Allow \(tool) to run on your Mac"
        // The callback form, so the context never leaves this actor.
        let (allowed, failure) = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, (any Error)?), Never>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { allowed, failure in
                continuation.resume(returning: (allowed, failure))
            }
        }
        if allowed { return nil }
        if let code = (failure as? LAError)?.code, [.userCancel, .appCancel, .systemCancel].contains(code) { return "" }
        return "Not allowed: \(failure?.localizedDescription ?? "not confirmed")"
    }
}
