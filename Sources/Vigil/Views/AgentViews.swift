import SwiftUI
import VigilCore

// Agent icons stay still on purpose. Any repeating symbol effect (a pulse, or a bounce per
// tool call) redraws the window every frame while an agent works, which cost a quarter of a
// CPU core; the tint and the status text already change as the agent does.
extension AgentPresence {
    var tint: Color {
        switch (source, activity) {
        case (.hooks, .working): .blue
        case (.hooks, .needsPermission): .orange
        case (.hooks, .askedQuestion): .orange
        case (.hooks, .ready): .green
        case (.hooks, .idle): .secondary
        case (.process, _): isBusy ? .blue : .secondary
        }
    }

    var systemImage: String {
        switch (source, activity) {
        case (.hooks, .needsPermission): "hand.raised.fill"
        case (.hooks, .askedQuestion): "questionmark.bubble.fill"
        case (.hooks, .ready): "checkmark.bubble"
        case (.hooks, .working): "sparkles"
        case (.hooks, .idle): "sparkles"
        case (.process, _): "sparkles"
        }
    }

    /// What the clock measures, said plainly: "working for 4m", "waiting 30s", "idle for 3m".
    func timing(now: Date) -> String {
        let span = Format.duration(since: since, to: now)
        switch (source, activity) {
        case (.process, _): return "running for \(span)"
        case (.hooks, .working): return "working for \(span)"
        case (.hooks, .needsPermission), (.hooks, .askedQuestion): return "waiting \(span)"
        case (.hooks, .ready): return "idle for \(span)"
        case (.hooks, .idle): return "ended \(Format.relative(since, to: now))"
        }
    }

    var timingHelp: String {
        switch source {
        case .process: "Time since the oldest agent process in this worktree started. Install hooks to see what it is doing."
        case .hooks: "Time since the agent entered this state, as reported by its hooks."
        }
    }

    var isWorking: Bool {
        if case .working = activity, source == .hooks { return true }
        return source == .process && isBusy
    }

    /// Sort rank in lists of agents: what is blocked on you, then what is busy, then the rest.
    var urgency: Int {
        switch (source, activity) {
        case (.hooks, .needsPermission), (.hooks, .askedQuestion): 0
        case (.hooks, .working): 1
        case (.process, _): isBusy ? 1 : 2
        case (.hooks, .ready): 2
        case (.hooks, .idle): 3
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
            Text(summary)
                .font(.caption)
                .foregroundStyle(presence.needsAttention ? presence.tint : .secondary)
                .lineLimit(1)
        }
        .help(presence.kind.displayName + " · " + presence.statusText)
    }

    private var summary: String {
        switch (presence.source, presence.activity) {
        case (.hooks, .working(let tool, _)): tool.map { "\(presence.kind.displayName) · \($0)" } ?? "\(presence.kind.displayName) · working"
        case (.hooks, .needsPermission): "\(presence.kind.displayName) · needs permission"
        case (.hooks, .askedQuestion): "\(presence.kind.displayName) · has a question"
        case (.hooks, .ready): "\(presence.kind.displayName) · ready"
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
            Text(presence.source == .process ? "up \(Format.duration(since: presence.since, to: now))" : Format.duration(since: presence.since, to: now))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .font(.caption)
        .help(presence.source == .hooks
              ? "Reported by the agent's hooks"
              : "An agent process has this worktree as its working directory. Install hooks for live status.")
    }
}

/// What the banner above the diff can add about the agent's turn, and what it can do.
struct AgentBannerDetails {
    var worktree: String
    /// Changed files touched this turn, most recent first.
    var files: [FileChange]
    var expanded: Bool
    var canGoToAgent: Bool
    var onToggle: () -> Void
    var onOpenFile: (String) -> Void
    var onGoToAgent: () -> Void
    var onSummary: () -> Void
}

/// A prominent status banner for the top of the detail column.
struct AgentStatusBanner: View {
    let presence: AgentPresence
    let now: Date
    var details: AgentBannerDetails? = nil

    private var expanded: Bool { details?.expanded ?? false }

    /// When the steps are listed below, the headline need not name the running tool.
    private var stepsShown: Bool {
        expanded && presence.source == .hooks && !presence.turnSteps.isEmpty
    }

    private var headline: String {
        switch (presence.source, presence.activity) {
        case (.hooks, .working(let tool, _)): stepsShown ? "Working" : tool.map { "Working · \($0)" } ?? "Working"
        case (.hooks, .needsPermission(let tool, _)): tool.isEmpty ? "Needs your permission" : "Needs your permission · \(tool)"
        case (.hooks, .askedQuestion): "Has a question for you"
        case (.hooks, .ready): "Ready for your next prompt"
        case (.hooks, .idle): "Session ended"
        case (.process, _): presence.isBusy ? "Running" : "Running, idle"
        }
    }

    /// The headline for a narrow column.
    private var shortHeadline: String {
        switch (presence.source, presence.activity) {
        case (.hooks, .working(let tool, _)): stepsShown ? "Working" : tool ?? "Working"
        case (.hooks, .needsPermission): "Needs permission"
        case (.hooks, .askedQuestion): "Has a question"
        case (.hooks, .ready): "Ready"
        case (.hooks, .idle): "Ended"
        case (.process, _): presence.isBusy ? "Running" : "Idle"
        }
    }

    private var detail: String? {
        switch presence.activity {
        case .working(_, let detail): stepsShown ? nil : detail.map(shorten)
        case .needsPermission(_, let detail): detail.map(shorten)
        case .askedQuestion(let detail): detail
        default: presence.source == .process ? processNote : nil
        }
    }

    /// Why only the process shows.
    private var processNote: String {
        switch presence.hooksInstalled {
        case false?: "No hooks installed; showing process presence only"
        case true?: "No hook events from this session yet"
        case nil: "Seen from its process only"
        }
    }

    private func shorten(_ text: String) -> String {
        details.map { AgentText.shortenPaths(text, in: $0.worktree) } ?? text
    }

    private func headlineRow(_ text: String, named: Bool) -> some View {
        HStack(spacing: 6) {
            if named {
                Text(presence.kind.displayName)
                    .font(.headline)
            }
            Text(text)
                .font(.headline)
                .fontWeight(named ? .regular : .semibold)
                .foregroundStyle(presence.needsAttention ? presence.tint : .primary)
        }
        .lineLimit(1)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: presence.systemImage)
                .font(.title2)
                .foregroundStyle(presence.tint)
                .frame(width: 28)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Shorten the words before truncating them, so a narrow column still reads.
                    ViewThatFits(in: .horizontal) {
                        headlineRow(headline, named: true)
                        headlineRow(shortHeadline, named: true)
                        headlineRow(shortHeadline, named: false)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    trailing
                }
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if expanded, let details {
                    expandedContent(details)
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
    }

    /// The clock, the step count, and small buttons for the agent's app, the summary and collapsing.
    private var trailing: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // One line, so the detail below sits right under the headline.
            HStack(spacing: 0) {
                Text(presence.timing(now: now))
                    .foregroundStyle(.secondary)
                    .help(presence.timingHelp)
                if presence.source == .hooks, presence.toolCallsThisTurn > 0 {
                    Text(" · " + (presence.toolCallsThisTurn == 1 ? "1 step" : "\(presence.toolCallsThisTurn) steps"))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout.monospacedDigit())
            .fixedSize()
            if let details {
                HStack(spacing: 6) {
                    if details.canGoToAgent {
                        Button(action: details.onGoToAgent) {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .help("Go to agent: bring the app it runs in to the front")
                        .accessibilityLabel("Go to agent")
                    }
                    Button(action: details.onSummary) {
                        Image(systemName: "doc.text")
                    }
                    .help("Session summary (⇧⌘E)")
                    .accessibilityLabel("Session summary")
                    Button(action: details.onToggle) {
                        Image(systemName: details.expanded ? "chevron.up" : "chevron.down")
                    }
                    .help(details.expanded ? "Show less" : "Show the task, recent steps and files")
                    .accessibilityLabel(details.expanded ? "Show less" : "Show details")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func expandedContent(_ details: AgentBannerDetails) -> some View {
        if let task = presence.task, !task.isEmpty {
            Label {
                Text(task)
                    .lineLimit(2)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: "text.bubble")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        let steps = Array(presence.turnSteps.suffix(3).reversed())
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(steps) { step in
                    StepLine(step: step, target: step.summary.map(shorten), now: now, waiting: step.id == presence.awaitingCallID)
                }
            }
            .padding(.top, 1)
        }
        if !details.files.isEmpty {
            FileChips(files: details.files, onOpen: details.onOpenFile)
                .padding(.top, 1)
        }
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
    @State private var hermesUnapproved = HermesHookInstaller.unapprovedEvents()
    @State private var recipe: AgentHookRecipe = .codex
    @State private var otherAgentName = AgentHookRecipe.other.agentName

    private static let hermesApproveCommand = "hermes --accept-hooks"

    private var hermesAwaitingApproval: Bool { hermesState == .installed && !hermesUnapproved.isEmpty }

    private var hermesStatusText: String {
        switch hermesState {
        case .notPresent: "Hermes not found"
        case .notInstalled: "Not installed"
        case .installed:
            hermesUnapproved.isEmpty ? "Installed and approved"
                : "Installed, \(hermesUnapproved.count) of \(HermesHookParser.subscribedEvents.count) waiting for approval in Hermes"
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
                LabeledContent("Events received", value: "\(hub.eventsReceived)" + (hub.lastEventAt.map { " · last \(Format.relative($0, to: model.now))" } ?? ""))
                heardFrom
            } header: {
                Text("Hooks")
            } footer: {
                Text("Hooks are commands an agent runs whenever something happens: a prompt, a tool call, a permission request. Vigil's post each event to its local socket, so it knows what the agent is doing. Vigil installs them for Claude Code and Hermes with one click; any other agent takes a setup you paste into its own settings (see Other agents).")
            }
            Section {
                LabeledContent("Hooks") {
                    Text(hooksInstalled ? "Installed" : "Not installed")
                        .foregroundStyle(hooksInstalled ? .green : .secondary)
                }
                HStack {
                    Button("Install Hooks…") { confirmInstall = true }
                        .help("Add Vigil's hooks to ~/.claude/settings.json. A backup is saved first and your own hooks are kept.")
                        .disabled(hooksInstalled)
                    Button("Uninstall Hooks…") { confirmUninstall = true }
                        .help("Remove only Vigil's hooks from ~/.claude/settings.json. A backup is saved first.")
                        .disabled(!hooksInstalled)
                    Spacer()
                    Button("Reveal settings.json") {
                        NSWorkspace.shared.activateFileViewerSelecting([HookInstaller.settingsURL])
                    }
                    .help("Show Claude Code's settings file in Finder")
                }
                if let lastMessage {
                    Text(lastMessage).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("Hooks let Claude Code tell Vigil exactly what it is doing: when a turn starts and ends, every tool call, and when it needs your permission or asks you a question. Installing adds entries to ~/.claude/settings.json that post each event to Vigil's local socket with curl; a backup is saved first and your other hooks are left untouched. If Vigil is not running the command fails silently in under a second.")
            }
            if hermesState != .notPresent {
                Section {
                    LabeledContent("Hooks") {
                        Text(hermesStatusText)
                            .foregroundStyle(hermesAwaitingApproval ? .orange : hermesState == .installed ? .green : .secondary)
                    }
                    if hermesAwaitingApproval {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Hermes runs a hook only after you approve it, and its gateway cannot ask, so until then it skips Vigil's hooks without a word. Run this once in Terminal, quit with /exit, then open a new Hermes session:")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Text(Self.hermesApproveCommand)
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                                Spacer()
                                Button("Copy") { Workspace.copy(Self.hermesApproveCommand) }
                                    .help("Copy the command that approves Vigil's hooks in Hermes")
                                Button("Check Again") { refreshHermes() }
                                    .help("Read Hermes's hook approvals again")
                            }
                            Text("Or run plain hermes and approve each hook when it asks. --accept-hooks approves every hook in config.yaml, so look there first if you have hooks of your own.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack {
                        Button("Install Hermes Hooks…") { confirmHermesInstall = true }
                            .help("Write Vigil's hook script and add its hooks to ~/.hermes/config.yaml. A backup is saved first.")
                            .disabled(hermesState == .installed)
                        Button("Uninstall Hermes Hooks…") { confirmHermesUninstall = true }
                            .help("Remove Vigil's hook script and its block from ~/.hermes/config.yaml. A backup is saved first.")
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
                    Text((hermesState == .manualMergeNeeded
                         ? "Your config.yaml already has a hooks: block, so Vigil will not edit it. Install writes the script to ~/.hermes/agent-hooks/vigil.sh; then paste the copied YAML entries under your existing hooks: key."
                         : "Install writes a small script to ~/.hermes/agent-hooks/vigil.sh and appends a delimited hooks: block to ~/.hermes/config.yaml (backup first). Hermes then needs you to approve the hooks once from a terminal; sessions opened after that report to Vigil.")
                         + " Hermes gets an installer of its own because it runs hooks without a shell, which needs the script, and skips any you have not approved; this section shows which are still waiting.")
                }
                .onAppear { refreshHermes() }
            }
            otherAgents
            Section {
                Toggle("Detect agent processes", isOn: settings.agentScanEnabled)
                    .help("Look for agent processes in your worktrees, so an agent shows even without hooks")
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
                .help("Which of an agent's tool calls get their own entry in the activity feed")
            }
            Section("Notifications") {
                Toggle("When an agent needs permission or asks a question", isOn: settings.notifyOnAgentPermission)
                    .help("Post a notification when an agent is waiting on you")
                Toggle("When an agent finishes a turn", isOn: settings.notifyOnAgentTurnFinished)
                    .help("Post a notification when an agent finishes its turn and is ready for your next prompt")
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

    /// Every agent that has reported since launch, so you can see a setup work.
    @ViewBuilder private var heardFrom: some View {
        let contacts = model.agentHub.contacts.values.sorted { $0.lastEventAt > $1.lastEventAt }
        if contacts.isEmpty {
            LabeledContent("Heard from") {
                Text("No agent since Vigil started").foregroundStyle(.secondary)
            }
        }
        ForEach(contacts) { contact in
            LabeledContent(contact.agent.displayName) {
                Text("\(contact.events == 1 ? "1 event" : "\(contact.events) events") · last \(Format.relative(contact.lastEventAt, to: model.now))")
                    .foregroundStyle(.secondary)
            }
            .help(contact.lastWorktree.map { "Last event: \(contact.lastEvent), in \(($0 as NSString).lastPathComponent)" }
                  ?? "Last event: \(contact.lastEvent), not in a worktree Vigil watches")
        }
    }

    /// The setup to copy into another agent's settings.
    @ViewBuilder private var otherAgents: some View {
        let setup = recipe.setup(socketPath: model.agentHub.socketPath, agent: recipe == .other ? otherAgentName : nil)
        Section {
            Picker("Set up", selection: $recipe) {
                ForEach(AgentHookRecipe.allCases) { Text($0.title).tag($0) }
            }
            .help("Which agent to show the hook setup for")
            if recipe == .other {
                TextField("Agent name", text: $otherAgentName, prompt: Text(AgentHookRecipe.other.agentName))
                    .help("The name Vigil shows for this agent")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(recipe.file.map { "Add this to \($0):" } ?? "Have the agent's hooks run:")
                    .font(.callout)
                ScrollView {
                    Text(setup)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(height: recipe == .other ? 54 : 150)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                Text(recipe.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(recipe == .other ? "Copy Command" : "Copy Setup") { Workspace.copy(setup) }
                    .help(recipe.file.map { "Copy the hooks to add to \($0)" } ?? "Copy the command for the agent's hooks to run")
                Spacer()
                if let file = recipe.file {
                    let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
                    Button("Reveal File") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .help("Show \(file) in Finder")
                        .disabled(!FileManager.default.fileExists(atPath: url.path))
                }
            }
        } header: {
            Text("Other agents")
        } footer: {
            Text("Any agent that can run a command when something happens can report to Vigil. Add the setup to the agent's own settings: Vigil works out which agent sent each event and understands its event names. Vigil never edits these files, so remove the entries yourself to stop.")
        }
    }

    private func installHermes() {
        do {
            if let backup = try HermesHookInstaller.install(socketPath: model.agentHub.socketPath) {
                hermesMessage = "Installed. Backup: \(backup.lastPathComponent). Approve the hooks in Hermes next (see above)."
            } else {
                Workspace.copy(HermesHookInstaller.snippet)
                hermesMessage = "Script written. Your config.yaml already has a hooks: key, so the YAML entries were copied to the clipboard; paste them under it."
            }
            refreshHermes()
        } catch {
            hermesMessage = "Install failed: \(error.localizedDescription)"
        }
    }

    private func refreshHermes() {
        hermesState = HermesHookInstaller.state()
        hermesUnapproved = HermesHookInstaller.unapprovedEvents()
    }

    private func uninstallHermes() {
        do {
            let backup = try HermesHookInstaller.uninstall()
            refreshHermes()
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
