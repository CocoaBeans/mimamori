import Foundation
import UserNotifications
import MimamoriCore

/// Posts user notifications for flagged changes. Only works from a real .app bundle;
/// when run bare via `swift run` the notification center is unavailable, so every call is a no-op.
@MainActor
final class Notifier {
    private var authorized = false
    private var lastPostByWorktree: [String: Date] = [:]

    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
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
        guard isAvailable, authorized else { return }
        if let last = lastPostByKey[key], Date().timeIntervalSince(last) < minimumInterval { return }
        lastPostByKey[key] = Date()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    func notify(entries: [ActivityEntry], worktreeName: String, minimumSeverity: Severity) {
        guard isAvailable, authorized else { return }
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
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
}
