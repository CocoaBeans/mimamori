// Debug builds only: catches the main thread stuck, for hangs that come and go.
#if DEBUG
import Foundation

/// With MIMAMORI_DEBUG_FLAGS=watchdog: a thread of its own asks the main thread to answer four
/// times a second. When it hasn't for a second, it notes the time and records a 3-second `sample`
/// of the app, so a hang is caught as it happens rather than after someone notices; then it notes
/// how long the main thread took to answer. Times are wall-clock, to line up with file changes.
final class MainThreadWatchdog: @unchecked Sendable {
    private static let interval: TimeInterval = 0.25
    private static let patience: TimeInterval = 1
    private static let sampleSeconds = 3

    private let logURL: URL
    private let samplePrefix: String
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Writes to `<prefix>.watchdog.txt`, and samples to `<prefix>.hang-<n>.txt`.
    init(prefix: String) {
        logURL = URL(fileURLWithPath: prefix + ".watchdog.txt")
        samplePrefix = prefix
    }

    func start() {
        let thread = Thread { [self] in watch() }
        thread.name = "Mimamori main-thread watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
        log("watching the main thread")
    }

    private func watch() {
        var hangs = 0
        while true {
            Thread.sleep(forTimeInterval: Self.interval)
            let answered = DispatchSemaphore(value: 0)
            let asked = Date()
            DispatchQueue.main.async { answered.signal() }
            guard answered.wait(timeout: .now() + Self.patience) == .timedOut else { continue }
            hangs += 1
            log("main thread blocked (hang \(hangs)), asked at \(formatter.string(from: asked))")
            let sample = "\(samplePrefix).hang-\(hangs).txt"
            record(sample)
            answered.wait()
            log("main thread answered after \(String(format: "%.1f", Date().timeIntervalSince(asked))) s (hang \(hangs), sample in \(sample))")
        }
    }

    private func record(_ path: String) {
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = [String(ProcessInfo.processInfo.processIdentifier), String(Self.sampleSeconds), "-mayDie", "-file", path]
        sample.standardOutput = FileHandle.nullDevice
        sample.standardError = FileHandle.nullDevice
        do {
            try sample.run()
        } catch {
            log("couldn't sample: \(error.localizedDescription)")
        }
    }

    private func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }
}
#endif
