import Foundation

/// Edits another tool's config file, such as Claude Code's settings.json or Hermes's config.yaml,
/// without losing anything of the user's:
/// - a symlinked file stays a symlink: the edit goes to the file it points to;
/// - a file that exists but cannot be read or decoded is left alone, and the edit throws;
/// - a copy is saved beside the file first, under a name no other copy has;
/// - the first copy ever saved (`<file>.mimamori-original`) is never pruned;
/// - the new contents replace the old in one rename, keeping the file's permissions.
public struct ConfigFileEditor: Sendable {
    public enum EditError: Error, LocalizedError, Equatable {
        case unreadable(path: String, reason: String)
        case notUTF8(path: String)
        case notJSON(path: String, reason: String)
        case notAnObject(path: String)
        case tooManySymlinks(path: String)
        case changedWhileEditing(path: String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path, let reason):
                "Mimamori could not read \(Self.short(path)) (\(reason)), so it left the file as it is."
            case .notUTF8(let path):
                "\(Self.short(path)) is not UTF-8 text, so Mimamori left it as it is."
            case .notJSON(let path, let reason):
                "\(Self.short(path)) is not valid JSON (\(reason)), so Mimamori left it as it is."
            case .notAnObject(let path):
                "\(Self.short(path)) does not contain a JSON object, so Mimamori left it as it is."
            case .tooManySymlinks(let path):
                "\(Self.short(path)) leads through too many symbolic links, so Mimamori left it as it is."
            case .changedWhileEditing(let path):
                "\(Self.short(path)) changed while Mimamori was editing it, so Mimamori left it as it is. Try again."
            }
        }

        private static func short(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
    }

    /// The file as configured, which may be a symlink. Backups go beside it.
    public let file: URL
    private let now: @Sendable () -> Date

    public init(file: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.now = now
    }

    /// The file that reads and writes reach: `file` with any symlinks to it followed.
    public func resolvedFile() throws -> URL {
        var url = file.standardizedFileURL
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return url }
            url = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).absoluteURL.standardizedFileURL
        }
        throw EditError.tooManySymlinks(path: file.path)
    }

    /// The file's contents, or nil when there is no file. Throws when it exists but cannot be read.
    public func read() throws -> Data? {
        let target = try resolvedFile()
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        do {
            return try Data(contentsOf: target)
        } catch {
            throw EditError.unreadable(path: file.path, reason: Self.reason(error))
        }
    }

    /// The file as UTF-8 text: "" when there is no file.
    public func readText() throws -> String {
        try Self.text(try read(), path: file.path)
    }

    /// The file as a JSON object: empty when there is no file or it is blank.
    public func readJSONObject() throws -> [String: Any] {
        try Self.jsonObject(try read(), path: file.path)
    }

    /// Changes the text with `change` and writes it back after a backup. Returns the backup, or
    /// nil when there was no file to back up.
    @discardableResult
    public func editText(_ change: (String) throws -> String) throws -> URL? {
        let original = try read()
        let updated = try change(try Self.text(original, path: file.path))
        return try write(Data(updated.utf8), replacing: original)
    }

    /// Changes the JSON object with `change` and writes it back after a backup, in the layout it
    /// had. New keys follow `keyOrder`, then their names. Returns the backup, or nil when there
    /// was no file to back up.
    @discardableResult
    public func editJSONObject(keyOrder: [String] = [], _ change: ([String: Any]) throws -> [String: Any]) throws -> URL? {
        let original = try read()
        let updated = try change(try Self.jsonObject(original, path: file.path))
        return try write(JSONLayout.data(for: updated, keepingLayoutOf: original, keyOrder: keyOrder), replacing: original)
    }

    /// Saves a backup, then replaces the file's contents with `data`, as long as the file still
    /// holds `expected` (nil: no file). Returns the backup, or nil when there was no file.
    @discardableResult
    public func write(_ data: Data, replacing expected: Data?) throws -> URL? {
        let target = try resolvedFile()
        guard try read() == expected else { throw EditError.changedWhileEditing(path: file.path) }
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let permissions = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
        var backup: URL?
        if let expected {
            try keepOriginal(expected, permissions: permissions)
            backup = try saveBackup(expected, permissions: permissions)
            HookBackups.prune(file)
        }
        try replaceContents(of: target, with: data, permissions: permissions)
        return backup
    }

    // MARK: Backups

    /// Saves the first copy Mimamori takes of the file, which pruning never removes. From a
    /// version that had no such copy, the oldest backup still there stands in for it.
    private func keepOriginal(_ contents: Data, permissions: NSNumber?) throws {
        let original = HookBackups.originalURL(of: file)
        guard !FileManager.default.fileExists(atPath: original.path) else { return }
        let oldest = HookBackups.list(of: file).last { !Self.isSymlink($0) }
        let earliest = oldest.flatMap { try? Data(contentsOf: $0) } ?? contents
        try Self.create(original, with: earliest, permissions: permissions)
    }

    private func saveBackup(_ contents: Data, permissions: NSNumber?) throws -> URL {
        let date = now()
        var attempt = 1
        while true {
            let backup = HookBackups.backupURL(of: file, at: date, attempt: attempt)
            do {
                try Self.create(backup, with: contents, permissions: permissions)
                return backup
            } catch CocoaError.fileWriteFileExists where attempt < 100 {
                attempt += 1
            }
        }
    }

    /// Writes a new file, failing if one is already there.
    private static func create(_ url: URL, with contents: Data, permissions: NSNumber?) throws {
        try contents.write(to: url, options: .withoutOverwriting)
        if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    }

    // MARK: Writing

    /// Writes beside `target` and renames over it, so a reader sees the old file or the new one.
    private func replaceContents(of target: URL, with data: Data, permissions: NSNumber?) throws {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).mimamori-\(UUID().uuidString)")
        do {
            try Self.create(temporary, with: data, permissions: permissions)
            guard rename(temporary.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    // MARK: Decoding

    private static func text(_ data: Data?, path: String) throws -> String {
        guard let data else { return "" }
        guard let text = String(data: data, encoding: .utf8) else { throw EditError.notUTF8(path: path) }
        return text
    }

    private static func jsonObject(_ data: Data?, path: String) throws -> [String: Any] {
        let text = try text(data, path: path)
        guard let data, !text.allSatisfy(\.isWhitespace) else { return [:] }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        } catch {
            throw EditError.notJSON(path: path, reason: reason(error))
        }
        guard let dictionary = object as? [String: Any] else { throw EditError.notAnObject(path: path) }
        return dictionary
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private static func reason(_ error: Error) -> String {
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        if let underlying, underlying.domain == NSPOSIXErrorDomain, let code = POSIXErrorCode(rawValue: Int32(underlying.code)) {
            return String(cString: strerror(code.rawValue))
        }
        if let debug = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String { return debug }
        return error.localizedDescription
    }
}
