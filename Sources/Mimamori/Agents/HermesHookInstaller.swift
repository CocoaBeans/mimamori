import Foundation
import MimamoriCore

/// Writes the Hermes hook script and, when safe, the `hooks:` block in Hermes's config.yaml
/// (in `~/.hermes`, or `$HERMES_HOME`).
enum HermesHookInstaller {
    static var hermesHome: URL { AgentConfigLocations.current.hermesHome }
    static var configURL: URL { AgentConfigLocations.current.hermesConfig }
    static var scriptURL: URL { AgentConfigLocations.current.hermesScript }
    /// The path as it appears in config.yaml.
    static var scriptPathForConfig: String { AgentConfigLocations.current.hermesScriptPathForConfig }

    static var allowlistURL: URL { AgentConfigLocations.current.hermesAllowlist }
    /// Hermes's session database, which records where each session works.
    static var stateDatabaseURL: URL { AgentConfigLocations.current.hermesStateDatabase }

    /// Mimamori's hook events Hermes has not been allowed to run yet.
    static func unapprovedEvents() -> [String] {
        HermesHooksConfig.unapprovedEvents(allowlistJSON: try? Data(contentsOf: allowlistURL), scriptPath: scriptPathForConfig)
    }

    static var isHermesPresent: Bool { FileManager.default.fileExists(atPath: hermesHome.path) }

    enum State: Equatable {
        case notPresent          // no Hermes home
        case notInstalled
        case installed
        case manualMergeNeeded   // config has its own hooks: key; show the snippet
    }

    static func state() -> State {
        guard isHermesPresent else { return .notPresent }
        let yaml = (try? editor.readText()) ?? ""
        if HermesHooksConfig.isInstalled(in: yaml) { return .installed }
        if HermesHooksConfig.hasTopLevelHooksKey(yaml) { return .manualMergeNeeded }
        return .notInstalled
    }

    static func writeScript(socketPath: String) throws {
        try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try HermesHooksConfig.script(socketPath: socketPath).write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// Writes the script and appends the block. Returns the backup URL, or nil when the
    /// config already has a `hooks:` key and the entries must be merged by hand. Throws, and
    /// leaves the config alone, when it cannot be read.
    static func install(socketPath: String) throws -> URL? {
        let yaml = try editor.readText()
        try writeScript(socketPath: socketPath)
        guard HermesHooksConfig.install(into: yaml, scriptPath: scriptPathForConfig) != nil else { return nil }
        return try edit { HermesHooksConfig.install(into: $0, scriptPath: scriptPathForConfig) ?? $0 } ?? noBackup
    }

    /// Removes the block, then the script. Returns the backup, or nil when there was no block.
    /// Throws, and leaves both alone, when the config cannot be read.
    static func uninstall() throws -> URL? {
        let yaml = try editor.readText()
        var backup: URL?
        if HermesHooksConfig.uninstall(from: yaml) != yaml {
            backup = try edit { HermesHooksConfig.uninstall(from: $0) }
        }
        try? FileManager.default.removeItem(at: scriptURL)
        return backup
    }

    /// The YAML entries for a manual merge under an existing `hooks:` key.
    static var snippet: String { HermesHooksConfig.yamlEntries(scriptPath: scriptPathForConfig) }

    private static var editor: ConfigFileEditor { ConfigFileEditor(file: configURL) }

    /// Changes config.yaml in place after a backup. Returns the backup, or nil when there was no file yet.
    private static func edit(_ change: (String) -> String) throws -> URL? {
        try editor.editText(change)
    }

    /// What install returns when there was no file to back up: the name a backup would have had, as before.
    private static var noBackup: URL { HookBackups.backupURL(of: configURL, at: Date()) }
}
