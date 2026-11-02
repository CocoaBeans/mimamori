import Foundation
import UserNotifications
import MimamoriCore

/// Posts user notifications for flagged changes. Only works from a real .app bundle;
/// when run bare via `swift run` the notification center is unavailable, so every call is a no-op.
/// The notifications that offer to watch a repository an agent works in.
private let repositoryOfferCategory = "repository-offer"

@MainActor
final class Notifier {
    private var authorized = false
    private var lastPostByWorktree: [String: Date] = [:]
    /// Kept here: the notification center holds its delegate weakly.
    private var responder: NotificationResponder?

    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    /// Whether notifications may be shown: what macOS says, asking once if you have not been
    /// asked yet. Checked at the moment of posting, so it holds after a relaunch too.
    private func mayNotify() async -> Bool {
        guard isAvailable else { return false }
        if authorized { return true }
        switch await Self.authorizationStatus() {
        case .authorized, .provisional, .ephemeral: authorized = true
        case .notDetermined: return await requestAuthorization()
        default: authorized = false
        }
        return authorized
    }

    private nonisolated static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func post(_ request: UNNotificationRequest) {
        Task {
            guard await mayNotify() else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            authorized = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            authorized = false
        }
        return authorized
    }

    private var lastPostByKey: [String: Date] = [:]

    /// A one-off notification, rate-limited per key.
    func notify(title: String, body: String, key: String, minimumInterval: TimeInterval = 5) {
        guard isAvailable else { return }
        if let last = lastPostByKey[key], Date().timeIntervalSince(last) < minimumInterval { return }
        lastPostByKey[key] = Date()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        post(request)
    }

    /// Registers the offer's Watch and Don't Ask Again buttons, and where the answers go.
    func handleRepositoryOffers(_ handler: @escaping @MainActor @Sendable (_ root: String, _ answer: RepositoryOfferAnswer) -> Void) {
        guard isAvailable else { return }
        let responder = NotificationResponder(handler: handler)
        self.responder = responder
        let center = UNUserNotificationCenter.current()
        center.delegate = responder
        let watch = UNNotificationAction(identifier: "watch", title: "Watch", options: [.foreground])
        let never = UNNotificationAction(identifier: "never", title: "Don't Ask Again")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: repositoryOfferCategory, actions: [watch, never], intentIdentifiers: []),
        ])
    }

    /// "Claude Code is working in new-app": Watch, or Don't Ask Again.
    func offerToWatch(root: String, agent: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(agent) is working in \((root as NSString).lastPathComponent)"
        content.body = "Mimamori doesn't watch \((root as NSString).abbreviatingWithTildeInPath) yet. Watch it?"
        content.sound = .default
        content.categoryIdentifier = repositoryOfferCategory
        content.userInfo = ["repository": root]
        let request = UNNotificationRequest(identifier: "offer:" + root, content: content, trigger: nil)
        post(request)
    }

    /// Takes an offer answered in Mimamori off the screen.
    func withdrawOffer(root: String) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["offer:" + root])
    }

    func notify(entries: [ActivityEntry], worktreeName: String, minimumSeverity: Severity) {
        guard isAvailable else { return }
        let flagged = entries.filter { $0.kind == .flagged && ($0.severity ?? .info) >= minimumSeverity }
        guard !flagged.isEmpty else { return }
        let key = flagged[0].worktreePath
        if let last = lastPostByWorktree[key], Date().timeIntervalSince(last) < 5 { return }
        lastPostByWorktree[key] = Date()

        let content = UNMutableNotificationContent()
        if flagged.count == 1 {
            content.title = flagged[0].title
            content.body = [flagged[0].detail, worktreeName].compactMap { $0 }.joined(separator: " · ")
        } else {
            content.title = "\(flagged.count) flagged changes"
            content.body = "\(worktreeName): " + flagged.prefix(3).map(\.title).joined(separator: ", ")
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        post(request)
    }
}

/// Hands answers to offers back to Mimamori. Offers show even while Mimamori is in front, since
/// they wait for an answer; other notifications show only when it is not, as before.
private final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
    let handler: @MainActor @Sendable (String, RepositoryOfferAnswer) -> Void

    init(handler: @escaping @MainActor @Sendable (String, RepositoryOfferAnswer) -> Void) {
        self.handler = handler
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let root = response.notification.request.content.userInfo["repository"] as? String
        let answer: RepositoryOfferAnswer? = switch response.actionIdentifier {
        case "watch": .watch
        case "never": .never
        default: nil  // a click on the notification itself only opens Mimamori, offer and all
        }
        if let root, let answer {
            let handler = handler
            Task { @MainActor in handler(root, answer) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.categoryIdentifier == repositoryOfferCategory ? [.banner, .sound] : [])
    }
}
