import Foundation
import MimamoriCore

/// Where Mimamori keeps its files. Reading and writing `state.json` is `StateFile`'s job.
enum Persistence {
    static let supportDirectory: URL = {
        // Debug hook: a throwaway folder, so a scripted run never touches the real state or socket.
        if let override = ProcessInfo.processInfo.environment["MIMAMORI_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Mimamori", isDirectory: true)
    }()

    /// A scripted run in a throwaway folder (MIMAMORI_SUPPORT_DIR), which must leave your real setup alone.
    static let isScratch = !(ProcessInfo.processInfo.environment["MIMAMORI_SUPPORT_DIR"] ?? "").isEmpty

    static var stateURL: URL { supportDirectory.appendingPathComponent("state.json") }
    static var shadowIndexDirectory: URL { supportDirectory.appendingPathComponent("index", isDirectory: true) }
    static var activityURL: URL { supportDirectory.appendingPathComponent("activity.jsonl") }

    static let state = StateFile(url: stateURL)
}
