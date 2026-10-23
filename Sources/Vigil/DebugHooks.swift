import AppKit
import Foundation
import VigilCore

/// Developer-only hooks driven by environment variables; inert otherwise.
///
///     VIGIL_SCREENSHOT=/path/file.png        write the main window as a PNG after launch
///     VIGIL_SCREENSHOT_INTERVAL=seconds      and keep rewriting it (also paces the dump)
///     VIGIL_DEBUG_DUMP=/path/file.txt        write a text summary of the model state
///     VIGIL_DEBUG_SELECT=relative/path       select this file in the selected worktree once it appears
///     VIGIL_WINDOW=1000x640                  resize the main window after launch
///
/// Useful for driving the app headlessly from scripts without screen-recording
/// or accessibility permissions.
@MainActor
enum DebugHooks {
    static func start(model: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? {
            guard let raw = environment[key], !raw.isEmpty else { return nil }
            return raw
        }
        let screenshot = value("VIGIL_SCREENSHOT")
        let dump = value("VIGIL_DEBUG_DUMP")
        let select = value("VIGIL_DEBUG_SELECT")
        guard screenshot != nil || dump != nil || select != nil else { return }
        let interval = Double(value("VIGIL_SCREENSHOT_INTERVAL") ?? "") ?? 0

        let windowSize = value("VIGIL_WINDOW")
        Task { @MainActor [weak model] in
            try? await Task.sleep(for: .seconds(1.5))
            if let windowSize {
                let parts = windowSize.lowercased().split(separator: "x").compactMap { Double($0) }
                if parts.count == 2, let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && $0.isVisible }) {
                    window.setContentSize(NSSize(width: parts[0], height: parts[1]))
                    window.center()
                }
            }
            try? await Task.sleep(for: .seconds(3.5))
            repeat {
                guard let model else { return }
                if let select, let session = model.selectedSession,
                   session.change(for: select) != nil, session.selectedPath != select {
                    session.selectedPath = select
                }
                if let dump { writeDump(model: model, to: dump) }
                if let screenshot { writeMainWindowImage(to: screenshot) }
                if interval <= 0 { break }
                try? await Task.sleep(for: .seconds(interval))
            } while !Task.isCancelled
        }
    }

    static func writeDump(model: AppModel, to path: String) {
        var lines: [String] = []
        lines.append("time: \(Format.dateTime.string(from: Date()))")
        lines.append("git: \(model.gitVersion ?? "none") error=\(model.gitError ?? "-")")
        lines.append("selected: \(model.selectedWorktreeID ?? "-") showActivity=\(model.showActivity) sort=\(model.sortOrder.rawValue) flaggedOnly=\(model.flaggedOnly)")
        for repo in model.repositories {
            lines.append("repo \(repo.displayName) [\(repo.rootPath)] error=\(repo.error ?? "-")")
            for worktree in repo.worktrees {
                let session = model.sessions[worktree.path]
                let phase = session.map { String(describing: $0.phase) } ?? "none"
                let duration = session?.lastRefreshDuration.map { String(format: "%.3fs", $0) } ?? "-"
                lines.append("  worktree \(worktree.name) branch=\(worktree.branch ?? "-") main=\(worktree.isMain) phase=\(phase) changes=\(session?.changes.count ?? -1) flagged=\(session?.flaggedCount ?? -1) baseline=\"\(session?.state?.baseline.label ?? "-")\" watcher=\(session?.watcherActive ?? false) snapshots=\(session?.snapshots.count ?? 0) start=\(session?.startSnapshot != nil) selected=\(session?.selectedPath ?? "-") lastRefresh=\(duration) error=\(session?.lastError ?? "-")")
                for change in session?.changes ?? [] {
                    let flags = change.flags.map { "\($0.rule.rawValue):\($0.message)" }.joined(separator: "; ")
                    lines.append("    \(change.kind.glyph) \(change.path) +\(change.additions.map(String.init) ?? "-") -\(change.deletions.map(String.init) ?? "-") untracked=\(change.isUntracked) flags=[\(flags)]")
                }
            }
        }
        lines.append("activity (\(model.activity.count)):")
        for entry in model.activity.prefix(40) {
            lines.append("  \(Format.time.string(from: entry.date)) \(entry.kind.rawValue) \(entry.title) \(entry.detail ?? "")")
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func writeMainWindowImage(to path: String) {
        let candidates = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) && $0.contentView != nil }
        guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let view = window.contentView?.superview ?? window.contentView else { return }

        // Materials and Liquid Glass are composited by the window server and come out blank
        // in a cached display. Flatten them to plain backgrounds for the capture, then restore.
        var restorers: [() -> Void] = []
        func neutralize(_ view: NSView) {
            let className = NSStringFromClass(type(of: view))
            if let effect = view as? NSVisualEffectView {
                let material = effect.material
                let state = effect.state
                let blending = effect.blendingMode
                effect.material = .windowBackground
                effect.state = .inactive
                effect.blendingMode = .withinWindow
                restorers.append { effect.material = material; effect.state = state; effect.blendingMode = blending }
            } else if Self.isEffectOnlyView(className) {
                let wasHidden = view.isHidden
                view.isHidden = true
                restorers.append { view.isHidden = wasHidden }
            }
            for subview in view.subviews { neutralize(subview) }
        }
        neutralize(view)
        defer { for restore in restorers.reversed() { restore() } }

        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        // Popovers and panels are separate windows; save each visible one as well.
        var extra = 0
        for other in NSApp.windows where other !== window && other.isVisible && other.contentView != nil
            && other.frame.width > 40 && other.frame.height > 40 && !other.styleMask.contains(.titled) {
            guard let otherView = other.contentView?.superview ?? other.contentView,
                  let otherRep = otherView.bitmapImageRepForCachingDisplay(in: otherView.bounds) else { continue }
            otherView.cacheDisplay(in: otherView.bounds, to: otherRep)
            if let otherData = otherRep.representation(using: .png, properties: [:]) {
                extra += 1
                try? otherData.write(to: URL(fileURLWithPath: path + ".extra\(extra).png"), options: .atomic)
            }
        }

        // Also dump the class names of what sits in the window, for diagnosing blank regions.
        var names: [String] = ["window frame=\(window.frame.integral) contentMinSize=\(window.contentMinSize) minSize=\(window.minSize)"]
        func collect(_ view: NSView, depth: Int) {
            guard depth < 16 else { return }
            var line = String(repeating: "  ", count: depth) + NSStringFromClass(type(of: view)) + " \(view.frame.integral)"
            if let scroll = view as? NSScrollView {
                line += " insets=\(scroll.contentInsets) visible=\(scroll.documentVisibleRect.integral) safe=\(scroll.safeAreaInsets)"
            }
            let name = NSStringFromClass(type(of: view))
            if name.contains("SplitView") || name.contains("HostingView") || name.contains("PlatformViewHost") {
                let fitting = view.fittingSize
                let intrinsic = view.intrinsicContentSize
                line += " fitting=(\(Int(fitting.width))x\(Int(fitting.height))) intrinsic=(\(Int(intrinsic.width))x\(Int(intrinsic.height)))"
            }
            names.append(line)
            for subview in view.subviews { collect(subview, depth: depth + 1) }
        }
        collect(view, depth: 0)
        try? names.joined(separator: "\n").write(toFile: path + ".views.txt", atomically: true, encoding: .utf8)
    }

    /// Views that only paint an effect (glass backdrops, scroll-edge pockets) and hold no content.
    private static func isEffectOnlyView(_ className: String) -> Bool {
        if className.contains("Glass") && className.contains("RootView") { return true }
        for marker in ["BackdropView", "PortalView", "PocketBlur", "LuminanceAdjustment", "DimmingView", "PocketMask"]
        where className.contains(marker) { return true }
        return false
    }

    /// Renders the layer tree instead of asking views to draw; backdrop layers come out empty
    /// rather than opaque, which keeps content under materials visible.
    static func writeLayerImage(of view: NSView, scale: CGFloat, to path: String) {
        guard let layer = view.layer else { return }
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.setFillColor(NSColor.windowBackgroundColor.cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
        if layer.isGeometryFlipped == false, view.isFlipped == false {
            // AppKit layer trees are rendered bottom-up into a flipped NSGraphicsContext.
        }
        layer.render(in: cg)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
