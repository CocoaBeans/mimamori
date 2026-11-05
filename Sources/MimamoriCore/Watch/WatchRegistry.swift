import Foundation

/// Keeps at most one watch per key, such as a file system watcher per repository. Making a watch
/// awaits (finding the folder to watch), so stopping a key also cancels a start still on its way,
/// and a watch that arrives for a key stopped meanwhile is ended instead of kept.
@MainActor
public final class WatchRegistry<Key: Hashable & Sendable, Watch: Sendable> {
    private var starts: [Key: Task<Void, Never>] = [:]
    private var watches: [Key: Watch] = [:]
    private let end: @MainActor (Watch) -> Void

    /// - Parameter end: stops a watch that is replaced, stopped, or arrives too late.
    public init(end: @escaping @MainActor (Watch) -> Void) {
        self.end = end
    }

    /// The keys with a watch, not counting starts still on their way.
    public var watchedKeys: Set<Key> { Set(watches.keys) }

    /// Whether a start for `key` is still on its way.
    public func isStarting(_ key: Key) -> Bool { starts[key] != nil }

    /// Watches `key` with what `make` returns, in place of anything it watched before. A nil from
    /// `make` leaves the key unwatched. The task returned finishes once the watch is kept or ended.
    @discardableResult
    public func start(_ key: Key, make: @escaping @MainActor () async -> Watch?) -> Task<Void, Never> {
        stop(key)
        let end = self.end
        let task = Task { [weak self] in
            let watch = Task.isCancelled ? nil : await make()
            // Stopped while the watch was being made: it must not outlive its key.
            guard let self, !Task.isCancelled else {
                if let watch { end(watch) }
                return
            }
            self.starts[key] = nil
            if let watch { self.watches[key] = watch }
        }
        starts[key] = task
        return task
    }

    /// Ends `key`'s watch, and cancels its start if it is still on its way.
    public func stop(_ key: Key) {
        starts.removeValue(forKey: key)?.cancel()
        if let watch = watches.removeValue(forKey: key) { end(watch) }
    }

    public func stopAll() {
        for key in Set(starts.keys).union(watches.keys) { stop(key) }
    }
}
