import AppKit
import MimamoriCore

/// What Uninstall Mimamori removes, as you choose it.
struct UninstallPlan: Equatable {
    var claudeHooks = true
    var hermesHooks = true
    var snapshots = true
    var data = true
    var trashApp = true
}

/// Everything Mimamori leaves on a Mac, and taking it away before the app goes in the Trash:
/// macOS gives an app no say when it is deleted, so this has to happen first. A scripted run
/// (MIMAMORI_SUPPORT_DIR) touches only what it was pointed at, never the real agent settings,
/// preferences or widget data.
@MainActor
enum Uninstaller {
    struct Leftovers {
        var claudeHooks = false
        var hermesHooks = false
        /// Snapshot refs, by the repository they are in.
        var snapshots: [(root: String, refs: [String])] = []
        var app: URL?

        var snapshotCount: Int { snapshots.reduce(0) { $0 + $1.refs.count } }
    }

    /// Whether the agents' real settings may be edited: not from a scripted run that was not
    /// pointed at scratch copies of them.
    static var mayEditClaude: Bool { !Persistence.isScratch || environment("CLAUDE_CONFIG_DIR") != nil }
    static var mayEditHermes: Bool { !Persistence.isScratch || environment("HERMES_HOME") != nil }

    private static func environment(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func find(model: AppModel) async -> Leftovers {
        var found = Leftovers()
        found.claudeHooks = mayEditClaude && HookInstaller.isInstalled()
        found.hermesHooks = mayEditHermes && HermesHookInstaller.state() == .installed
        // The saved list, not the loaded one: this may run while repositories are still loading.
        if let git = await git(model) {
            for root in model.repositoryRoots {
                let refs = (try? await git.refs(withPrefix: "refs/monitor/", in: URL(fileURLWithPath: root))) ?? []
                if !refs.isEmpty { found.snapshots.append((root, refs.map(\.name))) }
            }
        }
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" { found.app = bundle }
        return found
    }

    private static func git(_ model: AppModel) async -> GitClient? {
        if let git = model.git { return git }
        return await GitClient.locate(preferred: model.settings.gitPathOverride)
    }

    /// Carries out the plan. Returns a line for each thing done, or that could not be.
    static func run(_ plan: UninstallPlan, leftovers: Leftovers, model: AppModel) async -> [String] {
        var report: [String] = []
        if plan.claudeHooks, leftovers.claudeHooks {
            do {
                let backup = try HookInstaller.uninstall()
                report.append("Removed Claude Code's hooks from \(Format.abbreviate(path: HookInstaller.settingsURL.path)); the file as it was is saved beside it as \(backup.lastPathComponent).")
            } catch {
                report.append("Could not remove Claude Code's hooks: \(error.localizedDescription)")
            }
        }
        if plan.hermesHooks, leftovers.hermesHooks {
            do {
                let backup = try HermesHookInstaller.uninstall()
                report.append("Removed Hermes's hooks" + (backup.map { "; config.yaml as it was is saved as \($0.lastPathComponent)." } ?? "."))
            } catch {
                report.append("Could not remove Hermes's hooks: \(error.localizedDescription)")
            }
        }
        if plan.snapshots, leftovers.snapshotCount > 0, let git = await git(model) {
            var removed = 0
            for (root, refs) in leftovers.snapshots {
                for ref in refs where (try? await git.deleteRef(ref, in: URL(fileURLWithPath: root))) != nil {
                    removed += 1
                }
            }
            let repositories = leftovers.snapshots.count == 1 ? "1 repository" : "\(leftovers.snapshots.count) repositories"
            report.append("Deleted \(removed) snapshot \(removed == 1 ? "ref" : "refs") from \(repositories).")
        }
        if plan.data {
            model.isUninstalling = true
            // Stop serving paired phones, and delete their secrets from the Keychain.
            model.companion.removeAll()
            removeData()
            report.append(Persistence.isScratch
                          ? "Deleted this run's settings and activity in \(Persistence.supportDirectory.path)."
                          : "Deleted Mimamori's settings, activity, iPhone pairings, preferences and caches.")
        }
        if plan.trashApp, let app = leftovers.app {
            do {
                _ = try await NSWorkspace.shared.recycle([app])
                report.append("Moved Mimamori to the Trash.")
            } catch {
                report.append("Could not move Mimamori to the Trash (\(error.localizedDescription)): drag it there yourself.")
            }
        }
        for line in report { Log.state.notice("Uninstall: \(line, privacy: .public)") }
        return report
    }

    /// Mimamori's own files: its support folder, and outside a scripted run its preferences,
    /// caches, saved window state and the widgets' copy of the agents.
    static func removeData() {
        let manager = FileManager.default
        try? manager.removeItem(at: Persistence.supportDirectory)
        guard !Persistence.isScratch else { return }
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
            let library = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
            for folder in ["Caches/\(id)", "HTTPStorages/\(id)", "Saved Application State/\(id).savedState"] {
                try? manager.removeItem(at: library.appendingPathComponent(folder))
            }
        }
        if let widgets = AgentWidgetSnapshot.fileURL {
            try? manager.removeItem(at: widgets)
        }
    }
}
