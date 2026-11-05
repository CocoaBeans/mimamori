import Foundation
import MimamoriCore

/// Reads and writes Claude Code's settings.json to add or remove Mimamori's hooks.
enum HookInstaller {
    /// Claude Code's settings file, in `CLAUDE_CONFIG_DIR` when that is set, as Claude Code does.
    static var settingsURL: URL { AgentConfigLocations.current.claudeSettings }

    /// Whether launching may update the hooks without being asked. Not from a scratch run, unless
    /// it was pointed at a scratch Claude Code config: it would rewrite the real one.
    static var mayUpdateOnLaunch: Bool {
        !Persistence.isScratch || AgentConfigLocations.current.claudeConfigFromEnvironment
    }

    /// Replaces the hooks the app installed under its former name, which post to its old socket, with
    /// Mimamori's. Returns the backup, if written.
    @discardableResult
    static func migrateFormerHooks(socketPath: String) throws -> URL? {
        guard mayUpdateOnLaunch else { return nil }
        guard ClaudeHooksConfig.hasFormerHooks(in: try load()) else { return nil }
        return try edit { install(into: $0, socketPath: socketPath) }
    }

    /// The settings as a JSON object: empty when there is no file. Throws when the file cannot be
    /// read, or holds no JSON object.
    static func load() throws -> [String: Any] {
        try ConfigFileEditor(file: settingsURL).readJSONObject()
    }

    static func isInstalled() -> Bool {
        (try? load()).map(ClaudeHooksConfig.isInstalled) ?? false
    }

    static func install(socketPath: String) throws -> URL {
        try edit { install(into: $0, socketPath: socketPath) } ?? noBackup
    }

    /// Adds the events a newer Mimamori listens to when an older one installed the rest, so a
    /// status does not stick for want of the event that ends it, makes PermissionRequest wait
    /// for an answer from Mimamori, and rewrites hooks an older Mimamori wrote. Returns the
    /// backup, if written.
    @discardableResult
    static func updateIfOutdated(socketPath: String) throws -> URL? {
        guard mayUpdateOnLaunch else { return nil }
        let command = ClaudeHooksConfig.command(socketPath: socketPath)
        let permissionCommand = ClaudeHooksConfig.permissionCommand(socketPath: socketPath)
        guard ClaudeHooksConfig.isOutdated(in: try load(), command: command, permissionCommand: permissionCommand) else { return nil }
        return try edit { install(into: $0, socketPath: socketPath) }
    }

    static func uninstall() throws -> URL {
        try edit { ClaudeHooksConfig.uninstall(from: $0) } ?? noBackup
    }

    private static func install(into settings: [String: Any], socketPath: String) -> [String: Any] {
        ClaudeHooksConfig.install(into: settings, command: ClaudeHooksConfig.command(socketPath: socketPath),
                                  permissionCommand: ClaudeHooksConfig.permissionCommand(socketPath: socketPath))
    }

    /// Changes the settings in place, keeping their layout, after a backup. Returns the backup,
    /// or nil when there was no file yet.
    private static func edit(_ change: ([String: Any]) -> [String: Any]) throws -> URL? {
        try ConfigFileEditor(file: settingsURL).editJSONObject(keyOrder: ClaudeHooksConfig.keyOrder, change)
    }

    /// What install and uninstall return when there was no file to back up: the name a backup
    /// would have had, as before.
    private static var noBackup: URL { HookBackups.backupURL(of: settingsURL, at: Date()) }
}
