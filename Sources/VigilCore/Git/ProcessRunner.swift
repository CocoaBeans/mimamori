import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessError: Error, LocalizedError, Sendable {
    case launchFailed(reason: String, command: String)
    case timedOut(String)
    case directoryMissing(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason, let command): "Could not launch \(command.split(separator: " ").first ?? "process"): \(reason)"
        case .timedOut(let s): "Process timed out: \(s)"
        case .directoryMissing(let path): "The folder no longer exists: \(path)"
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
        if let currentDirectory, !FileManager.default.fileExists(atPath: currentDirectory.path) {
            throw ProcessError.directoryMissing(currentDirectory.path)
        }

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

            // Read until EOF, then close the descriptor right away. Waiting for deallocation
            // leaks pipes for as long as anything retains the Process (see the timeout below).
            group.enter()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    try? handle.close()
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
                    try? handle.close()
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
                try? outPipe.fileHandleForReading.close()
                try? errPipe.fileHandleForReading.close()
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                if let inPipe {
                    try? inPipe.fileHandleForReading.close()
                    try? inPipe.fileHandleForWriting.close()
                }
                continuation.resume(throwing: ProcessError.launchFailed(reason: error.localizedDescription, command: description))
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
            // The timer must not keep a finished Process (and its pipes) alive until the deadline.
            let timeoutItem = DispatchWorkItem { [weak boxed] in
                guard let process = boxed?.value, process.isRunning else { return }
                timedOut.raise()
                process.terminate()
            }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timeoutItem)

            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                timeoutItem.cancel()
                let status = boxed.value.terminationStatus
                boxed.value.terminationHandler = nil
                if timedOut.isRaised {
                    continuation.resume(throwing: ProcessError.timedOut(description))
                } else {
                    continuation.resume(returning: ProcessResult(status: status, stdout: out.value, stderr: err.value))
                }
            }
        }
    }
}
