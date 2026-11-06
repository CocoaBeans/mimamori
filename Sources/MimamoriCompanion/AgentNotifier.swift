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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        CompanionNotificationSetting.register(in: defaults)
        center.delegate = self
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
            content.sound = .default
            // One thread per worktree, as the Mac's.
            content.threadIdentifier = alert.thread
            content.userInfo = ["kind": alert.kind.rawValue]
            center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
        }
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
        let kind = notification.request.content.userInfo["kind"] as? String
        return kind == CompanionAlerts.Kind.needsYou.rawValue ? [.banner, .list, .sound] : [.list]
    }
}
