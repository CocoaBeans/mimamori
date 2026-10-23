import AppKit
import Foundation
import VigilCore

/// Developer-only hooks driven by environment variables; inert otherwise.
///
///     VIGIL_SCREENSHOT=/path/file.png        write the main window as a PNG after launch
///     VIGIL_SCREENSHOT_INTERVAL=seconds      and keep rewriting it (also paces the dump)
///     VIGIL_DEBUG_DUMP=/path/file.txt        write a text summary of the model state
///     VIGIL_DEBUG_SELECT=relative/path       select this file in the selected worktree once it appears
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

        Task { @MainActor [weak model] in
            try? await Task.sleep(for: .seconds(5))
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
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
