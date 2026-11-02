import SwiftUI
import MimamoriCore

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

    /// The tint for the worktree as a whole: orange while agents there collide.
    var alertTint: Color { collision != nil ? .orange : tint }

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

    /// The state the desktop widgets name it by.
    var widgetState: AgentWidgetSnapshot.State {
        switch (source, activity) {
        case (.process, _): .running
        case (.hooks, .needsPermission), (.hooks, .askedQuestion): .needsYou
        case (.hooks, .working): .working
        case (.hooks, .ready): .ready
        case (.hooks, .idle): .ended
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
        if collision != nil { return 0 }
        return switch (source, activity) {
        case (.hooks, .needsPermission), (.hooks, .askedQuestion): 0
        case (.hooks, .working): 1
        case (.process, _): isBusy ? 1 : 2
        case (.hooks, .ready): 2
        case (.hooks, .idle): 3
        }
    }
}

extension View {
    /// An agent's card, as the banner above the diff and the Agents window draw it: a soft wash
    /// and an edge in the colour of its state, stronger while it needs you.
    func agentCard(_ presence: AgentPresence, highlighted: Bool = false) -> some View {
        let strong = presence.needsAttention
        return background(presence.alertTint.opacity((strong ? 0.16 : 0.09) + (highlighted ? 0.05 : 0)),
                          in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(presence.alertTint.opacity(strong ? 0.5 : 0.2), lineWidth: 1)
            }
    }
}

/// An agent at a glance: its own glyph in the colour of its state, with a hand when it is
/// waiting on you and a triangle when it is colliding with another agent. The glyph says who,
/// the colour how it is doing.
struct AgentGlyph: View {
    let symbol: String
    let tint: Color
    var waiting = false
    var colliding = false

    init(symbol: String, tint: Color, waiting: Bool = false, colliding: Bool = false) {
        self.symbol = symbol
        self.tint = tint
        self.waiting = waiting
        self.colliding = colliding
    }

    init(presence: AgentPresence) {
        self.init(symbol: presence.kind.symbolName, tint: presence.tint,
                  waiting: presence.source == .hooks && presence.activity.needsAttention,
                  colliding: presence.collision != nil)
    }

    private var mark: String? {
        colliding ? "exclamationmark.triangle.fill" : waiting ? "hand.raised.fill" : nil
    }

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
            .overlay(alignment: .bottomTrailing) {
                if let mark {
                    Image(systemName: mark)
                        .foregroundStyle(.orange)
                        .scaleEffect(0.6, anchor: .bottomTrailing)
                        .offset(x: 3, y: 2)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The widget's badge for an agent: its glyph in a disc the colour of its state, with a hand
/// while it waits on you and a triangle while it collides with another agent.
struct AgentBadge: View {
    let presence: AgentPresence
    var size: CGFloat = 28

    var body: some View {
        StateBadge(state: presence.widgetState, symbol: presence.kind.symbolName, collision: presence.collision != nil,
                   size: size, tint: presence.tint)
            .accessibilityHidden(true)
    }
}

/// "Waiting 2:03" in a capsule the colour of the agent's state.
struct AgentTimerPill: View {
    let presence: AgentPresence
    let now: Date

    var body: some View {
        let text = presence.timing(now: now)
        Text(text.prefix(1).uppercased() + text.dropFirst())
            .font(.callout.weight(.medium).monospacedDigit())
            .foregroundStyle(presence.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(presence.tint.opacity(0.16), in: Capsule())
            .fixedSize()
            .help(presence.timingHelp)
    }
}

/// A small colored dot plus agent name, for sidebar rows.
struct AgentPresenceBadge: View {
    let presence: AgentPresence

    var body: some View {
        // The row's badge says which agent; this says what it is doing, so it stays short.
        Text(summary)
            .font(.caption)
            .foregroundStyle(presence.needsAttention ? presence.alertTint : .secondary)
            .lineLimit(1)
            .help(help)
    }

    private var help: String {
        var lines = ([presence] + presence.others).map { $0.kind.displayName + " · " + $0.statusText }
        if let collision = presence.collision { lines.append(collision.title) }
        return lines.joined(separator: "\n")
    }

    private var summary: String {
        guard presence.others.isEmpty else {
            return "\(presence.agentCount) agents · " + (presence.collision != nil ? "same files" : single.lowercased())
        }
        return single
    }

    private var single: String {
        switch (presence.source, presence.activity) {
        case (.hooks, .working(let tool, _)): tool.map { "Working · \($0)" } ?? "Working"
        case (.hooks, .needsPermission): "Needs permission"
        case (.hooks, .askedQuestion): "Has a question"
        case (.hooks, .ready): "Ready"
        case (.hooks, .idle): "Ended"
        case (.process, _): presence.isBusy ? "Busy" : "Running"
        }
    }
}

/// The full status line shown in a worktree header.
struct AgentStatusLine: View {
    let presence: AgentPresence
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            AgentGlyph(presence: presence)
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
    var onDismissCollision: () -> Void = {}
    /// Offer the button that shows more or less; off where the banner is always shown in full.
    var canToggle = true
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

    /// "Codex Needs permission": one text, so in the narrowest column it wraps rather than truncating.
    private func headlineText(_ text: String) -> some View {
        let state = Text(text)
            .fontWeight(.regular)
            .foregroundStyle(presence.needsAttention ? presence.tint : .primary)
        return Text("\(Text(presence.kind.displayName))\u{2002}\(state)")
            .font(.headline)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Across the whole banner: it is about every agent here, not the one below.
            if let collision = presence.collision {
                AgentCollisionNote(collision: collision, worktree: details?.worktree, onDismiss: details?.onDismissCollision)
                Divider()
            }
            agentBody
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .agentCard(presence)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .help(presence.source == .hooks ? "Reported by the agent's hooks" : "An agent process has this worktree as its working directory. Install hooks for live status.")
    }

    private var agentBody: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentBadge(presence: presence, size: 30)
                .padding(.top, -3)
            VStack(alignment: .leading, spacing: 4) {
                // One row while the headline fits beside the clock and buttons, in full or in
                // shorter words. Narrower than that, the clock and buttons move to a row of their
                // own and the headline gets the whole width: it never shrinks to "…".
                ViewThatFits(in: .horizontal) {
                    oneRow(headline)
                    oneRow(shortHeadline)
                    VStack(alignment: .leading, spacing: 4) {
                        ViewThatFits(in: .horizontal) {
                            headlineText(headline).lineLimit(1)
                            headlineText(shortHeadline).lineLimit(1)
                            headlineText(shortHeadline).lineLimit(2)
                        }
                        // Narrower still, the step count goes, then the buttons move below the
                        // clock: what the banner cannot fit, the window would widen to hold.
                        ViewThatFits(in: .horizontal) {
                            clockRow(steps: true)
                            clockRow(steps: false)
                            VStack(alignment: .leading, spacing: 4) {
                                timing(steps: false)
                                buttons
                            }
                        }
                    }
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
                if !presence.others.isEmpty {
                    OtherAgentsList(others: presence.others, now: now, worktree: details?.worktree)
                        .padding(.top, 4)
                }
            }
        }
    }

    /// The headline, then the clock and buttons on the right.
    private func oneRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            headlineText(text).lineLimit(1)
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                timing()
                buttons
            }
        }
    }

    /// The clock, then the buttons on the right.
    private func clockRow(steps: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            timing(steps: steps)
            Spacer(minLength: 8)
            buttons
        }
    }

    /// The clock and the step count, on one line.
    private func timing(steps: Bool = true) -> some View {
        HStack(spacing: 0) {
            Text(presence.timing(now: now))
                .foregroundStyle(.secondary)
                .help(presence.timingHelp)
            if steps, presence.source == .hooks, presence.toolCallsThisTurn > 0 {
                Text(" · " + (presence.toolCallsThisTurn == 1 ? "1 step" : "\(presence.toolCallsThisTurn) steps"))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout.monospacedDigit())
        .fixedSize()
    }

    /// Small buttons for the agent's app, the summary and collapsing.
    @ViewBuilder
    private var buttons: some View {
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
                if details.canToggle {
                    Button(action: details.onToggle) {
                        Image(systemName: details.expanded ? "chevron.up" : "chevron.down")
                    }
                    .help(details.expanded ? "Show less" : "Show the task, recent steps and files")
                    .accessibilityLabel(details.expanded ? "Show less" : "Show details")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
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

extension AgentCollision {
    /// "Claude Code and Codex both edited App.swift", "… both edited 4 files".
    var title: String {
        let names = files.map { ($0 as NSString).lastPathComponent }
        let what = switch names.count {
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: "\(names.count) files"
        }
        return agents.hasPrefix("Two ") || agents.hasPrefix("Three ") || agents.first?.isNumber == true
            ? "\(agents) edited \(what)" : "\(agents) both edited \(what)"
    }
}

/// The warning that agents sharing a worktree edited the same files.
struct AgentCollisionNote: View {
    let collision: AgentCollision
    var worktree: String? = nil
    var onDismiss: (() -> Void)? = nil

    private var files: String {
        collision.files.prefix(4).map { path in
            worktree.map { path.hasPrefix($0 + "/") ? String(path.dropFirst($0.count + 1)) : path } ?? path
        }.joined(separator: ", ") + (collision.files.count > 4 ? ", …" : "")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Warning")
                warning
            }
            // Read as one warning; Dismiss stays a button of its own.
            .accessibilityElement(children: .combine)
            Spacer(minLength: 6)
            if let onDismiss {
                Button("Dismiss", action: onDismiss)
                    .controlSize(.small)
                    .help("Hide this warning until the agents edit another file in common")
            }
        }
        .font(.callout)
    }

    private var warning: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(collision.title)
                .fontWeight(.semibold)
                .foregroundStyle(.orange)
            if collision.files.count > 2 {
                Text(files)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // A line limit, not a fixed size: measured at a narrow width, a fixed-size text grows
            // tall enough to push the whole window's content out of view.
            Text("Agents in one folder can undo each other's work. Stop one, or give it a worktree of its own.")
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }
}

/// The other agents in a worktree, a line each, under "Also here".
struct OtherAgentsList: View {
    let others: [AgentPresence]
    let now: Date
    var worktree: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Also here")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(others.enumerated()), id: \.offset) { _, other in
                OtherAgentLine(presence: other, now: now, worktree: worktree)
            }
        }
    }
}

/// One more agent in the worktree, in a single line, with a way to reach it.
struct OtherAgentLine: View {
    let presence: AgentPresence
    let now: Date
    var worktree: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            AgentGlyph(presence: presence)
                .frame(width: 14)
            Text(presence.kind.displayName)
                .fontWeight(.medium)
            Text("·").foregroundStyle(.tertiary)
            Text(worktree.map { AgentText.shortenPaths(presence.statusText, in: $0) } ?? presence.statusText)
                .foregroundStyle(presence.needsAttention ? presence.tint : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(presence.timing(now: now))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .fixedSize()
                .help(presence.timingHelp)
            if AgentApps.canGo(to: presence) {
                Button {
                    AgentApps.bringForward(presence)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Go to \(presence.kind.displayName): bring the app it runs in to the front")
                .accessibilityLabel("Go to \(presence.kind.displayName)")
            }
        }
        .font(.callout)
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

/// One request to the hook socket in Settings: what it was, when, and what became of it.
struct HookLogRow: View {
    let entry: HookLogEntry
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    private var tint: Color {
        switch entry.outcome {
        case .placed: .secondary
        case .test: .green
        case .unplaced: .orange
        case .rejected: .red
        }
    }

    /// A placed event names just its worktree's folder; the whole path is in the tooltip.
    private var detail: String {
        if case .placed(let worktree) = entry.outcome { return "→ " + (worktree as NSString).lastPathComponent }
        return entry.detail(home: Self.home)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(entry.at.formatted(.dateTime.hour().minute().second()))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(tint)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .help(entry.detail(home: Self.home))
        .accessibilityElement(children: .combine)
    }
}

/// The parts of Settings › Agents, each a pane of its own.
enum AgentSettingsSection: String, CaseIterable, Identifiable {
    case hooks
    case otherAgents = "other"
    case feedAndWidgets = "widgets"
    case notifications

    var id: Self { self }

    var title: String {
        switch self {
        case .hooks: "Hooks"
        case .otherAgents: "Other Agents"
        case .feedAndWidgets: "Feed & Widgets"
        case .notifications: "Notifications"
        }
    }
}

/// Settings tab: hooks, other agents and detection, the feed and widgets, and notifications,
/// each on a pane of its own.
struct AgentSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var section: AgentSettingsSection = .hooks
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
    @State private var testing = false
    @State private var testResult: AgentHub.HookTestResult?
    @State private var diagnosticsCopied = false
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
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(AgentSettingsSection.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)
            .padding(.bottom, 2)
            Form {
                switch section {
                case .hooks: hooks
                case .otherAgents:
                    otherAgents
                    detection
                case .feedAndWidgets: feedAndWidgets
                case .notifications: notifications
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Install Mimamori's hooks into ~/.claude/settings.json?", isPresented: $confirmInstall) {
            Button("Install") { install() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A backup of the file is saved first. Existing hooks are kept. New Claude Code sessions will report to Mimamori; sessions already running pick the change up on their next start.")
        }
        .confirmationDialog("Remove Mimamori's hooks from ~/.claude/settings.json?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) { uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the entries that post to Mimamori's socket are removed. A backup is saved first.")
        }
        .confirmationDialog("Install Mimamori's hooks for Hermes?", isPresented: $confirmHermesInstall) {
            Button("Install") { installHermes() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Writes ~/.hermes/agent-hooks/mimamori.sh and appends a delimited hooks: block to ~/.hermes/config.yaml after saving a backup. Nothing else in the file is touched.")
        }
        .confirmationDialog("Remove Mimamori's hooks for Hermes?", isPresented: $confirmHermesUninstall) {
            Button("Uninstall", role: .destructive) { uninstallHermes() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the script and Mimamori's delimited block from config.yaml after saving a backup.")
        }
        .onAppear {
            // MIMAMORI_DEBUG_FLAGS=agents:<section>: open on that section (with settings:agents).
            if let wanted = AgentSettingsSection.allCases.first(where: { model.debugFlags.contains("agents:" + $0.rawValue) }) {
                section = wanted
            }
        }
    }

    /// The hook socket, who has reported, and the one-click installers.
    @ViewBuilder private var hooks: some View {
        let hub = model.agentHub
        Section {
            LabeledContent("Socket") {
                HStack(spacing: 6) {
                    Circle().fill(hub.isListening ? .green : .red).frame(width: 8, height: 8)
                    Text(hub.isListening ? "listening" : (hub.socketError ?? "not listening"))
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Events received", value: "\(hub.eventsReceived)"
                           + (hub.eventsUnmatched > 0 ? " · \(hub.eventsUnmatched) not placed" : "")
                           + (hub.lastEventAt.map { " · last \(Format.relative($0, to: model.now))" } ?? ""))
            heardFrom
            HStack(spacing: 8) {
                Button("Send Test Event") { sendTestEvent() }
                    .help("Run the hook command Mimamori installs with a test event, as an agent would, and see whether it arrives")
                    .disabled(testing)
                if testing {
                    ProgressView().controlSize(.small)
                } else if let testResult {
                    testResultLabel(testResult)
                }
                Spacer()
                Button(diagnosticsCopied ? "Copied" : "Copy Diagnostics") {
                    model.copyDiagnostics()
                    diagnosticsCopied = true
                    Task { try? await Task.sleep(for: .seconds(2)); diagnosticsCopied = false }
                }
                .help("Copy a report for a bug report: versions, the socket, which hooks are installed, who reported and the recent events. Folders under your home show as ~; no prompts or code are included.")
            }
        } header: {
            Text("Status")
        } footer: {
            Text("Hooks are commands an agent runs whenever something happens: a prompt, a tool call, a permission request. Mimamori's post each event to its local socket, so it knows what the agent is doing. Mimamori installs them for Claude Code and Hermes with one click; any other agent takes a setup you paste into its own settings (see Other Agents).")
        }
        newRepositories
        Section {
            LabeledContent("Hooks") {
                Text(hooksInstalled ? "Installed" : "Not installed")
                    .foregroundStyle(hooksInstalled ? .green : .secondary)
            }
            HStack {
                Button("Install Hooks…") { confirmInstall = true }
                    .help("Add Mimamori's hooks to ~/.claude/settings.json. A backup is saved first and your own hooks are kept.")
                    .disabled(hooksInstalled)
                Button("Uninstall Hooks…") { confirmUninstall = true }
                    .help("Remove only Mimamori's hooks from ~/.claude/settings.json. A backup is saved first.")
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
            Text("Hooks let Claude Code tell Mimamori exactly what it is doing: when a turn starts and ends, every tool call, and when it needs your permission or asks you a question. Installing adds entries to ~/.claude/settings.json that post each event to Mimamori's local socket with curl; a backup is saved first and your other hooks are left untouched. If Mimamori is not running the command fails silently in under a second.")
        }
        if hermesState != .notPresent {
            Section {
                LabeledContent("Hooks") {
                    Text(hermesStatusText)
                        .foregroundStyle(hermesAwaitingApproval ? .orange : hermesState == .installed ? .green : .secondary)
                }
                if hermesAwaitingApproval {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Hermes runs a hook only after you approve it, and its gateway cannot ask, so until then it skips Mimamori's hooks without a word. Run this once in Terminal, quit with /exit, then open a new Hermes session:")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Text(Self.hermesApproveCommand)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                            Button("Copy") { Workspace.copy(Self.hermesApproveCommand) }
                                .help("Copy the command that approves Mimamori's hooks in Hermes")
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
                        .help("Write Mimamori's hook script and add its hooks to ~/.hermes/config.yaml. A backup is saved first.")
                        .disabled(hermesState == .installed)
                    Button("Uninstall Hermes Hooks…") { confirmHermesUninstall = true }
                        .help("Remove Mimamori's hook script and its block from ~/.hermes/config.yaml. A backup is saved first.")
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
                     ? "Your config.yaml already has a hooks: block, so Mimamori will not edit it. Install writes the script to ~/.hermes/agent-hooks/mimamori.sh; then paste the copied YAML entries under your existing hooks: key."
                     : "Install writes a small script to ~/.hermes/agent-hooks/mimamori.sh and appends a delimited hooks: block to ~/.hermes/config.yaml (backup first). Hermes then needs you to approve the hooks once from a terminal; sessions opened after that report to Mimamori.")
                     + " Hermes gets an installer of its own because it runs hooks without a shell, which needs the script, and skips any you have not approved; this section shows which are still waiting.")
            }
            .onAppear { refreshHermes() }
        }
        recentEvents
    }

    /// For your CLAUDE.md or AGENTS.md: an agent that starts a project adds it to Mimamori.
    static let newRepositoryInstruction = "When you create a new git repository, run `open -g -a Mimamori \"<path>\"` so Mimamori watches it."

    /// What happens when an agent works in a repository Mimamori does not watch, and how agents
    /// can add one they create.
    @ViewBuilder private var newRepositories: some View {
        let settings = SettingsBinding.make(model)
        let ignored = model.settings.ignoredAgentRepositories
        Section {
            Picker("When an agent works in an unwatched repository", selection: settings.agentRepositoryPolicy) {
                ForEach(AgentRepositoryPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .help("Offer to watch it asks in the sidebar and in a notification; Watch it adds it straight away")
            ForEach(model.repositoryOffers) { RepositoryOfferRow(offer: $0) }
            if !ignored.isEmpty {
                LabeledContent("Not offered again") {
                    HStack {
                        Text(ignored.count == 1 ? "1 repository" : "\(ignored.count) repositories")
                            .foregroundStyle(.secondary)
                            .help(ignored.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n"))
                        Button("Forget") {
                            var copy = model.settings
                            copy.ignoredAgentRepositories = []
                            model.updateSettings(copy)
                        }
                        .help("Offer these repositories again when an agent works in them")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("An agent can add a repository it creates. Put this in your CLAUDE.md or AGENTS.md:")
                    .font(.callout)
                HStack(alignment: .top) {
                    Text(Self.newRepositoryInstruction)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Copy") { Workspace.copy(Self.newRepositoryInstruction) }
                        .help("Copy the instruction for your agents")
                }
            }
        } header: {
            Text("New Repositories")
        } footer: {
            Text("Mimamori only offers git repositories, never your home folder, temporary folders or the dot folders agents keep in your home. A new worktree of a repository you watch is found at once. You can also add a repository by dropping its folder on Mimamori's Dock icon or sidebar, or with open -a Mimamori <folder>.")
        }
    }

    /// The latest requests to the socket and what became of each.
    @ViewBuilder private var recentEvents: some View {
        let log = model.agentHub.hookLog
        Section {
            if log.isEmpty {
                Text("Nothing has reached the socket since Mimamori started.")
                    .foregroundStyle(.secondary)
            }
            ForEach(log.prefix(50)) { entry in
                HookLogRow(entry: entry)
            }
        } header: {
            Text("Recent Events")
        } footer: {
            Text("The latest requests to Mimamori's socket, newest first. Not placed: no watched worktree holds the folder the agent works in, so add its repository; an event with a session waits until a later one says where the session works. Rejected: a hook sent the wrong address or shape, so compare its setup with Other Agents. Nothing at all: the agent's hooks are not running, so check they are installed and start a new session, since agents read their hooks when a session starts.")
        }
    }

    @ViewBuilder private func testResultLabel(_ result: AgentHub.HookTestResult) -> some View {
        switch result {
        case .arrived(let milliseconds):
            Label("Arrived in \(milliseconds) ms", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .noAnswer(let reason):
            Label(reason, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sendTestEvent() {
        testing = true
        testResult = nil
        Task {
            testResult = await model.agentHub.sendTestEvent()
            testing = false
        }
    }

    /// Agents seen from their processes, for those without hooks.
    @ViewBuilder private var detection: some View {
        let settings = SettingsBinding.make(model)
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
            Text("Without hooks, Mimamori still shows which worktrees have an agent process running in them (Claude Code, Codex, Aider, Cursor, Gemini, Goose, OpenCode, Amp). Add other executable names, comma separated, and press Return.")
        }
    }

    @ViewBuilder private var feedAndWidgets: some View {
        let settings = SettingsBinding.make(model)
        Section("Activity feed") {
            Picker("Show tool calls", selection: settings.agentToolCallsInFeed) {
                ForEach(AgentToolCallFeedMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .help("Which of an agent's tool calls get their own entry in the activity feed")
        }
        Section {
            Toggle("Show tasks and steps in widgets", isOn: settings.showTasksInWidgets)
                .help("Let desktop widgets show each agent's task and latest steps. Anyone who can see your screen can read them.")
        } header: {
            Text("Desktop widgets")
        } footer: {
            Text("Add the Agents widget from the desktop's Edit Widgets menu. Each widget can also be set to hide tasks, or to show only agents that need you.")
        }
    }

    @ViewBuilder private var notifications: some View {
        let settings = SettingsBinding.make(model)
        Section {
            Toggle("When an agent needs permission or asks a question", isOn: settings.notifyOnAgentPermission)
                .help("Post a notification when an agent is waiting on you")
            Toggle("When two agents edit the same files", isOn: settings.notifyOnAgentCollision)
                .help("Post a notification when agents working in one worktree edit the same file, which can undo each other's work")
            Toggle("When an agent finishes a turn", isOn: settings.notifyOnAgentTurnFinished)
                .help("Post a notification when an agent finishes its turn and is ready for your next prompt")
            if !model.isNotifierAvailable {
                Text("Notifications work when Mimamori runs from an app bundle.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Every agent that has reported since launch, so you can see a setup work.
    @ViewBuilder private var heardFrom: some View {
        let contacts = model.agentHub.contacts.values.sorted { $0.lastEventAt > $1.lastEventAt }
        if contacts.isEmpty {
            LabeledContent("Heard from") {
                Text("No agent since Mimamori started").foregroundStyle(.secondary)
            }
        }
        ForEach(contacts) { contact in
            LabeledContent(contact.agent.displayName) {
                Text("\(contact.events == 1 ? "1 event" : "\(contact.events) events") · last \(Format.relative(contact.lastEventAt, to: model.now))")
                    .foregroundStyle(.secondary)
            }
            .help(contact.lastWorktree.map { "Last event: \(contact.lastEvent), in \(($0 as NSString).lastPathComponent)" }
                  ?? "Last event: \(contact.lastEvent), not in a worktree Mimamori watches")
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
                    .help("The name Mimamori shows for this agent")
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
        } footer: {
            Text("Any agent that can run a command when something happens can report to Mimamori. Add the setup to the agent's own settings: Mimamori works out which agent sent each event and understands its event names. Mimamori never edits these files, so remove the entries yourself to stop.")
        }
    }

    private func installHermes() {
        do {
            if let backup = try HermesHookInstaller.install(socketPath: model.agentHub.socketPath) {
                hermesMessage = "Installed. Backup: \(backup.lastPathComponent). Approve the hooks in Hermes next (see above)."
                Log.hooks.notice("Installed Hermes's hooks; previous config saved to \(backup.path)")
            } else {
                Workspace.copy(HermesHookInstaller.snippet)
                hermesMessage = "Script written. Your config.yaml already has a hooks: key, so the YAML entries were copied to the clipboard; paste them under it."
            }
            refreshHermes()
        } catch {
            hermesMessage = "Install failed: \(error.localizedDescription)"
            Log.hooks.error("Could not install Hermes's hooks: \(error.localizedDescription, privacy: .public)")
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
            hermesMessage = backup.map { "Removed. Backup: \($0.lastPathComponent)" } ?? "Script removed. No Mimamori block was found in config.yaml."
            Log.hooks.notice("Removed Hermes's hooks")
        } catch {
            hermesMessage = "Uninstall failed: \(error.localizedDescription)"
            Log.hooks.error("Could not remove Hermes's hooks: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func install() {
        do {
            let backup = try HookInstaller.install(socketPath: model.agentHub.socketPath)
            hooksInstalled = HookInstaller.isInstalled()
            lastMessage = "Installed. Backup: \(backup.lastPathComponent)"
            Log.hooks.notice("Installed Claude Code's hooks; previous settings saved to \(backup.path)")
        } catch {
            lastMessage = "Install failed: \(error.localizedDescription)"
            Log.hooks.error("Could not install Claude Code's hooks: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func uninstall() {
        do {
            let backup = try HookInstaller.uninstall()
            hooksInstalled = HookInstaller.isInstalled()
            lastMessage = "Removed. Backup: \(backup.lastPathComponent)"
            Log.hooks.notice("Removed Claude Code's hooks")
        } catch {
            lastMessage = "Uninstall failed: \(error.localizedDescription)"
            Log.hooks.error("Could not remove Claude Code's hooks: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func commitNames() {
        var copy = model.settings
        copy.customAgentNames = customNames.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        model.updateSettings(copy)
    }
}
