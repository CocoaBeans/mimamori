import Foundation
import MimamoriShared
import UserNotifications

/// What the iPhone notifies you of, as the Mac does: an agent needs you, finished a turn, or
/// collides with another. Each one is a switch in the app's settings.
enum CompanionNotificationSetting {
    static let needsYou = "notifyNeedsYou"
    static let turnFinished = "notifyTurnFinished"
    static let collision = "notifyCollision"
    /// Keep running in the background, so notifications come while the app isn't on screen.
    static let staysConnected = "staysConnectedInBackground"

    /// The Mac's defaults: who needs you and collisions on, finished turns off.
    static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [needsYou: true, turnFinished: false, collision: true, staysConnected: false])
    }
}

/// Posts local notifications as the agents change (`CompanionAlerts` works out which), each kind
/// as its switch in the app's settings allows.
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Not kept: Swift 6.1 won't send a stored center across actors, as `await` on it would.
    private var center: UNUserNotificationCenter { .current() }
    private let defaults: UserDefaults
    private var previous: [AgentWidgetSnapshot.Agent]?
    private var askedForPermission = false
    /// Sends a notification's Allow or Deny to the Mac: nil once it took it, otherwise why not.
    var answer: (@MainActor (_ requestID: String, _ allow: Bool) async -> String?)?

    /// A permission request's notification, with Allow and Deny.
    static let permissionCategory = "permissionRequest"
    private static let allowAction = "allow"
    private static let denyAction = "deny"
    private static let answerFailedID = "answerFailed"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        CompanionNotificationSetting.register(in: defaults)
        center.delegate = self
        // Allow runs a command on the Mac, so the phone must be unlocked for it; Deny needn't be.
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow", options: [.authenticationRequired],
                                         icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive],
                                        icon: UNNotificationActionIcon(systemImageName: "xmark"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.permissionCategory, actions: [allow, deny], intentIdentifiers: []),
        ])
    }

    private var wantsAny: Bool {
        [CompanionNotificationSetting.needsYou, CompanionNotificationSetting.turnFinished,
         CompanionNotificationSetting.collision].contains { defaults.bool(forKey: $0) }
    }

    /// Asks once to post notifications, when some are wanted.
    func requestAuthorizationIfNeeded() async {
        guard wantsAny, !askedForPermission else { return }
        askedForPermission = true
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// A new connection: the next snapshot is the baseline again.
    func reset() {
        previous = nil
    }

    func update(_ snapshot: AgentWidgetSnapshot) {
        let changes = CompanionAlerts.changes(from: previous, to: snapshot.agents)
        previous = snapshot.agents
        if !changes.withdraw.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: changes.withdraw)
            center.removePendingNotificationRequests(withIdentifiers: changes.withdraw)
        }
        for alert in changes.post where defaults.bool(forKey: Self.setting(for: alert.kind)) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = alert.quiet ? nil : .default
            // One thread per worktree, as the Mac's.
            content.threadIdentifier = alert.thread
            var info: [String: Any] = ["kind": alert.kind.rawValue, "quiet": alert.quiet]
            if let requestID = alert.requestID {
                content.categoryIdentifier = Self.permissionCategory
                info["requestID"] = requestID
            }
            content.userInfo = info
            center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
        }
    }

    /// A notification's Allow or Deny. If the Mac didn't take it, a notification says why, since
    /// the one you answered is gone.
    func handle(action: String, requestID: String) async {
        guard action == Self.allowAction || action == Self.denyAction, let answer else { return }
        let allow = action == Self.allowAction
        guard let failure = await answer(requestID, allow) else { return }
        postFailure(failure, allow: allow)
    }

    /// Not async: awaiting the center's `add` would send it across actors, which Swift 6.1 refuses.
    private func postFailure(_ failure: String, allow: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Couldn't \(allow ? "allow" : "deny") from your iPhone"
        content.body = failure
        content.sound = .default
        content.userInfo = ["kind": "answerFailed"]
        center.add(UNNotificationRequest(identifier: Self.answerFailedID, content: content, trigger: nil))
    }

    private static func setting(for kind: CompanionAlerts.Kind) -> String {
        switch kind {
        case .needsYou: CompanionNotificationSetting.needsYou
        case .turnFinished: CompanionNotificationSetting.turnFinished
        case .collision: CompanionNotificationSetting.collision
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// With the app open, the cards already show what changed: only who needs you gets a banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        let kind = info["kind"] as? String
        // An update that only adds or drops Allow and Deny has been announced already.
        if info["quiet"] as? Bool == true { return [.list] }
        return kind == CompanionAlerts.Kind.needsYou.rawValue || kind == "answerFailed" ? [.banner, .list, .sound] : [.list]
    }

    /// Allow or Deny on a notification. iOS may have woken the app in the background for it, and
    /// waits until this returns.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard let requestID = response.notification.request.content.userInfo["requestID"] as? String else { return }
        await handle(action: action, requestID: requestID)
    }
}
