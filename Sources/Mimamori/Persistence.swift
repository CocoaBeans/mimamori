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
        let folder = base.appendingPathComponent("Mimamori", isDirectory: true)
        // The first launch under the new name brings the old folder's repositories, reviews,
        // settings and activity log across, before anything reads them.
        do {
            if try SupportFolderMigration.migrate(from: base.appendingPathComponent(FormerName.supportFolder, isDirectory: true), to: folder) {
                Log.migration.notice("Moved the settings folder over from \(FormerName.supportFolder, privacy: .public)")
            }
        } catch {
            Log.migration.error("Could not move the settings folder over from \(FormerName.supportFolder, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return folder
    }()

    /// A scripted run in a throwaway folder (MIMAMORI_SUPPORT_DIR), which must leave your real setup alone.
    static let isScratch = !(ProcessInfo.processInfo.environment["MIMAMORI_SUPPORT_DIR"] ?? "").isEmpty

    static var stateURL: URL { supportDirectory.appendingPathComponent("state.json") }
    static var shadowIndexDirectory: URL { supportDirectory.appendingPathComponent("index", isDirectory: true) }
    static var activityURL: URL { supportDirectory.appendingPathComponent("activity.jsonl") }

    static let state = StateFile(url: stateURL)
}
