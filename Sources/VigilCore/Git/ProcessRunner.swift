import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessError: Error, LocalizedError, Sendable {
    case launchFailed(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let s): "Could not launch process: \(s)"
        case .timedOut(let s): "Process timed out: \(s)"
        }
    }
}

/// Runs a subprocess without blocking a cooperative thread pool thread.
/// Output is collected through readability handlers; completion is a continuation.
public enum ProcessRunner {
    private final class Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private final class DataSink: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ data: Data) { lock.lock(); buffer.append(data); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.lock(); raised = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }

    /// Writing to a pipe whose reader exited would otherwise kill the app with SIGPIPE.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    public static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: Duration = .seconds(60)
    ) async throws -> ProcessResult {
        _ = ignoreSIGPIPE
        let description = ([executable.lastPathComponent] + arguments).joined(separator: " ")

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory
            if let environment { process.environment = environment }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            let inPipe: Pipe? = stdin == nil ? nil : Pipe()
            if let inPipe {
                process.standardInput = inPipe
            } else {
                process.standardInput = FileHandle.nullDevice
            }

            let out = DataSink()
            let err = DataSink()
            let timedOut = Flag()
            let group = DispatchGroup()

            group.enter()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    group.leave()
                } else {
                    out.append(data)
                }
            }
            group.enter()
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    group.leave()
                } else {
                    err.append(data)
                }
            }
            group.enter()
            process.terminationHandler = { _ in group.leave() }

            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: ProcessError.launchFailed("\(description): \(error.localizedDescription)"))
                return
            }

            if let stdin, let inPipe {
                let writer = Box(inPipe.fileHandleForWriting)
                DispatchQueue.global(qos: .userInitiated).async {
                    try? writer.value.write(contentsOf: stdin)
                    try? writer.value.close()
                }
            }

            let boxed = Box(process)
            let timeoutItem = DispatchWorkItem {
                if boxed.value.isRunning {
                    timedOut.raise()
                    boxed.value.terminate()
                }
            }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timeoutItem)

            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                timeoutItem.cancel()
                if timedOut.isRaised {
                    continuation.resume(throwing: ProcessError.timedOut(description))
                } else {
                    continuation.resume(returning: ProcessResult(
                        status: boxed.value.terminationStatus,
                        stdout: out.value,
                        stderr: err.value
                    ))
                }
            }
        }
    }
}
