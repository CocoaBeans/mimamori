import Foundation
import VigilCore

/// Reads and writes `~/.claude/settings.json` to add or remove Vigil's hooks.
enum HookInstaller {
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static func load() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.notAnObject
        }
        return object
    }

    static func isInstalled() -> Bool {
        (try? load()).map(ClaudeHooksConfig.isInstalled) ?? false
    }

    static func install(socketPath: String) throws -> URL {
        let settings = try load()
        let command = ClaudeHooksConfig.command(socketPath: socketPath)
        return try write(ClaudeHooksConfig.install(into: settings, command: command))
    }

    /// Adds the events a newer Vigil listens to when an older one installed the rest, so a
    /// status does not stick for want of the event that ends it. Returns the backup, if written.
    @discardableResult
    static func updateIfOutdated(socketPath: String) throws -> URL? {
        let settings = try load()
        let command = ClaudeHooksConfig.command(socketPath: socketPath)
        guard ClaudeHooksConfig.isOutdated(in: settings, command: command) else { return nil }
        return try write(ClaudeHooksConfig.install(into: settings, command: command))
    }

    static func uninstall() throws -> URL {
        let settings = try load()
        return try write(ClaudeHooksConfig.uninstall(from: settings))
    }

    /// Writes the settings atomically after saving a timestamped backup. Returns the backup URL.
    private static func write(_ settings: [String: Any]) throws -> URL {
        let directory = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = directory.appendingPathComponent("settings.json.\(stamp).vigil-backup")
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            try FileManager.default.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
        return backup
    }

    enum InstallError: Error, LocalizedError {
        case notAnObject
        var errorDescription: String? {
            switch self {
            case .notAnObject: "settings.json does not contain a JSON object."
            }
        }
    }
}
