import Foundation

/// Where Claude Code and Hermes keep their config, read once from the environment the way each
/// agent does: `$CLAUDE_CONFIG_DIR` or `~/.claude`, and `$HERMES_HOME` or `~/.hermes`. A leading
/// `~` in either variable means the home folder.
public struct AgentConfigLocations: Sendable, Equatable {
    public let home: URL
    /// Claude Code's own folder.
    public let claudeConfigDirectory: URL
    /// True when `CLAUDE_CONFIG_DIR` chose the folder.
    public let claudeConfigFromEnvironment: Bool
    /// Hermes's own folder.
    public let hermesHome: URL
    /// True when `HERMES_HOME` chose the folder.
    public let hermesHomeFromEnvironment: Bool

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
        let claude = Self.folder(environment["CLAUDE_CONFIG_DIR"], home: self.home)
        claudeConfigDirectory = claude ?? self.home.appendingPathComponent(".claude", isDirectory: true)
        claudeConfigFromEnvironment = claude != nil
        let hermes = Self.folder(environment["HERMES_HOME"], home: self.home)
        hermesHome = hermes ?? self.home.appendingPathComponent(".hermes", isDirectory: true)
        hermesHomeFromEnvironment = hermes != nil
    }

    /// The locations for this process's environment.
    public static var current: AgentConfigLocations { AgentConfigLocations() }

    public var claudeSettings: URL { claudeConfigDirectory.appendingPathComponent("settings.json") }
    /// Where Claude Code records its running sessions.
    public var claudeSessions: URL { claudeConfigDirectory.appendingPathComponent("sessions", isDirectory: true) }

    public var hermesConfig: URL { hermesHome.appendingPathComponent("config.yaml") }
    public var hermesScript: URL { hermesHome.appendingPathComponent(HermesHooksConfig.scriptRelativePath) }
    /// Where Hermes records the hooks you approved.
    public var hermesAllowlist: URL { hermesHome.appendingPathComponent(HermesHooksConfig.allowlistFileName) }
    /// Hermes's session database.
    public var hermesStateDatabase: URL { hermesHome.appendingPathComponent("state.db") }

    /// The script's path as written in config.yaml: `~/…` inside the home folder, as Hermes expands
    /// it, and quoted for Hermes's word splitting when it has spaces or other special characters.
    public var hermesScriptPathForConfig: String {
        let path = hermesScript.path
        let homePath = home.path
        guard path.hasPrefix(homePath + "/") else { return Self.shellQuoted(path) }
        return "~/" + Self.shellQuoted(String(path.dropFirst(homePath.count + 1)))
    }

    /// `value` as a folder, or nil when it is unset or empty.
    private static func folder(_ value: String?, home: URL) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        let path: String
        if value == "~" {
            path = home.path
        } else if value.hasPrefix("~/") {
            path = home.path + value.dropFirst(1)
        } else {
            // `~name/…`, an absolute path, or one relative to the current folder.
            path = (value as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// `text` unchanged when the shell would read it as one plain word, else in single quotes.
    static func shellQuoted(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@%,:")
        if !text.isEmpty, text.unicodeScalars.allSatisfy(plain.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
