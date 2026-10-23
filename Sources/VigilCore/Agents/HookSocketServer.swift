import Foundation
import Network

/// A tiny HTTP/1.1 server on a Unix domain socket. Agent hooks post their JSON here
/// with `curl --unix-socket`; nothing else ever connects.
public final class HookSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HookEvent) -> Void

    public let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.vigil.hooks", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var listening = false
    private var eventCount = 0

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    public var isListening: Bool { lock.lock(); defer { lock.unlock() }; return listening }
    public var receivedEvents: Int { lock.lock(); defer { lock.unlock() }; return eventCount }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard listener == nil else { return }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.lock.lock()
            switch state {
            case .ready: self.listening = true
            case .failed, .cancelled: self.listening = false
            default: break
            }
            self.lock.unlock()
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        listener?.cancel()
        listener = nil
        listening = false
        unlink(path)
    }

    // MARK: Connections

    private final class Request: @unchecked Sendable {
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

    private func accept(_ connection: NWConnection) {
        let request = Request()
        connection.start(queue: queue)
        receive(on: connection, into: request)
    }

    private func receive(on connection: NWConnection, into request: Request) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if let data { request.buffer.append(data) }
            if request.buffer.count > 4_000_000 {
                self.respond(connection, status: 413, reason: "Payload Too Large", body: "")
                return
            }
            if let body = request.completeBody() {
                let (status, reason, text) = self.handle(method: request.method, target: request.target, body: body)
                self.respond(connection, status: status, reason: reason, body: text)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, into: request)
        }
    }

    private func handle(method: String, target: String, body: Data) -> (Int, String, String) {
        switch (method, target) {
        case ("GET", "/health"):
            return (200, "OK", "ok\n")
        case ("POST", "/event"):
            guard let event = HookEventParser.parse(body) else { return (400, "Bad Request", "not a hook event\n") }
            lock.lock(); eventCount += 1; lock.unlock()
            handler(event)
            return (204, "No Content", "")
        default:
            return (404, "Not Found", "")
        }
    }

    private func respond(_ connection: NWConnection, status: Int, reason: String, body: String) {
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n"
        if !body.isEmpty { head += "Content-Type: text/plain; charset=utf-8\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + Data(body.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
