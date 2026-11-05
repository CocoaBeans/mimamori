import Foundation
import os
import Synchronization

/// What `StateFile.load()` found.
public struct LoadedState: Sendable {
    public var state: PersistedState
    /// Where the file was copied, as it was, because some or all of it couldn't be read.
    public var keptAside: URL?
    /// What went wrong; nil when the file read in full, or wasn't there yet.
    public var problem: String?
    /// The file itself couldn't be read, so this is the copy the save before it kept.
    public var fromPrevious = false

    public init(state: PersistedState, keptAside: URL? = nil, problem: String? = nil, fromPrevious: Bool = false) {
        self.state = state
        self.keptAside = keptAside
        self.problem = problem
        self.fromPrevious = fromPrevious
    }
}

/// The state file on disk, `state.json`.
///
/// Nothing is saved over a file that wasn't read in full: a file that can't all be read, or
/// came from a newer Mimamori, is first copied aside as `state.unreadable-<time>.json`, and one
/// that can't be copied isn't saved over at all. Each save keeps the file it replaces as
/// `state.previous.json`, which is opened in its place when the file itself can't be read.
public final class StateFile: Sendable {
    public let url: URL
    private let status = Mutex(Status())

    private struct Status {
        /// False when saving would lose a file that couldn't be read or kept aside.
        var maySave = true
        /// Whether the file on disk was read in full or written here, so is worth keeping as the previous copy.
        var fileIsKnown = false
    }

    static let log = Logger(subsystem: "com.kevinross.Mimamori", category: "state")

    public init(url: URL) {
        self.url = url
    }

    public var previousURL: URL { sibling("previous") }

    public func load() -> LoadedState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            setStatus(maySave: true, fileIsKnown: false)
            return LoadedState(state: PersistedState())
        } catch {
            // Something may be there, but what can't be read can't be kept aside either.
            Self.log.error("Could not read the state file, so it won't be saved over: \(error.localizedDescription, privacy: .public)")
            setStatus(maySave: false, fileIsKnown: false)
            return LoadedState(state: PersistedState(), problem: error.localizedDescription)
        }

        let state: PersistedState
        do {
            state = try Self.decode(data)
        } catch {
            let problem = Self.describe(error)
            Self.log.error("Could not read the state file: \(problem, privacy: .public)")
            let aside = keepAside(data)
            if let previous = try? Self.decode(Data(contentsOf: previousURL)) {
                Self.log.notice("Opened \(self.previousURL.lastPathComponent, privacy: .public) in its place")
                return LoadedState(state: previous, keptAside: aside, problem: problem, fromPrevious: true)
            }
            return LoadedState(state: PersistedState(), keptAside: aside, problem: problem)
        }

        var problems: [String] = []
        if state.schemaVersion > PersistedState.currentSchemaVersion {
            problems.append("it was written by a newer Mimamori (file version \(state.schemaVersion), this one reads \(PersistedState.currentSchemaVersion))")
        }
        let lost = Self.valuesLost(reading: data, as: state)
        if !lost.isEmpty {
            problems.append("\(lost.count) of its values couldn't be read")
            Self.log.notice("Values in the state file that couldn't be read: \(lost.joined(separator: ", "), privacy: .private)")
        }
        guard !problems.isEmpty else {
            setStatus(maySave: true, fileIsKnown: true)
            return LoadedState(state: state)
        }
        let problem = problems.joined(separator: "; ")
        Self.log.error("Read the state file, but \(problem, privacy: .public)")
        return LoadedState(state: state, keptAside: keepAside(data), problem: problem)
    }

    public func save(_ state: PersistedState) {
        status.withLock { status in
            guard status.maySave else {
                Self.log.error("Not saving state: the file there couldn't be read or kept aside")
                return
            }
            do {
                var state = state
                state.schemaVersion = PersistedState.currentSchemaVersion
                let data = try Self.encode(state)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if status.fileIsKnown, let replaced = try? Data(contentsOf: url), replaced != data {
                    do {
                        try replaced.write(to: previousURL, options: .atomic)
                    } catch {
                        Self.log.error("Could not keep the previous state: \(error.localizedDescription, privacy: .public)")
                    }
                }
                try data.write(to: url, options: .atomic)
                status.fileIsKnown = true
            } catch {
                Self.log.error("Could not save state: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Keeping files aside

    /// Writes `data`, the file as it was read, beside it under a new name. Saving stays off when it can't.
    private func keepAside(_ data: Data) -> URL? {
        let stamp = Self.stampFormatter.string(from: Date())
        for attempt in 1...20 {
            let target = sibling(attempt == 1 ? "unreadable-\(stamp)" : "unreadable-\(stamp)-\(attempt)")
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            do {
                try data.write(to: target, options: .withoutOverwriting)
                Self.log.notice("Kept the state file as it was in \(target.lastPathComponent, privacy: .public)")
                setStatus(maySave: true, fileIsKnown: false)
                return target
            } catch {
                Self.log.error("Could not keep the state file aside, so it won't be saved over: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
        setStatus(maySave: false, fileIsKnown: false)
        return nil
    }

    /// `state.<name>.json`, beside the file.
    private func sibling(_ name: String) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(base).\(name).json")
    }

    private func setStatus(maySave: Bool, fileIsKnown: Bool) {
        status.withLock { $0 = Status(maySave: maySave, fileIsKnown: fileIsKnown) }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    // MARK: Reading and writing

    static func decode(_ data: Data) throws -> PersistedState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PersistedState.self, from: data)
    }

    static func encode(_ state: PersistedState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(state)
    }

    /// The values in `data` that saving `state`, read from it, would not write back: keys added
    /// by a newer Mimamori, enum cases this one doesn't know, entries that couldn't be read.
    static func valuesLost(reading data: Data, as state: PersistedState) -> [String] {
        guard let original = try? JSONSerialization.jsonObject(with: data),
              let rewritten = try? JSONSerialization.jsonObject(with: encode(state)) else { return [] }
        var kept: [String: Int] = [:]
        for leaf in leaves(of: rewritten, at: "") {
            kept[leaf.value, default: 0] += 1
        }
        var lost: [String] = []
        for leaf in leaves(of: original, at: "") {
            let count = kept[leaf.value] ?? 0
            if count > 0 {
                kept[leaf.value] = count - 1
            } else {
                lost.append(leaf.path)
            }
        }
        return lost.sorted()
    }

    /// Every value in a JSON tree, with its path and the two written out together. List
    /// positions are left out of paths, since a set is saved in any order.
    private static func leaves(of node: Any, at path: String) -> [(path: String, value: String)] {
        var found: [(path: String, value: String)] = []
        if let object = node as? [String: Any] {
            if object.isEmpty { found.append((path, path + "={}")) }
            for (key, child) in object {
                let childPath = path.isEmpty ? key : path + "." + key
                found += leaves(of: child, at: childPath)
            }
        } else if let list = node as? [Any] {
            if list.isEmpty { found.append((path, path + "=[]")) }
            for child in list {
                found += leaves(of: child, at: path + "[]")
            }
        } else if !(node is NSNull) {
            found.append((path, "\(path)=\(node)"))
        }
        return found
    }

    /// A decoding error as where it happened and what was wrong.
    static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        let context: DecodingError.Context
        switch error {
        case .dataCorrupted(let found), .keyNotFound(_, let found), .typeMismatch(_, let found), .valueNotFound(_, let found):
            context = found
        @unknown default:
            return error.localizedDescription
        }
        let underlying = context.underlyingError?.localizedDescription
        let message = underlying.map { "\(context.debugDescription) \($0)" } ?? context.debugDescription
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? message : "\(path): \(message)"
    }
}
