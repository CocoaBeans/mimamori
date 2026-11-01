import Foundation
import CoreServices

public struct FSEvent: Sendable, Hashable {
    public let path: String
    public let flags: FSEventStreamEventFlags

    public init(path: String, flags: FSEventStreamEventFlags) {
        self.path = path
        self.flags = flags
    }

    private func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }
    public var isDirectory: Bool { has(kFSEventStreamEventFlagItemIsDir) }
    public var mustScanSubDirs: Bool { has(kFSEventStreamEventFlagMustScanSubDirs) }
    public var rootChanged: Bool { has(kFSEventStreamEventFlagRootChanged) }
    public var isHistoryDone: Bool { has(kFSEventStreamEventFlagHistoryDone) }
}

/// A thin wrapper over an FSEvents stream delivering file-level events on a private queue.
public final class FSEventsWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable ([FSEvent]) -> Void

    private let paths: [String]
    private let exclusions: [String]
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.kevinross.Mimamori.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private let lock = NSLock()

    public init(paths: [String], exclusions: [String] = [], latency: TimeInterval = 0.25, handler: @escaping Handler) {
        self.paths = paths
        self.exclusions = exclusions
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    public enum WatchError: Error, LocalizedError {
        case creationFailed
        case startFailed
        public var errorDescription: String? {
            switch self {
            case .creationFailed: "Could not create the file system event stream."
            case .startFailed: "Could not start the file system event stream."
            }
        }
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagNoDefer)
            | UInt32(kFSEventStreamCreateFlagWatchRoot)

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            let flags = UnsafeBufferPointer(start: eventFlags, count: count)
            var events: [FSEvent] = []
            events.reserveCapacity(count)
            for index in 0..<min(count, paths.count) {
                events.append(FSEvent(path: paths[index], flags: flags[index]))
            }
            watcher.handler(events)
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, FSEventStreamCreateFlags(flags)) else {
            throw WatchError.creationFailed
        }
        if !exclusions.isEmpty {
            FSEventStreamSetExclusionPaths(created, Array(exclusions.prefix(8)) as CFArray)
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw WatchError.startFailed
        }
        stream = created
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
