import SwiftUI
import VigilCore

/// The panes of the Settings window, so a button elsewhere can open the one it is about.
enum SettingsTab: String, Hashable, CaseIterable {
    case general, snapshots, attention, agents
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            Tab("General", systemImage: "gear", value: .general) { GeneralSettingsView() }
            Tab("Snapshots", systemImage: "camera", value: .snapshots) { SnapshotSettingsView() }
            Tab("Attention", systemImage: "exclamationmark.triangle", value: .attention) { AttentionSettingsView() }
            Tab("Agents", systemImage: "sparkles", value: .agents) { AgentSettingsView() }
        }
        .frame(width: 560, height: 560)
    }
}

struct SettingsBinding {
    @MainActor
    static func make(_ model: AppModel) -> Binding<AppSettings> {
        Binding(get: { model.settings }, set: { model.updateSettings($0) })
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var gitPath = ""

    var body: some View {
        let settings = SettingsBinding.make(model)
        Form {
            Section("Git") {
                TextField("git binary", text: $gitPath, prompt: Text("auto-detect"))
                    .onSubmit { commitGitPath() }
                    .onAppear { gitPath = model.settings.gitPathOverride }
                if let version = model.gitVersion {
                    LabeledContent("Detected", value: version)
                }
                if let error = model.gitError {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            Section("Refresh") {
                Stepper("Settle time: \(settings.wrappedValue.refreshDebounceMilliseconds) ms",
                        value: settings.refreshDebounceMilliseconds, in: 100...3000, step: 100)
                Stepper("Maximum delay: \(settings.wrappedValue.maxRefreshLatencySeconds, specifier: "%.1f") s",
                        value: settings.maxRefreshLatencySeconds, in: 0.5...10, step: 0.5)
                Stepper("Highlight changes for: \(Int(settings.wrappedValue.recencyWindowSeconds)) s",
                        value: settings.recencyWindowSeconds, in: 10...600, step: 10)
            }
            Section("Appearance") {
                Toggle("Show in menu bar", isOn: settings.showMenuBarExtra)
                    .help("Show changed and flagged files, and agents waiting on you, in the menu bar")
                Toggle("Wrap long diff lines", isOn: settings.wrapDiffLines)
                    .help("Wrap long lines instead of scrolling them sideways (⌥⌘W)")
                    .disabled(settings.wrappedValue.diffLayout == .sideBySide)
                Toggle("Show diffs side by side", isOn: Binding(
                    get: { settings.wrappedValue.diffLayout == .sideBySide },
                    set: { settings.wrappedValue.diffLayout = $0 ? .sideBySide : .unified }))
                    .help("Show old and new side by side instead of in one column (⌥⌘L)")
                Toggle("Highlight syntax in diffs", isOn: settings.syntaxHighlighting)
                    .help("Color code in diffs by language")
                Stepper("Diff font size: \(Int(settings.wrappedValue.diffFontSize))",
                        value: settings.diffFontSize, in: 9...20, step: 1)
            }
            Section {
                Stepper("Keep activity for \(settings.wrappedValue.activityRetentionDays) day\(settings.wrappedValue.activityRetentionDays == 1 ? "" : "s")",
                        value: settings.activityRetentionDays, in: 1...90)
            } header: {
                Text("Activity")
            } footer: {
                Text("The activity feed is saved in ~/Library/Application Support/Vigil/activity.jsonl, so it and session summaries survive a restart. Clearing the feed clears the file.")
            }
            Section("Notifications") {
                Toggle("Notify when a change is flagged", isOn: settings.notificationsEnabled)
                    .help("Post a notification when a change matches an attention rule")
                    .disabled(!model.isNotifierAvailable)
                Picker("Minimum severity", selection: settings.notifyMinimumSeverity) {
                    Text("Warning").tag(Severity.warning)
                    Text("Critical").tag(Severity.critical)
                }
                .disabled(!settings.wrappedValue.notificationsEnabled)
                .help("Notify only for flags at least this severe")
                if !model.isNotifierAvailable {
                    Text("Notifications work when Vigil runs from an app bundle (Scripts/make-app.sh).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func commitGitPath() {
        var copy = model.settings
        copy.gitPathOverride = gitPath.trimmingCharacters(in: .whitespaces)
        model.updateSettings(copy)
    }
}

struct SnapshotSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false

    var body: some View {
        let settings = SettingsBinding.make(model)
        Form {
            Section {
                Toggle("Record snapshots automatically", isOn: settings.snapshotsEnabled)
                    .help("Save a snapshot of the working tree as it changes, so you can compare against earlier moments")
                Stepper("At most one every \(Int(settings.wrappedValue.snapshotMinimumIntervalSeconds)) s",
                        value: settings.snapshotMinimumIntervalSeconds, in: 5...600, step: 5)
                    .disabled(!settings.wrappedValue.snapshotsEnabled)
                Stepper("Keep the newest \(settings.wrappedValue.maxSnapshotsPerWorktree) per worktree",
                        value: settings.maxSnapshotsPerWorktree, in: 10...2000, step: 10)
            } header: {
                Text("Snapshots")
            } footer: {
                Text("A snapshot is a commit object of the whole working tree, including untracked files, stored under refs/monitor/ inside the repository. Branches, the index and the working tree are never touched. Snapshots let you compare against any earlier moment and keep the Start marker alive across restarts.")
            }
            if let session = model.selectedSession {
                Section("Selected worktree: \(session.displayName)") {
                    LabeledContent("Snapshots", value: "\(session.snapshots.count)")
                    if let start = session.startSnapshot {
                        LabeledContent("Start marker", value: Format.dateTime.string(from: start.date))
                    }
                    Button("Delete All Snapshots for This Worktree…", role: .destructive) { confirmDelete = true }
                        .disabled(session.snapshots.isEmpty)
                        .help("Remove every snapshot Vigil recorded for this worktree, including the start marker")
                        .confirmationDialog("Delete all snapshots?", isPresented: $confirmDelete) {
                            Button("Delete", role: .destructive) { Task { await session.deleteAllSnapshots() } }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Removes every ref under refs/monitor for this worktree, including the start marker. The objects become unreachable and git will garbage-collect them later.")
                        }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AttentionSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var scopeText = ""

    var body: some View {
        let settings = SettingsBinding.make(model)
        Form {
            Section {
                Stepper("Mass deletion: \(settings.wrappedValue.inspector.rules.massDeletionThreshold)+ lines",
                        value: settings.inspector.rules.massDeletionThreshold, in: 20...5000, step: 20)
                Stepper("Large addition: \(settings.wrappedValue.inspector.rules.largeAdditionThreshold)+ lines",
                        value: settings.inspector.rules.largeAdditionThreshold, in: 100...20000, step: 100)
                Stepper("Huge file: \(ByteCountFormatter.string(fromByteCount: Int64(settings.wrappedValue.inspector.rules.hugeFileBytes), countStyle: .file))",
                        value: settings.inspector.rules.hugeFileBytes, in: 100_000...100_000_000, step: 500_000)
            } header: {
                Text("Thresholds")
            }
            if let session = model.selectedSession {
                Section {
                    TextField("Allowed path prefixes", text: $scopeText, prompt: Text("src/, Tests/ (comma separated)"))
                        .onSubmit { commitScope(session) }
                        .onAppear { scopeText = session.scopePrefixes.joined(separator: ", ") }
                        .onChange(of: session.id) { scopeText = session.scopePrefixes.joined(separator: ", ") }
                } header: {
                    Text("Scope for \(session.displayName)")
                } footer: {
                    Text("Changes outside these prefixes are flagged. Leave empty to allow the whole repository. Press Return to apply.")
                }
            }
            Section("Rules") {
                ForEach(RuleID.allCases) { rule in
                    Toggle(isOn: Binding(
                        get: { !model.settings.inspector.rules.disabledRules.contains(rule) },
                        set: { enabled in
                            var copy = model.settings
                            if enabled { copy.inspector.rules.disabledRules.remove(rule) } else { copy.inspector.rules.disabledRules.insert(rule) }
                            model.updateSettings(copy)
                        })) {
                        Label {
                            HStack {
                                Text(rule.title)
                                Spacer()
                                Text(rule.defaultSeverity.title)
                                    .font(.caption)
                                    .foregroundStyle(rule.defaultSeverity.color)
                            }
                        } icon: {
                            Image(systemName: rule.systemImage)
                        }
                    }
                    .help(rule.explanation)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func commitScope(_ session: WorktreeSession) {
        let prefixes = scopeText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        session.setScopePrefixes(prefixes)
    }
}
