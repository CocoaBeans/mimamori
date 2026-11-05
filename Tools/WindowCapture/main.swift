// WindowCapture: captures one window as it looks on screen, with its glass, vibrancy and shadow,
// using ScreenCaptureKit. Mimamori's own captures (MIMAMORI_SCREENSHOT) draw the window into an
// image, which flattens those. It is an app of its own so that it, and not the terminal or editor
// that starts it, holds the Screen Recording permission. Run it through Scripts/capture-window.sh.
//
//   list [--all]                                windows on screen: id, app, pid, size, title
//                                               (--all: menus, popovers and the like too, with their layer)
//   shot   <window> --out <file.png> [--no-shadow]
//   record <window> --out <file.mov> [--seconds <n>] [--until <file>] [--fps <n>] [--no-shadow]
//
// <window> is any of --app <bundle id or name>, --pid <pid>, --title <text>, --window <id>;
// the largest window that matches is taken. A window named by --window is taken whatever its
// layer, such as a menu-bar popover. A recording stops after --seconds (default 60) or once the
// --until file exists, whichever comes first.

import AppKit
import AVFoundation
import ScreenCaptureKit

struct Failure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

struct Options {
    var command = ""
    var app: String?
    var pid: Int32?
    var title: String?
    var windowID: UInt32?
    var out: URL?
    var shadow = true
    var seconds: Double = 60
    var until: URL?
    var fps: Int32 = 30
    var allLayers = false

    init(_ arguments: [String]) throws {
        // `open` starts apps in /, so relative paths are taken from where the script was run.
        let base = ProcessInfo.processInfo.environment["WINDOW_CAPTURE_CWD"] ?? FileManager.default.currentDirectoryPath
        func url(_ path: String) -> URL { URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: base, isDirectory: true)) }
        var rest = arguments[...]
        command = rest.popFirst() ?? ""
        while let flag = rest.popFirst() {
            func value() throws -> String {
                guard let value = rest.popFirst() else { throw Failure("\(flag) needs a value") }
                return value
            }
            switch flag {
            case "--app": app = try value()
            case "--pid": pid = Int32(try value())
            case "--title": title = try value()
            case "--window": windowID = UInt32(try value())
            case "--out": out = url(try value())
            case "--no-shadow": shadow = false
            case "--seconds": seconds = Double(try value()) ?? seconds
            case "--until": until = url(try value())
            case "--fps": fps = Int32(try value()) ?? fps
            case "--all": allLayers = true
            default: throw Failure("unknown option \(flag)")
            }
        }
    }

    func matches(_ window: SCWindow) -> Bool {
        let owner = window.owningApplication
        if let app, owner?.bundleIdentifier != app, owner?.applicationName != app { return false }
        if let pid, owner?.processID != pid { return false }
        if let title, !(window.title ?? "").localizedCaseInsensitiveContains(title) { return false }
        if let windowID, window.windowID != windowID { return false }
        return true
    }
}

/// Apps' windows: on screen, from the normal layer up to floating and utility windows (SwiftUI's
/// floating level is 19; the Dock is 20 and the menu bar above), and more than a sliver. With
/// `allLayers`, every layer, for a popover or menu.
func windows(allLayers: Bool = false) async throws -> [SCWindow] {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    return content.windows.filter {
        (allLayers || (0...19).contains($0.windowLayer)) && $0.frame.width >= 60 && $0.frame.height >= 60
    }
}

func window(for options: Options) async throws -> SCWindow {
    guard options.app != nil || options.pid != nil || options.title != nil || options.windowID != nil else {
        throw Failure("say which window: --app, --pid, --title or --window (see `list`)")
    }
    let candidates = try await windows(allLayers: options.allLayers || options.windowID != nil).filter(options.matches)
    guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
        throw Failure("no window on screen matches; `list` shows them")
    }
    return window
}

/// Captures at the display's full resolution, with transparency round the window's corners.
func configuration(for filter: SCContentFilter, shadow: Bool) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    configuration.width = Int(filter.contentRect.width * scale)
    configuration.height = Int(filter.contentRect.height * scale)
    configuration.ignoreShadowsSingleWindow = !shadow
    configuration.shouldBeOpaque = false
    configuration.showsCursor = false
    configuration.captureResolution = .best
    configuration.preservesAspectRatio = true
    return configuration
}

func describe(_ window: SCWindow) -> String {
    let owner = window.owningApplication
    return "\(window.windowID)\t\(owner?.bundleIdentifier ?? "-")\t\(owner?.processID ?? 0)\t"
        + "\(Int(window.frame.width))x\(Int(window.frame.height))\t\(window.title ?? "")"
}

/// An image's alpha channel, row by row from the top.
func alpha(of image: CGImage) -> (values: [UInt8], width: Int, height: Int) {
    let width = image.width, height = image.height
    var values = [UInt8](repeating: 0, count: width * height)
    values.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (values, width, height)
}

/// The smallest rectangle holding every pixel whose alpha is above `threshold`.
func bounds(of image: CGImage, above threshold: UInt8) -> CGRect? {
    let (values, width, height) = alpha(of: image)
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where values[y * width + x] > threshold {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

func shot(_ options: Options) async throws {
    guard let out = options.out else { throw Failure("shot needs --out <file.png>") }
    let window = try await window(for: options)
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = configuration(for: filter, shadow: options.shadow)
    var image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    if options.shadow, let body = bounds(of: image, above: 250), body.width < CGFloat(configuration.width) - 1 {
        // The shadow was squeezed into the window's size, shrinking the window with it. Capture
        // again with room enough for the window at full size, then trim what the shadow leaves.
        let shrink = body.width / CGFloat(configuration.width)
        configuration.width = Int((CGFloat(configuration.width) / shrink).rounded(.up))
        configuration.height = Int((CGFloat(configuration.height) / shrink).rounded(.up))
        image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        if let used = bounds(of: image, above: 0), let trimmed = image.cropping(to: used) { image = trimmed }
    }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure("could not encode the PNG") }
    try png.write(to: out)
    print("wrote \(out.path) (\(image.width)x\(image.height)) from \(describe(window))")
}

final class RecordingDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _finished = false
    private var _error: Error?
    var finished: Bool { lock.withLock { _finished } }
    var error: Error? { lock.withLock { _error } }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { lock.withLock { _finished = true } }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        lock.withLock { _error = error; _finished = true }
    }
}

func record(_ options: Options) async throws {
    guard let out = options.out else { throw Failure("record needs --out <file.mov>") }
    let window = try await window(for: options)
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = configuration(for: filter, shadow: options.shadow)
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: options.fps)
    let output = SCRecordingOutputConfiguration()
    try? FileManager.default.removeItem(at: out)
    output.outputURL = out
    output.outputFileType = .mov
    output.videoCodecType = .h264
    let delegate = RecordingDelegate()
    let recording = SCRecordingOutput(configuration: output, delegate: delegate)
    let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
    try stream.addRecordingOutput(recording)
    try await stream.startCapture()
    print("recording \(describe(window))")
    let deadline = Date().addingTimeInterval(options.seconds)
    while Date() < deadline {
        if let until = options.until, FileManager.default.fileExists(atPath: until.path) { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    // A recording keeps the size it started with, so a window that grows is squeezed into it.
    if let now = try await windows().first(where: { $0.windowID == window.windowID }), now.frame.size != window.frame.size {
        FileHandle.standardError.write(Data(("warning: the window went from \(Int(window.frame.width))x\(Int(window.frame.height)) to "
            + "\(Int(now.frame.width))x\(Int(now.frame.height)) while recording, so the video is distorted\n").utf8))
    }
    try await stream.stopCapture()
    // The file is finished a moment after the stream stops.
    for _ in 0..<100 where !delegate.finished { try await Task.sleep(for: .milliseconds(100)) }
    if let error = delegate.error { throw error }
    print("wrote \(out.path) (\(String(format: "%.1f", recording.recordedDuration.seconds))s)")
}

func run() async throws {
    let options = try Options(Array(CommandLine.arguments.dropFirst()))
    switch options.command {
    case "list":
        for window in try await windows(allLayers: options.allLayers) {
            print(describe(window) + (options.allLayers ? "\tlayer \(window.windowLayer)" : ""))
        }
    case "shot": try await shot(options)
    case "record": try await record(options)
    default: throw Failure("usage: list [--all] | shot <window> --out <file.png> | record <window> --out <file.mov>")
    }
}

// Connects to the window server, which capturing and drawing images need; no Dock icon or menu.
NSApplication.shared.setActivationPolicy(.prohibited)

Task {
    do {
        try await run()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}
// The main thread runs the app's run loop: ScreenCaptureKit puts its recording indicator in the
// menu bar from the main queue while a recording runs.
NSApplication.shared.run()
