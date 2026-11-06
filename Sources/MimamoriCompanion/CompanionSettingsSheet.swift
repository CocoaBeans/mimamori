import SwiftUI
import UIKit
import UserNotifications

/// The iPhone's own settings: what to be notified of, and whether to stay connected in the
/// background so the notifications come while the app isn't on screen.
struct CompanionSettingsSheet: View {
    let notifier: AgentNotifier
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(CompanionNotificationSetting.needsYou) private var needsYou = true
    @AppStorage(CompanionNotificationSetting.turnFinished) private var turnFinished = false
    @AppStorage(CompanionNotificationSetting.collision) private var collision = true
    @AppStorage(CompanionNotificationSetting.staysConnected) private var staysConnected = false
    @AppStorage(ScreenKeeper.keepsScreenOn) private var keepsScreenOn = false
    @AppStorage(ScreenKeeper.onlyWhileCharging) private var onlyWhileCharging = true
    @State private var notificationsDenied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("An agent needs you", isOn: $needsYou)
                        .accessibilityHint("Permission requests and questions")
                    Toggle("An agent finishes a turn", isOn: $turnFinished)
                    Toggle("Two agents edit the same file", isOn: $collision)
                    if notificationsDenied {
                        Button("Turn On Notifications in Settings…") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                        }
                        .help("Notifications for Mimamori are off in Settings")
                    }
                } header: {
                    Text("Notify me when")
                } footer: {
                    Text("As your Mac does. Without staying connected below, they come only while Mimamori is open.")
                }

                Section {
                    Toggle("Stay connected in the background", isOn: $staysConnected)
                } footer: {
                    Text("Mimamori keeps running after you leave it, playing silence so iOS doesn't suspend it, and keeps in touch with your Mac so it can tell you when an agent needs you. Your own music keeps playing. It uses more battery: turn it off when you don't need it.")
                }

                Section {
                    Toggle("Keep the screen on", isOn: $keepsScreenOn)
                        .help("Don't let the iPhone dim or lock while Mimamori is open")
                    Toggle("Only while charging", isOn: $onlyWhileCharging)
                        .disabled(!keepsScreenOn)
                        .help("Keep the screen on only while the iPhone is plugged in")
                } footer: {
                    Text("While Mimamori is open, the iPhone doesn't dim or lock, so your agents stay in view on a stand beside your Mac. Only while charging saves your battery when it's unplugged.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .help("Close settings")
                }
            }
            .task { await checkNotifications() }
            .onChange(of: [needsYou, turnFinished, collision]) {
                Task {
                    await notifier.requestAuthorizationIfNeeded()
                    await checkNotifications()
                }
            }
        }
    }

    private func checkNotifications() async {
        notificationsDenied = await Self.authorizationStatus() == .denied
    }

    /// Off the main actor: the settings object isn't Sendable, and Swift 6.1 won't bring it across.
    private nonisolated static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
