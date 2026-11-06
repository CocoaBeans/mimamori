import Foundation
import UserNotifications
import MimamoriCore

/// Posts user notifications for flagged changes. Only works from a real .app bundle;
/// when run bare via `swift run` the notification center is unavailable, so every call is a no-op.
/// The notifications that offer to watch a repository an agent works in.
private let repositoryOfferCategory = "repository-offer"
/// The notifications that let you answer an agent's permission request.
private let permissionCategory = "permission-request"

/// What you answered in a notification's buttons.
enum NotificationAnswer: Sendable {
    case repository(root: String, RepositoryOfferAnswer)
    case permission(id: String, allow: Bool)
}

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

    /// Registers the notifications' buttons (Watch and Don't Ask Again on an offer, Allow and
    /// Deny on a permission request) and where the answers go.
    func handleAnswers(_ handler: @escaping @MainActor @Sendable (NotificationAnswer) -> Void) {
        guard isAvailable else { return }
        let responder = NotificationResponder(handler: handler)
        self.responder = responder
        let center = UNUserNotificationCenter.current()
        center.delegate = responder
        let watch = UNNotificationAction(identifier: "watch", title: "Watch", options: [.foreground])
        let never = UNNotificationAction(identifier: "never", title: "Don't Ask Again")
        let allow = UNNotificationAction(identifier: "allow", title: "Allow")
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: repositoryOfferCategory, actions: [watch, never], intentIdentifiers: []),
            UNNotificationCategory(identifier: permissionCategory, actions: [allow, deny], intentIdentifiers: []),
        ])
    }

    /// "Codex asks to use Bash": Allow, or Deny. The agent's own prompt is open meanwhile.
    func askPermission(id: String, title: String, subtitle: String? = nil, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.sound = .default
        content.categoryIdentifier = permissionCategory
        content.userInfo = ["permission": id]
        post(UNNotificationRequest(identifier: "permission:" + id, content: content, trigger: nil))
    }

    /// Takes a request answered elsewhere, or let go, off the screen.
    func withdrawPermission(id: String) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["permission:" + id])
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

/// Hands answers from notifications' buttons back to Mimamori. Offers and permission requests
/// show even while Mimamori is in front, since they wait for an answer; other notifications show
/// only when it is not, as before.
private final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
    let handler: @MainActor @Sendable (NotificationAnswer) -> Void

    init(handler: @escaping @MainActor @Sendable (NotificationAnswer) -> Void) {
        self.handler = handler
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        // A click on the notification itself only opens Mimamori, the question still open.
        let answer: NotificationAnswer? = switch (response.actionIdentifier, info["repository"] as? String, info["permission"] as? String) {
        case ("watch", let root?, _): .repository(root: root, .watch)
        case ("never", let root?, _): .repository(root: root, .never)
        case ("allow", _, let id?): .permission(id: id, allow: true)
        case ("deny", _, let id?): .permission(id: id, allow: false)
        default: nil
        }
        if let answer {
            let handler = handler
            Task { @MainActor in handler(answer) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let category = notification.request.content.categoryIdentifier
        completionHandler(category == repositoryOfferCategory || category == permissionCategory ? [.banner, .sound] : [])
    }
}
