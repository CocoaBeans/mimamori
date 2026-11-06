import SwiftUI
import MimamoriCore

/// Mimamori › Uninstall Mimamori…: everything Mimamori added to this Mac, each with a checkbox,
/// removed before the app goes in the Trash.
struct UninstallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var plan = UninstallPlan()
    @State private var leftovers: Uninstaller.Leftovers?
    @State private var running = false
    @State private var report: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Uninstall Mimamori")
                .font(.title2.weight(.semibold))
            if let report {
                done(report)
            } else if let leftovers {
                choices(leftovers)
            } else {
                ProgressView("Looking for what Mimamori added…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task { leftovers = await Uninstaller.find(model: model) }
    }

    @ViewBuilder
    private func choices(_ leftovers: Uninstaller.Leftovers) -> some View {
        Text("macOS gives an app no word when it is deleted, so remove what Mimamori added first. Choose what goes; Mimamori quits when it is done.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 12) {
            item($plan.claudeHooks, available: leftovers.claudeHooks, "Claude Code hooks",
                 leftovers.claudeHooks
                    ? "Mimamori's entries in \(Format.abbreviate(path: HookInstaller.settingsURL.path)); your own stay, and the file is backed up first."
                    : Uninstaller.mayEditClaude ? "Not installed." : "Left alone in a scripted run.")
            item($plan.hermesHooks, available: leftovers.hermesHooks, "Hermes hooks",
                 leftovers.hermesHooks
                    ? "The script in \(Format.abbreviate(path: HermesHookInstaller.scriptURL.deletingLastPathComponent().path)) and Mimamori's block in config.yaml, backed up first."
                    : "Not installed.")
            item($plan.snapshots, available: leftovers.snapshotCount > 0, "Snapshots",
                 leftovers.snapshotCount > 0
                    ? "\(leftovers.snapshotCount) \(leftovers.snapshotCount == 1 ? "ref" : "refs") under refs/monitor/ in \(leftovers.snapshots.count == 1 ? "1 repository" : "\(leftovers.snapshots.count) repositories"). Your branches and commits are untouched."
                    : "None saved.")
            item($plan.data, available: true, "Settings and activity",
                 Persistence.isScratch
                    ? "This run's folder, \(Persistence.supportDirectory.path)."
                    : "\(Format.abbreviate(path: Persistence.supportDirectory.path)) (watched repositories, reviews, the activity feed), paired iPhones and their keys, preferences, caches and the widgets' data.")
            item($plan.trashApp, available: leftovers.app != nil, "Move Mimamori to the Trash",
                 leftovers.app.map { Format.abbreviate(path: $0.path) } ?? "Not running from an app bundle.")
        }
        Text("Agent sessions already running keep Mimamori's hooks until they restart; until then they fail without a sound. Backups of your agents' settings stay beside them.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("Cancel") { dismissWindow(id: "uninstall") }
                .keyboardShortcut(.cancelAction)
            Button("Uninstall", role: .destructive) {
                running = true
                Task {
                    report = await Uninstaller.run(plan, leftovers: leftovers, model: model)
                    running = false
                }
            }
            .disabled(running || !anythingChosen(leftovers))
        }
    }

    private func anythingChosen(_ leftovers: Uninstaller.Leftovers) -> Bool {
        (plan.claudeHooks && leftovers.claudeHooks) || (plan.hermesHooks && leftovers.hermesHooks)
            || (plan.snapshots && leftovers.snapshotCount > 0) || plan.data || (plan.trashApp && leftovers.app != nil)
    }

    private func item(_ isOn: Binding<Bool>, available: Bool, _ title: String, _ detail: String) -> some View {
        Toggle(isOn: Binding(get: { available && isOn.wrappedValue }, set: { isOn.wrappedValue = $0 })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!available || running)
    }

    @ViewBuilder
    private func done(_ report: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(report.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: line.hasPrefix("Could not") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(line.hasPrefix("Could not") ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if report.isEmpty {
                Text("Nothing was removed.")
                    .foregroundStyle(.secondary)
            }
        }
        HStack {
            Spacer()
            Button("Quit Mimamori") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut(.defaultAction)
        }
    }
}
