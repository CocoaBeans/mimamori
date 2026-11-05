// Debug builds only: release builds leave every debug hook out (see the README's Debug hooks).
#if DEBUG
import AppKit
import Foundation
import SwiftUI
import MimamoriCore
import WidgetKit

/// Developer-only hooks driven by environment variables; inert otherwise.
///
///     MIMAMORI_SCREENSHOT=/path/file.png        write the main window as a PNG after launch
///     MIMAMORI_SCREENSHOT_INTERVAL=seconds      and keep rewriting it (also paces the dump)
///     MIMAMORI_DEBUG_DUMP=/path/file.txt        write a text summary of the model state
///     MIMAMORI_DEBUG_SELECT=relative/path       select this file in the selected worktree once it appears
///     MIMAMORI_DEBUG_REVIEW=path,path           mark these files in the selected worktree reviewed once they appear
///     MIMAMORI_WINDOW=1000x640                  resize the main window after launch
///     MIMAMORI_SUPPORT_DIR=/path                keep state, shadow indexes and the socket here instead
///     MIMAMORI_SCREENSHOT_WINDOW=Agents         capture the window with this title instead of the largest
///     MIMAMORI_QUIET_AFTER=5                    call a working agent quiet after 5 s without a tool call, not 3 min
///     MIMAMORI_DEBUG_FLAGS=summary              open the session summary (and write it to <dump>.summary.md)
///     MIMAMORI_DEBUG_FLAGS=open-runs            open every agent run in the activity feed
///     MIMAMORI_DEBUG_FLAGS=menu-bar             open the menu-bar popover (captured as <screenshot>.extra1.png)
///     MIMAMORI_DEBUG_FLAGS=status-pill          open the toolbar's agent status popover
///     MIMAMORI_DEBUG_FLAGS=sidebar              render the sidebar rows with agents or changes, light and dark
///     MIMAMORI_DEBUG_FLAGS=diff-line:120        scroll the selected file's diff to new-file line 120
///     MIMAMORI_DEBUG_FLAGS=note-line:12-14      start a note on new-file lines 12 to 14 of the selected file
///     MIMAMORI_DEBUG_FLAGS=discard:2            ask to discard hunk 2 of the selected file (discard:file: the whole
///                                               file; add :confirm to go ahead 2 s later); discard-undo presses Undo once
///     MIMAMORI_DEBUG_FLAGS=about                open the About window
///     MIMAMORI_DEBUG_FLAGS=permission:allow     answer a permission request once it has waited 5 s (or permission:deny)
///     MIMAMORI_DEBUG_FLAGS=hook-test            send a test event through the hook command once (result in the dump,
///                                               Copy Diagnostics' report in <dump>.diagnostics.txt)
///     MIMAMORI_DEBUG_FLAGS=sidebar:show         unfold the main window's sidebar at its usual width
///     MIMAMORI_DEBUG_FLAGS=welcome              open the welcome window (uninstall: the Uninstall window)
///     MIMAMORI_DEBUG_FLAGS=help:agents          open the Help window on that topic (help alone: the first)
///     MIMAMORI_DEBUG_FLAGS=appearance:light     draw every window light (appearance:dark: dark), whatever the system's setting
///     MIMAMORI_DEBUG_FLAGS=resize:1000/600/1000 drag the window's width through these sizes, holding at each (the window
///                                               MIMAMORI_SCREENSHOT_WINDOW names; captures as <screenshot>.resize-<n><a|b>.png)
///     MIMAMORI_DEBUG_FLAGS=uninstall:run        run Uninstall's default choices, app kept out of the Trash
///                                               (report in <dump>.uninstall.txt; use a scratch setup)
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
        let screenshot = value("MIMAMORI_SCREENSHOT")
        let dump = value("MIMAMORI_DEBUG_DUMP")
        let select = value("MIMAMORI_DEBUG_SELECT")
        var toReview = Set((value("MIMAMORI_DEBUG_REVIEW") ?? "").split(separator: ",").map(String.init))
        // "appearance:light" or "appearance:dark": draw every window that way, whatever the system's setting.
        if model.debugFlags.contains("appearance:light") { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
        if model.debugFlags.contains("appearance:dark") { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
        if let flag = model.debugFlags.first(where: { $0.hasPrefix("resize:") }) {
            let widths = flag.dropFirst("resize:".count).split(separator: "/").compactMap { Double($0) }
            let title = value("MIMAMORI_SCREENSHOT_WINDOW")
            Task { await dragWindow(through: widths, titled: title, capturingTo: screenshot) }
        }
        guard screenshot != nil || dump != nil || select != nil || !toReview.isEmpty else { return }
        let interval = Double(value("MIMAMORI_SCREENSHOT_INTERVAL") ?? "") ?? 0

        let windowSize = value("MIMAMORI_WINDOW")
        let windowTitle = value("MIMAMORI_SCREENSHOT_WINDOW")
        var toggledReview = false
        var openedSummary = false
        var ranHookTest = false
        var openedAbout = false
        var renderedWidgets = false
        var openedCommit = false
        var openedMenuBar = false
        var ranUninstall = false
        var shownSidebar = false
        var renderedPillPopover = false
        Task { @MainActor [weak model] in
            try? await Task.sleep(for: .seconds(1.5))
            let resized = windowSize.map { resizeWindow(to: $0, titled: windowTitle) } ?? true
            try? await Task.sleep(for: .seconds(1.5))
            // Settings opens a moment after the main window.
            if !resized, let windowSize { _ = resizeWindow(to: windowSize, titled: windowTitle) }
            try? await Task.sleep(for: .seconds(2))
            repeat {
                guard let model else { return }
                if let select, let session = model.selectedSession,
                   session.change(for: select) != nil, session.selectedPath != select {
                    session.selectedPath = select
                }
                if let session = model.selectedSession {
                    let ready = toReview.filter { session.change(for: $0) != nil }
                    if !ready.isEmpty {
                        session.setReviewed(true, paths: Array(ready))
                        toReview.subtract(ready)
                    }
                }
                // "widgets": render every widget size, light and dark, next to the dump.
                if model.debugFlags.contains("widgets"), !renderedWidgets, let dump {
                    renderedWidgets = true
                    writeWidgetPreviews(agents: model.widgetAgents(), to: dump)
                }
                if model.debugFlags.contains("about"), !openedAbout {
                    openedAbout = true
                    BuildInfo.showAboutPanel()
                }
                // "permission:allow" / "permission:deny": answer a waiting request, as its buttons do.
                for answer in ["allow", "deny"] where model.debugFlags.contains("permission:" + answer) {
                    for pending in model.agentHub.pendingPermissions.values where Date().timeIntervalSince(pending.since) > 5 {
                        model.agentHub.answerPermission(pending.id, allow: answer == "allow")
                    }
                }
                // "hook-test": what Settings › Agents › Send Test Event does, once.
                if model.debugFlags.contains("hook-test"), !ranHookTest, model.agentHub.isListening {
                    ranHookTest = true
                    Task { hookTestResult = "\(await model.agentHub.sendTestEvent())" }
                }
                // "summary": open the session summary for the selected worktree once.
                if model.debugFlags.contains("summary"), !openedSummary, let session = model.selectedSession, session.state != nil {
                    model.summaryWindowRequest = session.id
                    openedSummary = true
                    if let dump {
                        let summary = await model.sessionSummary(for: session, includeDiffs: model.settings.summaryOptions.diffs)
                        try? summary.markdown(options: model.settings.summaryOptions)
                            .write(toFile: dump + ".summary.md", atomically: true, encoding: .utf8)
                    }
                }
                // "toggle-review": press ⌘↩ once on the selected file, after the marks above.
                if model.debugFlags.contains("toggle-review"), !toggledReview, let session = model.selectedSession,
                   let selected = session.selectedPath, session.change(for: selected) != nil {
                    model.toggleReviewForSelection()
                    toggledReview = true
                }
                // "commits": show the Commits list, open its newest commit and then its first file;
                // "commits:<id>": open that commit the way the activity feed does.
                if let flag = model.debugFlags.first(where: { $0 == "commits" || $0.hasPrefix("commits:") }),
                   let session = model.selectedSession, session.state != nil {
                    if !openedCommit {
                        openedCommit = true
                        if flag.hasPrefix("commits:") {
                            model.showCommit(String(flag.dropFirst("commits:".count)), in: session.id)
                        } else {
                            model.showCommits = true
                        }
                    } else if !flag.hasPrefix("commits:"), session.commitSelection == nil, let newest = session.history?.all.first {
                        session.select(.commit(newest.oid))
                    } else if !flag.hasPrefix("commits:"), case .commit(let oid)? = session.commitSelection,
                              let first = session.openCommitChanges.first {
                        session.select(.file(commit: oid, path: first.path))
                    }
                }
                if model.debugFlags.contains("sidebar"), let dump {
                    // The sidebar's vibrant material loses its colours in the live capture.
                    let rows = model.repositories.flatMap(\.worktrees).filter { worktree in
                        model.agentHub.presence(for: worktree.path) != nil || !(model.sessions[worktree.path]?.changes.isEmpty ?? true)
                    }
                    let view = VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.repositoryOffers) { RepositoryOfferRow(offer: $0) }
                        ForEach(model.repositories) { repo in
                            RepositoryHeader(repo: repo, hidden: 0, collapsed: false, sessions: [])
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                            ForEach(rows.filter { row in repo.worktrees.contains(row) }, id: \.path) { worktree in
                                WorktreeRow(info: worktree, session: model.sessions[worktree.path], now: model.now,
                                            recencyWindow: model.settings.recencyWindowSeconds,
                                            presence: model.agentHub.presence(for: worktree.path))
                            }
                        }
                    }
                    .padding(10)
                    .frame(width: 240)
                    writePreviews(of: view, named: "sidebar", model: model, to: dump)
                }
                if model.debugFlags.contains("status-pill"), !renderedPillPopover, !model.agentRows.isEmpty, let dump {
                    // The live popover loses its vibrant colours too.
                    renderedPillPopover = true
                    writePreviews(of: AgentStatusPopover(onDone: {}), named: "status-pill", model: model, to: dump)
                }
                if model.debugFlags.contains("menu-bar"), !openedMenuBar {
                    openedMenuBar = clickStatusItem()
                    // The live capture loses the popover's vibrant colours; render it as well.
                    if let dump { writeMenuBarPreviews(model: model, to: dump) }
                }
                // "uninstall:run": what Uninstall does, with the default choices but keeping the app
                // out of the Trash; its report goes next to the dump.
                if model.debugFlags.contains("uninstall:run"), !ranUninstall, model.agentHub.isListening, let dump {
                    ranUninstall = true
                    let leftovers = await Uninstaller.find(model: model)
                    var plan = UninstallPlan()
                    plan.trashApp = false
                    let report = await Uninstaller.run(plan, leftovers: leftovers, model: model)
                    try? report.joined(separator: "\n").write(toFile: dump + ".uninstall.txt", atomically: true, encoding: .utf8)
                }
                // "sidebar:show": unfold the main window's sidebar; the window remembers it folded
                // across launches, and README captures want it.
                if model.debugFlags.contains("sidebar:show"), !shownSidebar {
                    shownSidebar = showSidebar()
                }
                if model.debugFlags.contains("cycle") {
                    let ids = model.orderedSessions.map(\.id)
                    if !ids.isEmpty {
                        let index = model.selectedWorktreeID.flatMap { ids.firstIndex(of: $0) } ?? -1
                        model.select(worktree: ids[(index + 1) % ids.count])
                    }
                }
                if let dump { writeDump(model: model, to: dump) }
                if let screenshot { writeMainWindowImage(to: screenshot, title: windowTitle) }
                if interval <= 0 { break }
                try? await Task.sleep(for: .seconds(interval))
            } while !Task.isCancelled
        }
    }

    /// Clicks Mimamori's menu-bar item, as if from the menu bar; false when it is not there yet.
    private static func clickStatusItem() -> Bool {
        func button(in view: NSView?) -> NSStatusBarButton? {
            guard let view else { return nil }
            if let button = view as? NSStatusBarButton { return button }
            return view.subviews.lazy.compactMap { button(in: $0) }.first
        }
        guard let item = NSApp.windows.lazy.compactMap({ button(in: $0.contentView) }).first else { return false }
        item.performClick(nil)
        return true
    }

    /// Resizes the window titled `title` (or the first one) to `size` ("1000x640"); false when it is not open yet.
    private static func resizeWindow(to size: String, titled title: String?) -> Bool {
        let parts = size.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, let window = NSApp.windows.first(where: {
            $0.styleMask.contains(.titled) && $0.isVisible && (title == nil || $0.title == title)
        }) else { return false }
        window.setContentSize(NSSize(width: parts[0], height: parts[1]))
        window.center()
        return true
    }

    /// Drags the window's right edge through `widths` (content widths, in points) a frame at a time,
    /// as a person resizing it would, keeping its height, and holds at each width. With a screenshot
    /// path, captures the window just after each drag (`<path>.resize-<n>a.png`) and once it has
    /// settled (`<path>.resize-<n>b.png`).
    private static func dragWindow(through widths: [Double], titled title: String?, capturingTo path: String?) async {
        // After launch and MIMAMORI_WINDOW's resize, once the window has its rows.
        try? await Task.sleep(for: .seconds(8))
        guard let window = NSApp.windows.first(where: {
            $0.styleMask.contains(.titled) && $0.isVisible && (title == nil || $0.title == title)
        }) else { return }
        for (index, width) in widths.enumerated() {
            let start = window.contentRect(forFrameRect: window.frame).size
            // Half a second at 60 frames a second.
            for step in 1...30 {
                let fraction = Double(step) / 30
                window.setContentSize(NSSize(width: start.width + (width - start.width) * fraction, height: start.height))
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard let path else {
                try? await Task.sleep(for: .seconds(1.5))
                continue
            }
            try? await Task.sleep(for: .milliseconds(20))
            writeMainWindowImage(to: "\(path).resize-\(index + 1)a.png", title: title)
            try? await Task.sleep(for: .seconds(1.5))
            writeMainWindowImage(to: "\(path).resize-\(index + 1)b.png", title: title)
        }
    }

    /// Unfolds the main window's sidebar if it is folded. False until the window is there.
    private static func showSidebar() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }),
              let content = window.contentView else { return false }
        func splitViews(in view: NSView) -> [NSSplitView] {
            var found = view.subviews.flatMap(splitViews)
            if let split = view as? NSSplitView { found.insert(split, at: 0) }
            return found
        }
        for split in splitViews(in: content) {
            guard let controller = split.delegate as? NSSplitViewController,
                  let sidebar = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) else { continue }
            if sidebar.isCollapsed { sidebar.isCollapsed = false }
            // Unfolded, it may come back at its narrowest; give it its usual width.
            split.setPosition(250, ofDividerAt: 0)
            return true
        }
        return false
    }

    /// The widget sizes on a Mac's desktop, in points.
    private static let widgetSizes: [(name: String, family: WidgetFamily, size: CGSize)] = [
        ("small", .systemSmall, CGSize(width: 170, height: 170)),
        ("medium", .systemMedium, CGSize(width: 364, height: 170)),
        ("large", .systemLarge, CGSize(width: 364, height: 382)),
        ("extralarge", .systemExtraLarge, CGSize(width: 704, height: 344)),
    ]

    /// Draws the Agents widget in every size, light and dark, as `<path>.widget-<size>-<scheme>.png`.
    /// Uses the app's agents, or the gallery's sample ones when none are running.
    private static func writeWidgetPreviews(agents: [AgentWidgetSnapshot.Agent], to path: String) {
        let snapshot = AgentWidgetSnapshot(agents: agents.isEmpty ? AgentWidgetSnapshot.sample.agents : agents)
        for size in widgetSizes {
            for scheme in [ColorScheme.light, .dark] {
                // Outside WidgetKit there is no container background; draw a plain one instead.
                let view = AgentsWidgetView(snapshot: snapshot, family: size.family)
                    .padding(16)
                    .frame(width: size.size.width, height: size.size.height)
                    .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.95), in: RoundedRectangle(cornerRadius: 22))
                    .environment(\.colorScheme, scheme)
                    .environment(\.isRenderingWidgetPreview, true)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
                try? png.write(to: URL(fileURLWithPath: "\(path).widget-\(size.name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    /// The menu-bar popover in light and dark, next to the dump.
    private static func writeMenuBarPreviews(model: AppModel, to path: String) {
        writePreviews(of: MenuBarPanel(), named: "menubar", model: model, to: path)
    }

    /// `view` in light and dark, as `<path>.<name>-light.png` and `-dark.png`.
    private static func writePreviews(of content: some View, named name: String, model: AppModel, to path: String) {
        for scheme in [ColorScheme.light, .dark] {
            let view = content
                .environment(model)
                .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.95))
                .environment(\.colorScheme, scheme)
                .environment(\.isRenderingWidgetPreview, true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: "\(path).\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    /// The result of the "hook-test" flag's test, once it has run.
    private static var hookTestResult: String?

    static func writeDump(model: AppModel, to path: String) {
        var lines: [String] = []
        lines.append("time: \(Format.dateTime.string(from: Date()))")
        lines.append("git: \(model.gitVersion ?? "none") error=\(model.gitError ?? "-")")
        lines.append("selected: \(model.selectedWorktreeID ?? "-") showActivity=\(model.showActivity) sort=\(model.sortOrder.rawValue) flaggedOnly=\(model.flaggedOnly)")
        lines.append("settings updates: requested=\(model.settingsUpdateRequests) applied=\(model.settingsUpdatesApplied) hideReviewed=\(model.hideReviewed)")
        lines.append("state notice: \(model.stateNotice.map { "\($0.message) [\($0.file.lastPathComponent)]" } ?? "-")")
        for window in NSApp.windows {
            lines.append("window \(type(of: window)) \"\(window.title)\" number=\(window.windowNumber) visible=\(window.isVisible) key=\(window.isKeyWindow) frame=\(window.frame)")
        }
        for repo in model.repositories {
            lines.append("repo \(repo.displayName) [\(repo.rootPath)] error=\(repo.error ?? "-")")
            for worktree in repo.worktrees {
                let session = model.sessions[worktree.path]
                let phase = session.map { String(describing: $0.phase) } ?? "none"
                let duration = session?.lastRefreshDuration.map { String(format: "%.3fs", $0) } ?? "-"
                lines.append("  worktree \(worktree.name) branch=\(worktree.branch ?? "-") main=\(worktree.isMain) phase=\(phase) changes=\(session?.changes.count ?? -1) flagged=\(session?.flaggedCount ?? -1) baseline=\"\(session?.state?.baseline.label ?? "-")\" watcher=\(session?.watcherActive ?? false) snapshots=\(session?.snapshots.count ?? 0) start=\(session?.startSnapshot != nil) selected=\(session?.selectedPath ?? "-") reviewed=\(session?.reviewedCount ?? 0) lastRefresh=\(duration) error=\(session?.lastError ?? "-")")
                for change in session?.changes ?? [] {
                    let flags = change.flags.map { "\($0.rule.rawValue):\($0.message)" }.joined(separator: "; ")
                    let review: String
                    switch session?.reviewStatus(of: change) ?? .unreviewed {
                    case .unreviewed: review = "-"
                    case .reviewed: review = "reviewed"
                    case .changedSinceReview: review = "changed-since-review"
                    }
                    lines.append("    \(change.kind.glyph) \(change.path) +\(change.additions.map(String.init) ?? "-") -\(change.deletions.map(String.init) ?? "-") untracked=\(change.isUntracked) review=\(review) flags=[\(flags)]")
                }
            }
        }
        let hub = model.agentHub
        lines.append("agents: socket=\(hub.isListening ? "listening" : "down") path=\(hub.socketPath) error=\(hub.socketError ?? "-") events=\(hub.eventsReceived) unmatched=\(hub.eventsUnmatched) hooksInstalled=\(HookInstaller.isInstalled()) hubSeesHooks=\(hub.claudeHooksInstalled)")
        for pending in hub.pendingPermissions.values {
            let plan = pending.autoAnswer.map { "\($0.allow ? "allow" : "deny") in \(Int($0.at.timeIntervalSinceNow.rounded()))s" } ?? "waits"
            lines.append("  permission pending: \(pending.agent.id) \(pending.tool) \(pending.detail ?? "-") in \((pending.worktree as NSString).lastPathComponent) auto=\(plan) askRule=\(pending.waitsForAskRule ?? "-")")
        }
        lines.append("repositories: \(model.repositories.map(\.rootPath)) offers: \(model.repositoryOffers.map(\.root)) policy: \(model.settings.agentRepositoryPolicy.rawValue)")
        lines.append("windows: " + NSApp.windows.map { "\($0.title.isEmpty ? "-" : $0.title)[\($0.isVisible ? "shown" : "hidden"), level \($0.level.rawValue), \($0.identifier?.rawValue ?? "-")]" }.joined(separator: ", "))
        if let hookTestResult { lines.append("hook test: \(hookTestResult)") }
        if model.debugFlags.contains("hook-test") {
            try? model.diagnostics().text().write(toFile: path + ".diagnostics.txt", atomically: true, encoding: .utf8)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for entry in hub.hookLog.prefix(12) { lines.append("  hook log: \(entry.title) | \(entry.detail(home: home))") }
        for contact in hub.contacts.values.sorted(by: { $0.agent.id < $1.agent.id }) {
            lines.append("  heard \(contact.agent.id) (\(contact.agent.displayName)): events=\(contact.events) last=\(contact.lastEvent) worktree=\(contact.lastWorktree.map { ($0 as NSString).lastPathComponent } ?? "-")")
        }
        for row in model.agentRows {
            let app = AgentApps.app(for: row.presence)?.localizedName ?? "-"
            let steps = row.presence.turnSteps.map { step in
                let state = step.finishedAt == nil ? (step.id == row.presence.awaitingCallID ? "needs-you" : "running") : (step.failed ? "failed" : "done")
                return "\(step.toolName):\(state)"
            }
            let note = row.presence.source == .process ? " hooksInstalled=\(row.presence.hooksInstalled.map(String.init) ?? "-")" : ""
            lines.append("  row \((row.session.id as NSString).lastPathComponent): agent=\(row.presence.kind.displayName) status=\"\(row.presence.statusText)\"\(note) others=\(row.presence.others.map { "\($0.kind.id):\($0.statusText)" }) collision=\(row.presence.collision.map { "\($0.agents): \($0.files.map { ($0 as NSString).lastPathComponent })" } ?? "-") attention=\(row.presence.needsAttention) task=\"\(row.presence.task ?? "-")\" steps=\(steps) files=\(row.files.map(\.path)) goToAgent=\(app)")
        }
        if let session = model.selectedSession {
            let history = session.history
            lines.append("commits: shown=\(model.showCommits) reference=\(history?.reference ?? "-") since=\(history?.sinceBranchPoint.map(\.subject) ?? []) earlier=\(history?.earlier.count ?? 0) more=\(history?.hasMore ?? false) error=\(session.historyError ?? "-")")
            let selection = session.commitSelection.map { selection -> String in
                switch selection {
                case .commit(let oid): "commit \(oid.prefix(7))"
                case .file(let oid, let path): "file \(oid.prefix(7)) \(path)"
                }
            } ?? "-"
            let files = session.shownCommitChanges.prefix(5).map { "\($0.kind.glyph) \($0.path) +\($0.additions ?? 0) -\($0.deletions ?? 0) flags=\($0.flags.map(\.rule.rawValue))" }
            lines.append("  open: \(session.openCommit.map { "\($0.shortOID) \($0.subject)" } ?? "-") selection=\(selection) files=\(session.openCommitChanges.count) shown=\(session.shownCommitChanges.count) hidden=\(session.hiddenCommitChangeCount) first=\(files)")
        }
        for (worktree, list) in hub.processes.sorted(by: { $0.key < $1.key }) where !list.isEmpty {
            let processes = list.map { process in
                let session = process.claudeSession.map { " session=\($0.sessionID.prefix(8)) \($0.status ?? "-")" } ?? ""
                return "\(process.kind.id)#\(process.pid) cpu=\(String(format: "%.0f%%", process.cpuLoad * 100))\(session) cwd=\((process.workingDirectory as NSString).lastPathComponent)"
            }.joined(separator: ", ")
            lines.append("  processes \((worktree as NSString).lastPathComponent): \(processes)")
        }
        for (worktree, sessions) in hub.statuses.sorted(by: { $0.key < $1.key }) {
            for status in sessions {
                lines.append("  status \((worktree as NSString).lastPathComponent): \(status.agent.id) \(status.activity.title) since=\(Format.time.string(from: status.since)) turn=\(status.turnStartedAt.map { "-\(Int(Date().timeIntervalSince($0)))s" } ?? "-") tools=\(status.recentToolCalls.count) session=\(status.sessionID?.prefix(8) ?? "-") from=\(status.fromSessionRecord ? "record" : "hooks")")
            }
        }
        for (worktree, here) in hub.agents.sorted(by: { $0.key < $1.key }) where here.agentCount > 0 {
            let collisions = here.collisions.map { "\(($0.path as NSString).lastPathComponent)<\($0.agents.map(\.id).joined(separator: "+"))>" }
            lines.append("  agents \((worktree as NSString).lastPathComponent): live=\(here.live.map { "\($0.agent.id):\($0.key.prefix(8))" }) unclaimed=\(here.unclaimed.map(\.pid)) shared=\(here.isShared) collisions=\(collisions) dismissed=\(hub.dismissedCollisions[worktree]?.count ?? 0)")
        }
        if let toolbar = NSApp.windows.first(where: { $0.toolbar != nil && $0.isVisible })?.toolbar {
            func tips(_ view: NSView?) -> [String] {
                guard let view else { return [] }
                return (view.toolTip.map { [$0] } ?? []) + view.subviews.flatMap(tips)
            }
            lines.append("toolbar: " + toolbar.items.map { item in
                let name = item.label.isEmpty ? item.itemIdentifier.rawValue : item.label
                return "\(name)=\(item.toolTip ?? "-") views=\(tips(item.view))"
            }.joined(separator: " | "))
        }
        if let monitor = NSApp.mainMenu?.items.first(where: { $0.title == "Monitor" })?.submenu {
            // Menus may be rebuilt lazily, just before they open; ask for that first.
            monitor.delegate?.menuNeedsUpdate?(monitor)
            monitor.update()
            let items = monitor.items.filter { !$0.isSeparatorItem }.map { item in
                "\(item.title)\(item.state == .on ? " [on]" : "")\(item.isEnabled ? "" : " (disabled)")"
            }
            lines.append("monitor menu: " + items.joined(separator: " | "))
        }
        lines.append("activity (\(model.activity.count)):")
        for entry in model.activity.prefix(40) {
            lines.append("  \(Format.time.string(from: entry.date)) \(entry.kind.rawValue) \(entry.title) \(entry.detail ?? "")")
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func writeMainWindowImage(to path: String, title: String? = nil) {
        var candidates = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) && $0.contentView != nil }
        if let title { candidates = candidates.filter { $0.title == title } }
        guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let view = window.contentView?.superview ?? window.contentView else { return }

        // Materials and Liquid Glass are composited by the window server and come out blank
        // in a cached display. Flatten them to plain backgrounds for the capture, then restore.
        var restorers: [() -> Void] = []
        neutralizeEffects(in: view, restorers: &restorers)
        defer { for restore in restorers.reversed() { restore() } }

        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        window.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: bounds, to: rep) }
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        // Popovers, panels and sheets are separate windows; save each visible one as well.
        var extra = 0
        for other in NSApp.windows where other !== window && other.isVisible && other.contentView != nil
            && (other === window.attachedSheet || !other.styleMask.contains(.titled))
            && other.frame.width > 40 && other.frame.height > 40 {
            guard let otherView = other.contentView?.superview ?? other.contentView,
                  let otherRep = otherView.bitmapImageRepForCachingDisplay(in: otherView.bounds) else { continue }
            var otherRestorers: [() -> Void] = []
            neutralizeEffects(in: otherView, restorers: &otherRestorers)
            // Popovers draw their chrome with their own appearance; match the main window's so
            // flattened materials and vibrant text agree on light versus dark.
            let previousAppearance = other.appearance
            other.appearance = window.effectiveAppearance
            other.effectiveAppearance.performAsCurrentDrawingAppearance {
                otherView.cacheDisplay(in: otherView.bounds, to: otherRep)
            }
            other.appearance = previousAppearance
            for restore in otherRestorers.reversed() { restore() }
            // Nothing paints behind popover content once its material is flattened, so the
            // capture is transparent; composite it over the window background.
            let flattened = composited(otherRep, appearance: window.effectiveAppearance)
            if let otherData = flattened.representation(using: .png, properties: [:]) {
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

    private static func composited(_ rep: NSBitmapImageRep, appearance: NSAppearance) -> NSBitmapImageRep {
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return rep }
        out.size = rep.size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: out) else { return rep }
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: rep.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: rep.size))
        return out
    }

    private static func neutralizeEffects(in view: NSView, restorers: inout [() -> Void]) {
        let className = NSStringFromClass(type(of: view))
        if let effect = view as? NSVisualEffectView {
            let material = effect.material
            let state = effect.state
            let blending = effect.blendingMode
            effect.material = .windowBackground
            effect.state = .inactive
            effect.blendingMode = .withinWindow
            restorers.append { effect.material = material; effect.state = state; effect.blendingMode = blending }
        } else if isEffectOnlyView(className) {
            let wasHidden = view.isHidden
            view.isHidden = true
            restorers.append { view.isHidden = wasHidden }
        }
        for subview in view.subviews { neutralizeEffects(in: subview, restorers: &restorers) }
    }

    /// Views that only paint an effect (glass backdrops, scroll-edge pockets) and hold no content.
    private static func isEffectOnlyView(_ className: String) -> Bool {
        if className.contains("Glass") && className.contains("RootView") { return true }
        for marker in ["BackdropView", "PortalView", "PocketBlur", "LuminanceAdjustment", "DimmingView", "PocketMask"]
        where className.contains(marker) { return true }
        return false
    }

}
#endif
