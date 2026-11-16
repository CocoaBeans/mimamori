import Foundation
import MimamoriShared
import Observation
import os
import UIKit

/// The phone's background log (`CompanionEventLog`), kept in a file of its own beside the app's
/// settings, so it outlasts the app being ended. Each entry also goes to the system log.
@MainActor @Observable
final class BackgroundLog {
    static let shared = BackgroundLog()

    private(set) var log: CompanionEventLog
    @ObservationIgnored private let url: URL
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private static let logger = Logger(subsystem: "com.kevinross.Mimamori.Companion", category: "background-log")

    init(url: URL = BackgroundLog.defaultURL) {
        self.url = url
        log = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(CompanionEventLog.self, from: $0) }
            ?? CompanionEventLog()
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        log.started(version: version)
        save()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated { BackgroundLog.shared.add(.app, "Memory warning: iOS may end the app soon") }
        })
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated { BackgroundLog.shared.add(.app, "Ending: quit, or ended by iOS while running") }
        })
    }

    static var defaultURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent("background-log.json")
    }

    func add(_ kind: CompanionEventLog.Kind, _ text: String) {
        log.add(kind, text)
        Self.logger.notice("[\(kind.rawValue, privacy: .public)] \(text, privacy: .public)")
        save()
    }

    /// The app is running in the background now.
    func heartbeat() {
        log.heartbeat()
        save()
    }

    /// The app came to the front: says so, and if it had stopped running in the background, from
    /// when to when.
    func cameToFront() {
        log.cameToFront()
        add(.app, "Came to the front")
    }

    func clear() {
        log.clear()
        save()
    }

    /// Small, and written at once: in the background, iOS may suspend the app at any moment after.
    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(log).write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Couldn't save the background log: \(error.localizedDescription, privacy: .public)")
        }
    }
}
