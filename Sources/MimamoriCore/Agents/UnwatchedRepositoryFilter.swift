import Foundation

/// Which folders an agent works in could be repositories worth offering to watch: not your home
/// or anything above it, not temporary folders, and not the dot folders in your home that agents
/// and tools keep for themselves (`~/.hermes`, `~/.claude`).
public struct UnwatchedRepositoryFilter: Sendable {
    public let home: String
    private static let temporary = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.home = (home as NSString).standardizingPath
    }

    /// Whether to ask git about a folder an agent works in, or about a repository's root.
    public func allows(_ directory: String) -> Bool {
        guard directory.hasPrefix("/") else { return false }
        let path = (directory as NSString).standardizingPath
        if path == "/" || path == home || home.hasPrefix(path + "/") { return false }
        if Self.temporary.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
        if path.hasPrefix(home + "/.") { return false }
        return true
    }
}
