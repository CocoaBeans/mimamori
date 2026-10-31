import Darwin
import Foundation

/// Who is on the other end of a hook connection.
public struct HookCaller: Sendable, Hashable {
    /// The process that connected, usually the hook's `curl`.
    public var pid: Int32
    /// Its working directory, which a hook command inherits from the agent that ran it.
    public var directory: String?
    /// The agent that ran the hook, found among the caller and its ancestors.
    public var agent: AgentKind?
    public var agentPID: Int32?

    public init(pid: Int32, directory: String? = nil, agent: AgentKind? = nil, agentPID: Int32? = nil) {
        self.pid = pid
        self.directory = directory
        self.agent = agent
        self.agentPID = agentPID
    }

    /// Looks the caller up while it is still connected, and so still running.
    public static func identify(pid: Int32, classifier: AgentClassifier) -> HookCaller {
        let ancestor = ProcessInspector.agentAncestor(of: pid, classifier: classifier)
        return HookCaller(pid: pid, directory: ProcessInspector.currentDirectory(of: pid),
                          agent: ancestor?.kind, agentPID: ancestor?.pid)
    }
}

/// A tiny HTTP/1.1 server on a Unix domain socket. Agent hooks post their JSON here
/// with `curl --unix-socket`; nothing else ever connects.
///
/// Requests: `POST /event` with any agent's hook JSON (see `AgentEventTranslator`), optionally
/// `?agent=<name>` to say which agent it is and `?event=<name>` for a payload that names no
/// event; `POST /event/hermes` for Hermes; `GET /health`.
public final class HookSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HookEvent) -> Void

    public let path: String
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "dev.vigil.hooks", qos: .userInitiated)
    private let connectionQueue = DispatchQueue(label: "dev.vigil.hooks.connections", qos: .userInitiated, attributes: .concurrent)
    /// Hands events over one at a time, in the order their requests completed.
    private let deliveryQueue = DispatchQueue(label: "dev.vigil.hooks.delivery", qos: .userInitiated)
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var listening = false
    private var eventCount = 0
    private var agentClassifier = AgentClassifier()

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    public var isListening: Bool { lock.lock(); defer { lock.unlock() }; return listening }
    public var receivedEvents: Int { lock.lock(); defer { lock.unlock() }; return eventCount }

    /// How callers are recognized as agents; set it to include the names you added in Settings.
    public var classifier: AgentClassifier {
        get { lock.lock(); defer { lock.unlock() }; return agentClassifier }
        set { lock.lock(); agentClassifier = newValue; lock.unlock() }
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard source == nil else { return }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.posixError() }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // Only you can connect: macOS checks write permission on the socket file.
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 64) == 0 else {
            let error = Self.posixError()
            close(fd)
            unlink(path)
            throw error
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        listening = true
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let source else { return }
        source.cancel()
        self.source = nil
        listening = false
        unlink(path)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    // MARK: Connections

    private final class Request {
        var buffer = Data()
        var method = ""
        var target = ""
        var contentLength = 0
        var headerEnd: Int?

        /// Returns the body once headers and body are complete.
        func completeBody() -> Data? {
            if headerEnd == nil {
                guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
                let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                let lines = head.split(separator: "\r\n", omittingEmptySubsequences: true)
                let requestLine = lines.first.map { $0.split(separator: " ") } ?? []
                method = requestLine.count > 0 ? String(requestLine[0]) : ""
                target = requestLine.count > 1 ? String(requestLine[1]) : ""
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                        contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
                headerEnd = range.upperBound
            }
            guard let headerEnd else { return nil }
            guard buffer.count - headerEnd >= contentLength else { return nil }
            return buffer[headerEnd..<(headerEnd + contentLength)]
        }
    }

    private func acceptPending(on listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }  // EAGAIN: nothing more waiting
            // An accepted socket inherits the listener's non-blocking flag; reads here block, with a timeout.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var pid: pid_t = 0
            var length = socklen_t(MemoryLayout<pid_t>.size)
            let peer = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 && pid > 0 ? pid : nil
            connectionQueue.async { [weak self] in
                guard let self else { close(fd); return }
                self.serve(fd, peer: peer)
            }
        }
    }

    private func serve(_ fd: Int32, peer: pid_t?) {
        defer { close(fd) }
        let request = Request()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let body = request.completeBody() {
                let (status, reason, text) = handle(method: request.method, target: request.target, body: body, peer: peer)
                respond(fd, status: status, reason: reason, body: text)
                return
            }
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return }
            request.buffer.append(contentsOf: chunk[0..<count])
            if request.buffer.count > 4_000_000 {
                respond(fd, status: 413, reason: "Payload Too Large", body: "")
                return
            }
        }
    }

    private func handle(method: String, target: String, body: Data, peer: pid_t?) -> (Int, String, String) {
        let url = URLComponents(string: target)
        let query = Dictionary((url?.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
                               uniquingKeysWith: { first, _ in first })
        switch (method, url?.path ?? target) {
        case ("GET", "/health"):
            return (200, "OK", "ok\n")
        case ("POST", "/event"), ("POST", "/event/hermes"):
            let named = url?.path == "/event/hermes" ? .hermes : query["agent"].flatMap(AgentKind.named)
            // Look the caller up while it waits for this reply; once answered it may be gone.
            let caller = peer.map { HookCaller.identify(pid: $0, classifier: classifier) }
            guard let event = AgentEventTranslator.translate(body, agent: named, caller: caller, eventName: query["event"]) else {
                return (400, "Bad Request", "not a hook event\n")
            }
            lock.lock(); eventCount += 1; lock.unlock()
            deliveryQueue.sync { handler(event) }
            return (204, "No Content", "")
        default:
            return (404, "Not Found", "")
        }
    }

    private func respond(_ fd: Int32, status: Int, reason: String, body: String) {
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n"
        if !body.isEmpty { head += "Content-Type: text/plain; charset=utf-8\r\n" }
        head += "\r\n"
        let bytes = Array((head + body).utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            sent += count
        }
    }
}
