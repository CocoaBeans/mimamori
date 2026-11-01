import Foundation
import MimamoriCore

/// Reads and writes `~/.claude/settings.json` to add or remove Mimamori's hooks.
enum HookInstaller {
    /// Claude Code's settings file, in `CLAUDE_CONFIG_DIR` when that is set, as Claude Code does.
    static var settingsURL: URL {
        if let directory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !directory.isEmpty {
            return URL(fileURLWithPath: directory).appendingPathComponent("settings.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// Whether launching may update the hooks without being asked. Not from a scratch run, unless
    /// it was pointed at a scratch Claude Code config: it would rewrite the real one.
    static var mayUpdateOnLaunch: Bool {
        !Persistence.isScratch || !(ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? "").isEmpty
    }

    /// Replaces the hooks the app installed under its former name, which post to its old socket, with
    /// Mimamori's. Returns the backup, if written.
    @discardableResult
    static func migrateFormerHooks(socketPath: String) throws -> URL? {
        guard mayUpdateOnLaunch else { return nil }
        let settings = try load()
        guard ClaudeHooksConfig.hasFormerHooks(in: settings) else { return nil }
        return try write(ClaudeHooksConfig.install(into: settings, command: ClaudeHooksConfig.command(socketPath: socketPath)))
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

    /// Adds the events a newer Mimamori listens to when an older one installed the rest, so a
    /// status does not stick for want of the event that ends it. Returns the backup, if written.
    @discardableResult
    static func updateIfOutdated(socketPath: String) throws -> URL? {
        guard mayUpdateOnLaunch else { return nil }
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
        let backup = directory.appendingPathComponent("settings.json.\(stamp).mimamori-backup")
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
