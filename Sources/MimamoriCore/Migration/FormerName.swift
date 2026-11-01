import Foundation

/// The app was called Vigil until November 2026. Its first launch as Mimamori finds what the old
/// name left behind (its settings folder, and its hooks in Claude Code's and Hermes's config) and
/// carries it over. These are the old names: the only place "vigil" may appear in the code, which
/// a test checks.
public enum FormerName {
    /// `~/Library/Application Support/Vigil`.
    public static let supportFolder = "Vigil"
    public static let socketFile = "vigil.sock"
    /// In every Claude Code hook command the old app installed.
    public static let claudeHookMarker = "vigil.sock"
    public static let hermesScriptRelativePath = "agent-hooks/vigil.sh"
    public static let hermesBeginMarker = "# --- Vigil hooks (added by Vigil; remove this block to uninstall) ---"
    public static let hermesEndMarker = "# --- end Vigil hooks ---"
}

/// Moves the old app's support folder (state, activity log, shadow indexes) to the new one.
public enum SupportFolderMigration {
    /// Moves `legacy` to `destination` when it exists and `destination` does not, keeping a copy
    /// of `state.json` aside first and deleting the old socket. Returns whether it moved anything.
    @discardableResult
    public static func migrate(from legacy: URL, to destination: URL, fileManager: FileManager = .default) throws -> Bool {
        guard fileManager.fileExists(atPath: legacy.path), !fileManager.fileExists(atPath: destination.path) else { return false }
        let state = legacy.appendingPathComponent("state.json")
        if fileManager.fileExists(atPath: state.path) {
            let aside = legacy.appendingPathComponent("state.json.before-rename")
            try? fileManager.removeItem(at: aside)
            try fileManager.copyItem(at: state, to: aside)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // One rename on the same volume: it happens entirely or not at all.
        try fileManager.moveItem(at: legacy, to: destination)
        try? fileManager.removeItem(at: destination.appendingPathComponent(FormerName.socketFile))
        return true
    }
}
