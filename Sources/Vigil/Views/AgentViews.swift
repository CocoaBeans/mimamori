import SwiftUI
import VigilCore

extension AgentPresence {
    var tint: Color {
        switch (source, activity) {
        case (.hooks, .working): .blue
        case (.hooks, .needsPermission): .orange
        case (.hooks, .waitingForInput): .green
        case (.hooks, .idle): .secondary
        case (.process, _): isBusy ? .blue : .secondary
        }
    }

    var systemImage: String {
        switch (source, activity) {
        case (.hooks, .needsPermission): "hand.raised.fill"
        case (.hooks, .waitingForInput): "bubble.left.fill"
        case (.hooks, .working): "sparkles"
        case (.hooks, .idle): "sparkles"
        case (.process, _): "sparkles"
        }
    }
}

/// A small colored dot plus agent name, for sidebar rows.
struct AgentPresenceBadge: View {
    let presence: AgentPresence

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: presence.systemImage)
                .font(.caption2)
                .foregroundStyle(presence.tint)
                .symbolEffect(.pulse, options: .repeating, isActive: isWorking)
            Text(summary)
                .font(.caption)
                .foregroundStyle(presence.needsAttention ? presence.tint : .secondary)
                .lineLimit(1)
        }
        .help(presence.kind.displayName + " · " + presence.statusText)
    }

    private var isWorking: Bool {
        if case .working = presence.activity, presence.source == .hooks { return true }
        return presence.source == .process && presence.isBusy
    }

    private var summary: String {
        switch (presence.source, presence.activity) {
        case (.hooks, .working(let tool, _)): tool.map { "\(presence.kind.displayName) · \($0)" } ?? "\(presence.kind.displayName) · working"
        case (.hooks, .needsPermission): "\(presence.kind.displayName) · needs permission"
        case (.hooks, .waitingForInput): "\(presence.kind.displayName) · waiting for you"
        case (.hooks, .idle): "\(presence.kind.displayName) · ended"
        case (.process, _): "\(presence.kind.displayName) · \(presence.isBusy ? "busy" : "running")"
        }
    }
}

/// The full status line shown in a worktree header.
struct AgentStatusLine: View {
    let presence: AgentPresence
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: presence.systemImage)
                .foregroundStyle(presence.tint)
            Text(presence.kind.displayName)
                .fontWeight(.medium)
            Text("·").foregroundStyle(.tertiary)
            Text(presence.statusText)
                .foregroundStyle(presence.needsAttention ? presence.tint : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if presence.source == .hooks, presence.toolCallsThisTurn > 0, case .working = presence.activity {
                Text("\(presence.toolCallsThisTurn) tools")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Text(Format.relative(presence.since, to: now))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .font(.caption)
        .help(presence.source == .hooks
              ? "Reported by the agent's hooks"
              : "An agent process has this worktree as its working directory. Install hooks for live status.")
    }
}

/// A prominent status banner for the top of the detail column.
struct AgentStatusBanner: View {
    let presence: AgentPresence
    let now: Date

    private var isWorking: Bool {
        if case .working = presence.activity, presence.source == .hooks { return true }
        return presence.source == .process && presence.isBusy
    }

    private var headline: String {
        switch (presence.source, presence.activity) {
        case (.hooks, .working(let tool, _)): tool.map { "Working · \($0)" } ?? "Working"
        case (.hooks, .needsPermission(let tool, _)): "Needs your permission · \(tool)"
        case (.hooks, .waitingForInput): "Waiting for your input"
        case (.hooks, .idle): "Session ended"
        case (.process, _): presence.isBusy ? "Running" : "Running, idle"
        }
    }

    private var detail: String? {
        switch presence.activity {
        case .working(_, let detail): detail
        case .needsPermission(_, let detail): detail
        default: presence.source == .process ? "No hooks installed; showing process presence only" : nil
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: presence.systemImage)
                .font(.title2)
                .foregroundStyle(presence.tint)
                .symbolEffect(.pulse, options: .repeating, isActive: isWorking)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(presence.kind.displayName)
                        .font(.headline)
                    Text(headline)
                        .font(.headline)
                        .fontWeight(.regular)
                        .foregroundStyle(presence.needsAttention ? presence.tint : .primary)
                }
                .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.relative(presence.since, to: now))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                if presence.source == .hooks, presence.toolCallsThisTurn > 0 {
                    Text(presence.toolCallsThisTurn == 1 ? "1 tool call" : "\(presence.toolCallsThisTurn) tool calls")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(presence.tint.opacity(presence.needsAttention ? 0.16 : 0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(presence.tint.opacity(presence.needsAttention ? 0.5 : 0.2), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .help(presence.source == .hooks ? "Reported by the agent's hooks" : "An agent process has this worktree as its working directory. Install hooks for live status.")
        .accessibilityElement(children: .combine)
    }
}

/// Sidebar footer button: how many worktrees have an agent waiting on you.
struct AttentionNeededButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let waiting = model.worktreesNeedingAttention
        if !waiting.isEmpty {
            Button {
                if let first = waiting.first { model.select(worktree: first) }
            } label: {
                Label("\(waiting.count)", systemImage: "hand.raised.fill")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help(waiting.count == 1 ? "An agent is waiting for you" : "\(waiting.count) agents are waiting for you")
        }
    }
}

/// Settings tab: hooks, detection, feed and notifications.
struct AgentSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var hooksInstalled = HookInstaller.isInstalled()
    @State private var confirmInstall = false
    @State private var confirmUninstall = false
    @State private var lastMessage: String?
    @State private var customNames = ""
    @State private var hermesState = HermesHookInstaller.state()
    @State private var confirmHermesInstall = false
    @State private var confirmHermesUninstall = false
    @State private var hermesMessage: String?

    private var hermesStatusText: String {
        switch hermesState {
        case .notPresent: "Hermes not found"
        case .notInstalled: "Not installed"
        case .installed: "Installed"
        case .manualMergeNeeded: "Manual merge needed"
        }
    }

    var body: some View {
        let settings = SettingsBinding.make(model)
        let hub = model.agentHub
        Form {
            Section {
                LabeledContent("Socket") {
                    HStack(spacing: 6) {
                        Circle().fill(hub.isListening ? .green : .red).frame(width: 8, height: 8)
                        Text(hub.isListening ? "listening" : (hub.socketError ?? "not listening"))
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Claude Code hooks") {
                    Text(hooksInstalled ? "Installed" : "Not installed")
                        .foregroundStyle(hooksInstalled ? .green : .secondary)
                }
                LabeledContent("Events received", value: "\(hub.eventsReceived)" + (hub.lastEventAt.map { " · last \(Format.relative($0, to: model.now))" } ?? ""))
                HStack {
                    Button("Install Hooks…") { confirmInstall = true }
                        .disabled(hooksInstalled)
                    Button("Uninstall Hooks…") { confirmUninstall = true }
                        .disabled(!hooksInstalled)
                    Spacer()
                    Button("Reveal settings.json") {
                        NSWorkspace.shared.activateFileViewerSelecting([HookInstaller.settingsURL])
                    }
                }
                if let lastMessage {
                    Text(lastMessage).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Hooks")
            } footer: {
                Text("Hooks let Claude Code tell Vigil exactly what it is doing: when a turn starts and ends, every tool call, and when it is waiting for your permission or input. Installing adds entries to ~/.claude/settings.json that post each event to Vigil's local socket with curl; a backup is saved first and your other hooks are left untouched. If Vigil is not running the command fails silently in under a second.")
            }
            if hermesState != .notPresent {
                Section {
                    LabeledContent("Hermes hooks") {
                        Text(hermesStatusText).foregroundStyle(hermesState == .installed ? .green : .secondary)
                    }
                    HStack {
                        Button("Install Hermes Hooks…") { confirmHermesInstall = true }
                            .disabled(hermesState == .installed)
                        Button("Uninstall Hermes Hooks…") { confirmHermesUninstall = true }
                            .disabled(hermesState != .installed)
                        Spacer()
                        Button("Copy YAML") { Workspace.copy(HermesHookInstaller.snippet) }
                            .help("The entries to put under hooks: in ~/.hermes/config.yaml")
                    }
                    if let hermesMessage {
                        Text(hermesMessage).font(.callout).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Hermes Agent")
                } footer: {
                    Text(hermesState == .manualMergeNeeded
                         ? "Your config.yaml already has a hooks: block, so Vigil will not edit it. Install writes the script to ~/.hermes/agent-hooks/vigil.sh; then paste the copied YAML entries under your existing hooks: key."
                         : "Install writes a small script to ~/.hermes/agent-hooks/vigil.sh and appends a delimited hooks: block to ~/.hermes/config.yaml (backup first). Hermes asks once per event for consent the first time each hook runs, unless hooks_auto_accept is on.")
                }
            }
            Section {
                Toggle("Detect agent processes", isOn: settings.agentScanEnabled)
                Stepper("Scan every \(Int(settings.wrappedValue.agentScanIntervalSeconds)) s",
                        value: settings.agentScanIntervalSeconds, in: 1...30, step: 1)
                    .disabled(!settings.wrappedValue.agentScanEnabled)
                TextField("Additional executable names", text: $customNames, prompt: Text("myagent, otheragent"))
                    .onSubmit { commitNames() }
                    .onAppear { customNames = model.settings.customAgentNames.joined(separator: ", ") }
            } header: {
                Text("Detection")
            } footer: {
                Text("Without hooks, Vigil still shows which worktrees have an agent process running in them (Claude Code, Codex, Aider, Cursor, Gemini, Goose, OpenCode, Amp). Add other executable names, comma separated, and press Return.")
            }
            Section("Activity feed") {
                Picker("Show tool calls", selection: settings.agentToolCallsInFeed) {
                    ForEach(AgentToolCallFeedMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }
            Section("Notifications") {
                Toggle("When an agent needs permission", isOn: settings.notifyOnAgentPermission)
                Toggle("When an agent finishes a turn", isOn: settings.notifyOnAgentTurnFinished)
                if !model.isNotifierAvailable {
                    Text("Notifications work when Vigil runs from an app bundle.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Install Vigil's hooks into ~/.claude/settings.json?", isPresented: $confirmInstall) {
            Button("Install") { install() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A backup of the file is saved first. Existing hooks are kept. New Claude Code sessions will report to Vigil; sessions already running pick the change up on their next start.")
        }
        .confirmationDialog("Remove Vigil's hooks from ~/.claude/settings.json?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) { uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the entries that post to Vigil's socket are removed. A backup is saved first.")
        }
        .confirmationDialog("Install Vigil's hooks for Hermes?", isPresented: $confirmHermesInstall) {
            Button("Install") { installHermes() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Writes ~/.hermes/agent-hooks/vigil.sh and appends a delimited hooks: block to ~/.hermes/config.yaml after saving a backup. Nothing else in the file is touched.")
        }
        .confirmationDialog("Remove Vigil's hooks for Hermes?", isPresented: $confirmHermesUninstall) {
            Button("Uninstall", role: .destructive) { uninstallHermes() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the script and Vigil's delimited block from config.yaml after saving a backup.")
        }
    }

    private func installHermes() {
        do {
            if let backup = try HermesHookInstaller.install(socketPath: model.agentHub.socketPath) {
                hermesMessage = "Installed. Backup: \(backup.lastPathComponent). Hermes will ask for consent once per event."
            } else {
                Workspace.copy(HermesHookInstaller.snippet)
                hermesMessage = "Script written. Your config.yaml already has a hooks: key, so the YAML entries were copied to the clipboard; paste them under it."
            }
            hermesState = HermesHookInstaller.state()
        } catch {
            hermesMessage = "Install failed: \(error.localizedDescription)"
        }
    }

    private func uninstallHermes() {
        do {
            let backup = try HermesHookInstaller.uninstall()
            hermesState = HermesHookInstaller.state()
            hermesMessage = backup.map { "Removed. Backup: \($0.lastPathComponent)" } ?? "Script removed. No Vigil block was found in config.yaml."
        } catch {
            hermesMessage = "Uninstall failed: \(error.localizedDescription)"
        }
    }

    private func install() {
        do {
            let backup = try HookInstaller.install(socketPath: model.agentHub.socketPath)
            hooksInstalled = HookInstaller.isInstalled()
            lastMessage = "Installed. Backup: \(backup.lastPathComponent)"
        } catch {
            lastMessage = "Install failed: \(error.localizedDescription)"
        }
    }

    private func uninstall() {
        do {
            let backup = try HookInstaller.uninstall()
            hooksInstalled = HookInstaller.isInstalled()
            lastMessage = "Removed. Backup: \(backup.lastPathComponent)"
        } catch {
            lastMessage = "Uninstall failed: \(error.localizedDescription)"
        }
    }

    private func commitNames() {
        var copy = model.settings
        copy.customAgentNames = customNames.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        model.updateSettings(copy)
    }
}
