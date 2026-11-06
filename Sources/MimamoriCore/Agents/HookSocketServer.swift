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

/// A request the socket turned down, kept so you can see why a hook setup does not report.
/// It records the shape of what arrived, never its content: prompts and code stay out of it.
public struct HookRejection: Sendable, Hashable {
    public var status: Int
    /// Why, in a few words: "not a hook event", "no such address".
    public var reason: String
    /// The address the request was sent to, such as `/event?agent=codex`.
    public var target: String
    /// The top-level keys of the JSON body; nil when the body was not a JSON object.
    public var keys: [String]?
    public var at: Date

    public init(status: Int, reason: String, target: String, keys: [String]? = nil, at: Date = Date()) {
        self.status = status
        self.reason = reason
        self.target = target
        self.keys = keys
        self.at = at
    }

    /// The top-level keys of a JSON object, sorted; nil for anything else.
    static func keys(of body: Data) -> [String]? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any]).map { $0.keys.sorted() }
    }
}

/// A tiny HTTP/1.1 server on a Unix domain socket. Agent hooks post their JSON here
/// with `curl --unix-socket`; nothing else ever connects.
///
/// Requests: `POST /event` with any agent's hook JSON (see `AgentEventTranslator`), optionally
/// `?agent=<name>` to say which agent it is and `?event=<name>` for a payload that names no
/// event; `POST /event/hermes` for Hermes; `GET /health`. A body with a `mimamori_test` key is a
/// test from Settings: it is answered and reported, not handed on as an agent's event.
///
/// Every copy of Mimamori uses the same path, and a socket file that is replaced leaves its
/// listener reachable by nothing. So a server never takes the path from another that answers
/// there, removes only its own socket file, and checks now and then that the file is still its
/// own: when another copy took it and has quit, it takes the path back.
public final class HookSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HookEvent) -> Void

    /// What the server reports besides events.
    public enum Note: Sendable {
        case rejected(HookRejection)
        /// A test arrived, carrying the token it was sent with.
        case test(token: String)
        /// The hook waiting on permission request `id` went away before an answer: the agent no
        /// longer waits on it. Claude Code ends the hook when you say no in its own prompt.
        case hungUp(permission: String)
        /// The server stopped or started listening after it started: another copy of Mimamori
        /// took the socket, or let it go.
        case state(State)
    }

    /// Whether the server has the socket.
    public enum State: Sendable, Equatable {
        case stopped
        case listening
        /// Another copy of Mimamori answers at the path, so events go to it. This one takes the
        /// path once nothing answers there.
        case deferring
    }

    public let path: String
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "com.kevinross.Mimamori.hooks", qos: .userInitiated)
    private let connectionQueue = DispatchQueue(label: "com.kevinross.Mimamori.hooks.connections", qos: .userInitiated, attributes: .concurrent)
    /// Hands events over one at a time, in the order their requests completed.
    private let deliveryQueue = DispatchQueue(label: "com.kevinross.Mimamori.hooks.delivery", qos: .userInitiated)
    /// Watches the connections of hooks waiting on a permission answer for hanging up.
    private let hangUpQueue = DispatchQueue(label: "com.kevinross.Mimamori.hooks.hang-ups", qos: .userInitiated)
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var listening = false
    private var currentState = State.stopped
    /// The socket file this server bound, to tell it from one another copy put at the path.
    private var socketFile: (device: dev_t, inode: ino_t)?
    private var pathWatch: DispatchSourceTimer?
    /// How often the server checks that the socket file at the path is still its own.
    public var pathCheckInterval: TimeInterval = 5
    private var eventCount = 0
    private var agentClassifier = AgentClassifier()
    private var noteHandler: (@Sendable (Note) -> Void)?
    private var answering = false
    /// Permission requests waiting on an answer from Mimamori.
    public let permissions = PermissionBroker()
    /// The longest a permission request waits: under the hook's own timeout, so the hook ends
    /// on its own terms.
    public var permissionTimeout: TimeInterval = 590

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    public var isListening: Bool { lock.lock(); defer { lock.unlock() }; return listening }
    public var state: State { lock.lock(); defer { lock.unlock() }; return currentState }
    public var receivedEvents: Int { lock.lock(); defer { lock.unlock() }; return eventCount }

    /// How callers are recognized as agents; set it to include the names you added in Settings.
    public var classifier: AgentClassifier {
        get { lock.lock(); defer { lock.unlock() }; return agentClassifier }
        set { lock.lock(); agentClassifier = newValue; lock.unlock() }
    }

    /// Told of rejected requests and of tests, on the server's own queues.
    public var onNote: (@Sendable (Note) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return noteHandler }
        set { lock.lock(); noteHandler = newValue; lock.unlock() }
    }

    private func note(_ note: Note) { onNote?(note) }

    /// A file to append every request's body to, as it came, one JSON line each with the time and
    /// the address it was posted to; nil, as normally, writes nothing. For looking at what agents
    /// actually send (MIMAMORI_DEBUG_FLAGS=hooks:raw in a debug build).
    public var rawLog: URL? {
        get { lock.lock(); defer { lock.unlock() }; return rawLogURL }
        set { lock.lock(); rawLogURL = newValue; lock.unlock() }
    }
    private var rawLogURL: URL?
    private let rawLogLock = NSLock()

    private func logRaw(_ body: Data, target: String) {
        guard let url = rawLog else { return }
        var line: [String: Any] = ["at": Date().timeIntervalSince1970, "target": target]
        line["body"] = (try? JSONSerialization.jsonObject(with: body)) ?? String(decoding: body, as: UTF8.self)
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        // Requests are handled at the same time; one write at a time keeps each line whole.
        rawLogLock.lock()
        defer { rawLogLock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Whether `/permission` waits for an answer from Mimamori. Off, it reports the request like
    /// any other event and answers at once with no decision.
    public var answersPermissions: Bool {
        get { lock.lock(); defer { lock.unlock() }; return answering }
        set { lock.lock(); answering = newValue; lock.unlock() }
    }

    /// Listens at `path`, unless another copy of Mimamori answers there: then it defers to that
    /// copy (`state` says so) and takes the path once nothing answers. Throws when the socket
    /// cannot be made, for instance when the path is longer than a socket address allows.
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard currentState == .stopped else { return }
        guard Self.address(for: path) != nil else { throw POSIXError(.ENAMETOOLONG) }
        if Self.answers(at: path) {
            // Taking the path would leave that copy listening on a file nothing can reach.
            currentState = .deferring
        } else {
            try bindLocked()
        }
        let watch = DispatchSource.makeTimerSource(queue: acceptQueue)
        let interval = max(0.05, pathCheckInterval)
        watch.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 200)))
        watch.setEventHandler { [weak self] in self?.checkPath() }
        watch.resume()
        pathWatch = watch
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        pathWatch?.cancel()
        pathWatch = nil
        // A file another copy put at the path is that copy's to remove.
        if ownsPathLocked() { unlink(path) }
        closeListenerLocked()
        currentState = .stopped
    }

    /// Makes sure events reach a Mimamori: while listening, that the socket file at the path is
    /// still this server's; while deferring, that the other copy still answers. Takes the path
    /// (back) when nothing answers there. Runs every `pathCheckInterval` seconds by itself.
    @discardableResult
    public func checkPath() -> State {
        lock.lock()
        let before = currentState
        let settled = before == .stopped || (before == .listening && ownsPathLocked())
        lock.unlock()
        if settled { return before }

        // Another copy replaced the socket file (or it was removed): this listener is out of reach.
        let otherCopy = Self.answers(at: path)
        lock.lock()
        guard currentState != .stopped else { lock.unlock(); return .stopped }
        closeListenerLocked()
        if otherCopy {
            currentState = .deferring
        } else {
            // Not ours to give up on: try again at the next check.
            do { try bindLocked() } catch { currentState = .deferring }
        }
        let after = currentState
        lock.unlock()
        if after != before { note(.state(after)) }
        return after
    }

    /// Binds a fresh socket at the path, replacing whatever file is there. Call with `lock` held.
    private func bindLocked() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard var address = Self.address(for: path) else { throw POSIXError(.ENAMETOOLONG) }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.posixError() }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // Only you can connect: macOS checks write permission on the socket file.
        var file = stat()
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 64) == 0, stat(path, &file) == 0 else {
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
        socketFile = (file.st_dev, file.st_ino)
        listening = true
        currentState = .listening
    }

    /// Call with `lock` held.
    private func closeListenerLocked() {
        source?.cancel()
        source = nil
        socketFile = nil
        listening = false
    }

    /// Whether the file at the path is the socket this server bound. Call with `lock` held.
    private func ownsPathLocked() -> Bool {
        guard let socketFile else { return false }
        var file = stat()
        return stat(path, &file) == 0 && file.st_dev == socketFile.device && file.st_ino == socketFile.inode
    }

    private static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// Whether something listens at `path`: another copy of Mimamori. A socket file left by a
    /// copy that quit refuses the connection.
    static func answers(at path: String) -> Bool {
        guard var address = address(for: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
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
                let (status, reason, text) = handle(method: request.method, target: request.target, body: body, peer: peer, fd: fd)
                respond(fd, status: status, reason: reason, body: text)
                return
            }
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return }
            request.buffer.append(contentsOf: chunk[0..<count])
            if request.buffer.count > 4_000_000 {
                respond(fd, status: 413, reason: "Payload Too Large", body: "")
                note(.rejected(HookRejection(status: 413, reason: "larger than 4 MB", target: request.target)))
                return
            }
        }
    }

    private func handle(method: String, target: String, body: Data, peer: pid_t?, fd: Int32) -> (Int, String, String) {
        if method == "POST" { logRaw(body, target: target) }
        let url = URLComponents(string: target)
        let query = Dictionary((url?.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
                               uniquingKeysWith: { first, _ in first })
        switch (method, url?.path ?? target) {
        case ("GET", "/health"):
            return (200, "OK", "ok\n")
        case ("POST", "/permission"):
            // A permission request whose hook waits for an answer: reported like any event, then
            // held until answered here, let go, or timed out. No decision answers 204, empty.
            let caller = peer.map { HookCaller.identify(pid: $0, classifier: classifier) }
            guard var event = AgentEventTranslator.translate(body, agent: query["agent"].flatMap(AgentKind.named) ?? .claudeCode,
                                                             caller: caller, eventName: query["event"]) else {
                note(.rejected(HookRejection(status: 400, reason: "not a hook event", target: target, keys: HookRejection.keys(of: body))))
                return (400, "Bad Request", "not a hook event\n")
            }
            lock.lock(); eventCount += 1; lock.unlock()
            let id = answersPermissions ? UUID().uuidString : nil
            event.permissionRequestID = id
            if let id { permissions.open(id) }
            deliveryQueue.sync { handler(event) }
            guard let id, let answer = waitForAnswer(id, hook: fd) else { return (204, "No Content", "") }
            return (200, "OK", answer.hookResponse + "\n")
        case ("POST", "/event"), ("POST", "/event/hermes"):
            // A test from Settings: the cheap byte search keeps agents' events from being parsed twice.
            if body.range(of: Data("mimamori_test".utf8)) != nil,
               let token = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["mimamori_test"] as? String {
                note(.test(token: token))
                return (204, "No Content", "")
            }
            let named = url?.path == "/event/hermes" ? .hermes : query["agent"].flatMap(AgentKind.named)
            // Look the caller up while it waits for this reply; once answered it may be gone.
            let caller = peer.map { HookCaller.identify(pid: $0, classifier: classifier) }
            guard let event = AgentEventTranslator.translate(body, agent: named, caller: caller, eventName: query["event"]) else {
                note(.rejected(HookRejection(status: 400, reason: body.isEmpty ? "empty, and no ?event= to name it" : "not a hook event",
                                             target: target, keys: HookRejection.keys(of: body))))
                return (400, "Bad Request", "not a hook event\n")
            }
            lock.lock(); eventCount += 1; lock.unlock()
            deliveryQueue.sync { handler(event) }
            return (204, "No Content", "")
        default:
            note(.rejected(HookRejection(status: 404, reason: "no such address; hooks post to /event", target: "\(method) \(target)")))
            return (404, "Not Found", "")
        }
    }

    /// Waits for an answer to `id` while watching the hook's connection. A hook that hangs up
    /// first was ended by its agent, which no longer waits on the answer: the request is let go
    /// then, and reported, rather than held until the timeout.
    private func waitForAnswer(_ id: String, hook fd: Int32) -> PermissionAnswer? {
        let watch = DispatchSource.makeReadSource(fileDescriptor: fd, queue: hangUpQueue)
        let stopped = DispatchSemaphore(value: 0)
        watch.setEventHandler { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = recv(fd, &bytes, bytes.count, MSG_DONTWAIT)
            // Bytes after the request are none of ours, and are dropped; only the end matters.
            guard count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) else { return }
            watch.cancel()
            guard let self, self.permissions.answer(id, nil) else { return }
            self.note(.hungUp(permission: id))
        }
        watch.setCancelHandler { stopped.signal() }
        watch.resume()
        let answer = permissions.wait(id, timeout: permissionTimeout)
        // The socket closes once the reply is written: stop watching it first.
        watch.cancel()
        stopped.wait()
        return answer
    }

    private func respond(_ fd: Int32, status: Int, reason: String, body: String) {
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n"
        if !body.isEmpty { head += "Content-Type: \(body.hasPrefix("{") ? "application/json" : "text/plain; charset=utf-8")\r\n" }
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
