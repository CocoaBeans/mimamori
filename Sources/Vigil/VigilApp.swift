import AppKit
import SwiftUI
import VigilCore

@main
struct VigilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        if Bundle.main.bundleURL.pathExtension != "app" {
            // Running bare (swift run): still behave like a foreground app.
            NSApplication.shared.setActivationPolicy(.regular)
            DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
    }

    var body: some Scene {
        Window("Vigil", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands { VigilCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: Binding(
            get: { model.settings.showMenuBarExtra },
            set: { value in
                var copy = model.settings
                copy.showMenuBarExtra = value
                model.updateSettings(copy)
            })) {
            MenuBarMenu()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct VigilCommands: Commands {
    let model: AppModel

    var body: some Commands {
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
            Divider()
            Button("Compare Uncommitted") { model.selectedSession?.setBaseline(.head) }
                .keyboardShortcut("1")
            Button("Compare Since Branch Point") { model.selectedSession?.setBaseline(.branchPoint) }
                .keyboardShortcut("2")
            Button("Compare Since Start") { model.selectedSession?.setBaseline(.start) }
                .keyboardShortcut("3")
            Divider()
            Button("Filter Files") { model.filterFocusToken += 1 }
                .keyboardShortcut("f")
            Toggle("Flagged Only", isOn: Binding(get: { model.flaggedOnly }, set: { model.flaggedOnly = $0 }))
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Toggle("Hide Reviewed Files", isOn: Binding(get: { model.hideReviewed }, set: { model.hideReviewed = $0 }))
            Toggle("Wrap Diff Lines", isOn: Binding(
                get: { model.settings.wrapDiffLines },
                set: { value in
                    var copy = model.settings
                    copy.wrapDiffLines = value
                    model.updateSettings(copy)
                }))
                .keyboardShortcut("w", modifiers: [.command, .option])
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
