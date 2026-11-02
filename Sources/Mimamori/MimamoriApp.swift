import AppKit
import SwiftUI
import MimamoriCore

@main
struct MimamoriApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    /// Started with the app, so Sparkle can check on its schedule.
    @State private var updates = Updates()

    init() {
        if Bundle.main.bundleURL.pathExtension != "app" {
            // Running bare (swift run): still behave like a foreground app.
            NSApplication.shared.setActivationPolicy(.regular)
            DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
    }

    var body: some Scene {
        Window("Mimamori", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        // mimamori:// links (from the desktop widgets) open here, whichever window is in front.
        .handlesExternalEvents(matching: ["*"])
        .commands { MimamoriCommands(model: model, updates: updates) }

        // One per worktree, so a summary can sit beside your work. A summary reopened after a
        // relaunch could name a worktree no longer watched, so they are not restored.
        WindowGroup("Session Summary", id: SessionSummaryWindow.id, for: String.self) { $worktree in
            SessionSummaryWindow(worktree: worktree)
                .environment(model)
        }
        .defaultSize(width: 760, height: 680)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])

        Window("Agents", id: "agents") {
            AgentsWindowView()
                .environment(model)
        }
        .defaultSize(width: 520, height: 620)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .windowLevel(model.settings.agentsWindowFloats ? .floating : .normal)

        // The menu-bar panel, pinned: a window of its own above the others, until you unpin it.
        Window("Mimamori Overview", id: MenuBarPanel.pinnedWindowID) {
            MenuBarPanel(pinned: true)
                .environment(model)
        }
        .defaultSize(width: 340, height: 560)
        .windowResizability(.contentMinSize)
        .windowLevel(.floating)
        .handlesExternalEvents(matching: [])
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(model)
                .environment(updates)
        }

        MenuBarExtra(isInserted: Binding(
            get: { model.settings.showMenuBarExtra },
            set: { value in
                var copy = model.settings
                copy.showMenuBarExtra = value
                model.updateSettings(copy)
            })) {
            MenuBarPanel()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MimamoriCommands: Commands {
    let model: AppModel
    let updates: Updates
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Mimamori") { BuildInfo.showAboutPanel() }
            if updates.isEnabled {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheck)
            }
        }
        CommandGroup(after: .help) {
            Button("Troubleshoot Agent Hooks…") {
                model.settingsTab = .agents
                openSettings()
            }
            Button("Copy Diagnostics") { model.copyDiagnostics() }
            Divider()
            Button("Mimamori on GitHub") { NSWorkspace.shared.open(BuildInfo.repository) }
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Repository…") { model.promptForRepository() }
                .keyboardShortcut("o")
            Button("Stop Watching Repository…") { model.requestRemovalOfSelectedRepository() }
                .keyboardShortcut(.delete, modifiers: .command)
        }
        CommandMenu("Monitor") {
            Button("Refresh") { model.selectedSession?.requestRefresh(force: true) }
                .keyboardShortcut("r")
            Button("Refresh All") { model.refreshAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Mark Start") { if let session = model.selectedSession { Task { await session.markStart() } } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Clear Start Marker") { if let session = model.selectedSession { Task { await session.clearStart() } } }
            Button("Take Snapshot Now") { if let session = model.selectedSession { Task { await session.takeSnapshotNow() } } }
            Button("Session Summary…") { if let session = model.selectedSession { openWindow.summary(for: session.id) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button("Compare Uncommitted") { model.selectedSession?.setBaseline(.head) }
                .keyboardShortcut("1")
            Button("Compare Since Branch Point") { model.selectedSession?.setBaseline(.branchPoint) }
                .keyboardShortcut("2")
            Button("Compare Since Start") { model.selectedSession?.setBaseline(.start) }
                .keyboardShortcut("3")
            Toggle("Show Commits", isOn: Binding(get: { model.showCommits }, set: { model.showCommits = $0 }))
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            Button("Filter Files") { model.filterFocusToken += 1 }
                .keyboardShortcut("f")
            Toggle("Flagged Only", isOn: Binding(get: { model.flaggedOnly }, set: { model.flaggedOnly = $0 }))
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Toggle("Only Files to Review", isOn: Binding(get: { model.hideReviewed }, set: { model.hideReviewed = $0 }))
                .keyboardShortcut("r", modifiers: [.command, .option])
            Toggle("Only Worktrees with Agents", isOn: Binding(get: { model.sidebarAgentsOnly }, set: { model.sidebarAgentsOnly = $0 }))
            Toggle("Wrap Diff Lines", isOn: Binding(
                get: { model.settings.wrapDiffLines },
                set: { value in
                    var copy = model.settings
                    copy.wrapDiffLines = value
                    model.updateSettings(copy)
                }))
                .keyboardShortcut("w", modifiers: [.command, .option])
            Toggle("Side-by-Side Diff", isOn: Binding(
                get: { model.settings.diffLayout == .sideBySide },
                set: { value in
                    var copy = model.settings
                    copy.diffLayout = value ? .sideBySide : .unified
                    model.updateSettings(copy)
                }))
                .keyboardShortcut("l", modifiers: [.command, .option])
            Toggle("Syntax Highlighting", isOn: Binding(
                get: { model.settings.syntaxHighlighting },
                set: { value in
                    var copy = model.settings
                    copy.syntaxHighlighting = value
                    model.updateSettings(copy)
                }))
            Divider()
            Button(model.selectedChangeIsReviewed ? "Mark as Not Reviewed" : "Mark as Reviewed") {
                model.toggleReviewForSelection()
            }
            .keyboardShortcut(.return, modifiers: .command)
            Button("Mark All as Reviewed") { model.selectedSession?.markAllReviewed() }
                .keyboardShortcut(.return, modifiers: [.command, .option])
            Button("Clear All Reviews") { model.selectedSession?.clearAllReviews() }
        }
        SidebarCommands()
        InspectorCommands()
    }
}
