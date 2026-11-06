import SwiftUI
import UIKit

/// Keeps the iPhone's screen from dimming and locking while Mimamori is open, so the agents stay
/// in view on a stand beside the Mac. iOS honours this only while the app is on screen.
@MainActor
@Observable
final class ScreenKeeper {
    static let keepsScreenOn = "keepsScreenOn"
    static let onlyWhileCharging = "keepsScreenOnOnlyWhileCharging"

    /// Plugged in, charging or full.
    private(set) var isCharging = false
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        isCharging = Self.pluggedIn
        observer = NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isCharging = Self.pluggedIn }
        }
    }

    /// Whether the screen should stay on: asked for, Mimamori on screen, and plugged in unless
    /// you said it needn't be.
    static func staysOn(asked: Bool, onlyWhileCharging: Bool, active: Bool, charging: Bool) -> Bool {
        asked && active && (charging || !onlyWhileCharging)
    }

    private static var pluggedIn: Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full: true
        default: false
        }
    }
}
