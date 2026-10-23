import Foundation
import VigilCore

/// Writes the Hermes hook script and, when safe, the `hooks:` block in `~/.hermes/config.yaml`.
enum HermesHookInstaller {
    static var hermesHome: URL {
        if let env = ProcessInfo.processInfo.environment["HERMES_HOME"], !env.isEmpty { return URL(fileURLWithPath: env) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
    }
    static var configURL: URL { hermesHome.appendingPathComponent("config.yaml") }
    static var scriptURL: URL { hermesHome.appendingPathComponent(HermesHooksConfig.scriptRelativePath) }
    /// The path as it appears in config.yaml.
    static var scriptPathForConfig: String { "~/.hermes/" + HermesHooksConfig.scriptRelativePath }

    static var isHermesPresent: Bool { FileManager.default.fileExists(atPath: hermesHome.path) }

    enum State: Equatable {
        case notPresent          // no ~/.hermes
        case notInstalled
        case installed
        case manualMergeNeeded   // config has its own hooks: key; show the snippet
    }

    static func state() -> State {
        guard isHermesPresent else { return .notPresent }
        let yaml = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
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
    /// config already has a `hooks:` key and the entries must be merged by hand.
    static func install(socketPath: String) throws -> URL? {
        try writeScript(socketPath: socketPath)
        let yaml = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard let updated = HermesHooksConfig.install(into: yaml, scriptPath: scriptPathForConfig) else { return nil }
        return try write(updated)
    }

    static func uninstall() throws -> URL? {
        try? FileManager.default.removeItem(at: scriptURL)
        let yaml = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let updated = HermesHooksConfig.uninstall(from: yaml)
        guard updated != yaml else { return nil }
        return try write(updated)
    }

    /// The YAML entries for a manual merge under an existing `hooks:` key.
    static var snippet: String { HermesHooksConfig.yamlEntries(scriptPath: scriptPathForConfig) }

    private static func write(_ yaml: String) throws -> URL {
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = hermesHome.appendingPathComponent("config.yaml.\(stamp).vigil-backup")
        if FileManager.default.fileExists(atPath: configURL.path) {
            try FileManager.default.copyItem(at: configURL, to: backup)
        }
        try yaml.write(to: configURL, atomically: true, encoding: .utf8)
        return backup
    }
}
