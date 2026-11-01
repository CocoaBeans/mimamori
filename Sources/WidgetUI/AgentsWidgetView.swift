import SwiftUI
import VigilCore
import WidgetKit

// The Agents widget's views. Compiled into the widget extension and, for rendering previews
// headlessly (VIGIL_DEBUG_FLAGS=widgets), into the app built by Xcode.

/// What a widget instance is set to show (its configuration, in the extension).
struct AgentsWidgetOptions: Hashable, Sendable {
    var showDetails = true
    var onlyNeedsYou = false
}

extension AgentWidgetSnapshot.State {
    var tint: Color {
        switch self {
        case .needsYou: .orange
        case .working: .blue
        case .ready: .green
        case .running: .teal
        case .ended: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .needsYou: "hand.raised.fill"
        case .working: "sparkles"
        case .ready: "checkmark.bubble.fill"
        case .running: "terminal.fill"
        case .ended: "moon.zzz.fill"
        }
    }

    /// Said before the timer: "Waiting 2:03".
    var verb: String {
        switch self {
        case .needsYou: "Waiting"
        case .working: "Working"
        case .ready: "Ready"
        case .running: "Running"
        case .ended: "Ended"
        }
    }
}

/// The whole widget for one size.
struct AgentsWidgetView: View {
    let snapshot: AgentWidgetSnapshot?
    let family: WidgetFamily
    var options = AgentsWidgetOptions()
    var now = Date()

    private var agents: [AgentWidgetSnapshot.Agent] {
        let all = snapshot?.agents ?? []
        return options.onlyNeedsYou ? all.filter { $0.state == .needsYou || $0.collision != nil } : all
    }

    /// The color washing the background: the most pressing state shown.
    private var mood: Color {
        guard let snapshot, snapshot.isCurrent(at: now), let first = agents.first else { return .secondary }
        return first.collision != nil ? .orange : first.state.tint
    }

    var body: some View {
        content
            .containerBackground(for: .widget) {
                LinearGradient(colors: [mood.opacity(0.22), mood.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
    }

    @ViewBuilder private var content: some View {
        if let snapshot, snapshot.isCurrent(at: now) {
            if agents.isEmpty {
                QuietView(onlyNeedsYou: options.onlyNeedsYou, family: family)
            } else {
                switch family {
                case .systemSmall: SmallAgentView(agent: agents[0], more: agents.count - 1)
                case .systemMedium: AgentListView(snapshot: snapshot, agents: agents, limit: 3, detailed: false)
                case .systemLarge: AgentListView(snapshot: snapshot, agents: agents, limit: 4, detailed: options.showDetails)
                default: AgentGridView(snapshot: snapshot, agents: agents, limit: 8, detailed: options.showDetails)
                }
            }
        } else {
            NotRunningView(family: family)
        }
    }
}

// MARK: Pieces

/// The agent's state as a symbol in a tinted disc.
struct StateBadge: View {
    let state: AgentWidgetSnapshot.State
    var collision = false
    var size: CGFloat = 26

    var body: some View {
        let tint = collision ? Color.orange : state.tint
        Image(systemName: collision ? "exclamationmark.triangle.fill" : state.symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.18), in: Circle())
            .widgetAccentable()
    }
}

/// "Waiting 2:03": the state's verb and a timer that ticks without reloading the widget.
struct StateTimer: View {
    let agent: AgentWidgetSnapshot.Agent

    var body: some View {
        HStack(spacing: 3) {
            Text(agent.state.verb)
            Text(agent.since, style: .timer)
                .monospacedDigit()
        }
        .foregroundStyle(agent.state.tint)
    }
}

/// "1 needs you · 2 working", or how many agents there are.
struct SummaryLine: View {
    let snapshot: AgentWidgetSnapshot

    var body: some View {
        let parts = [snapshot.needingYou > 0 ? "\(snapshot.needingYou) need\(snapshot.needingYou == 1 ? "s" : "") you" : nil,
                     snapshot.working > 0 ? "\(snapshot.working) working" : nil].compactMap { $0 }
        Text(parts.isEmpty ? (snapshot.agents.count == 1 ? "1 agent" : "\(snapshot.agents.count) agents") : parts.joined(separator: " · "))
            .foregroundStyle(snapshot.needingYou > 0 ? Color.orange : Color.secondary)
    }
}

struct WidgetHeader: View {
    let snapshot: AgentWidgetSnapshot

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Agents", systemImage: "sparkles")
                .font(.headline)
                .widgetAccentable()
            Spacer()
            SummaryLine(snapshot: snapshot)
                .font(.caption.weight(.medium))
        }
    }
}

// MARK: Sizes

/// Small: the most pressing agent, big and plain.
struct SmallAgentView: View {
    let agent: AgentWidgetSnapshot.Agent
    let more: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                StateBadge(state: agent.state, collision: agent.collision != nil, size: 32)
                Spacer()
                if more > 0 {
                    Text("+\(more)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            Spacer(minLength: 2)
            Text(agent.worktree)
                .font(.headline)
                .lineLimit(1)
            Text("\(agent.agent) · \(agent.repository)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            StateTimer(agent: agent)
                .font(.caption.weight(.semibold))
                .padding(.top, 2)
        }
        .widgetURL(agent.link)
    }
}

/// One agent: who, where, what state, and optionally its task and latest steps.
struct AgentRowView: View {
    let agent: AgentWidgetSnapshot.Agent
    var detailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                StateBadge(state: agent.state, collision: agent.collision != nil, size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(agent.worktree)
                            .font(.subheadline.weight(.semibold))
                        if agent.others > 0 {
                            Text("+\(agent.others)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    Text("\(agent.agent) · \(agent.repository)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                StateTimer(agent: agent)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            if let collision = agent.collision {
                Label(collision, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .padding(.leading, 32)
            } else if detailed {
                details.padding(.leading, 32)
            }
        }
    }

    @ViewBuilder private var details: some View {
        if let task = agent.task, !task.isEmpty {
            Text(task)
                .font(.caption)
                .lineLimit(1)
        }
        ForEach(Array(agent.steps.prefix(2).enumerated()), id: \.offset) { _, step in
            HStack(spacing: 4) {
                Text(step.tool)
                    .fontWeight(.medium)
                if let target = step.target {
                    Text(target)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
            }
            .font(.system(.caption2, design: .monospaced))
            .lineLimit(1)
        }
    }
}

/// Medium and large: a header and a column of agents, each opening Vigil on its worktree.
struct AgentListView: View {
    let snapshot: AgentWidgetSnapshot
    let agents: [AgentWidgetSnapshot.Agent]
    let limit: Int
    let detailed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(snapshot: snapshot)
            ForEach(agents.prefix(limit)) { agent in
                Link(destination: agent.link) {
                    AgentRowView(agent: agent, detailed: detailed)
                }
            }
            Spacer(minLength: 0)
            if agents.count > limit {
                Text("and \(agents.count - limit) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Extra large: two columns.
struct AgentGridView: View {
    let snapshot: AgentWidgetSnapshot
    let agents: [AgentWidgetSnapshot.Agent]
    let limit: Int
    let detailed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(snapshot: snapshot)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18, alignment: .top), GridItem(.flexible(), spacing: 18, alignment: .top)],
                      alignment: .leading, spacing: 12) {
                ForEach(agents.prefix(limit)) { agent in
                    Link(destination: agent.link) {
                        AgentRowView(agent: agent, detailed: detailed)
                    }
                }
            }
            Spacer(minLength: 0)
            if agents.count > limit {
                Text("and \(agents.count - limit) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// No agent at work (or none needing you).
struct QuietView: View {
    let onlyNeedsYou: Bool
    let family: WidgetFamily

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: onlyNeedsYou ? "checkmark.circle.fill" : "moon.stars.fill")
                .font(family == .systemSmall ? .title : .largeTitle)
                .foregroundStyle(onlyNeedsYou ? .green : .secondary)
                .widgetAccentable()
            Text(onlyNeedsYou ? "Nobody needs you" : "No agents at work")
                .font(.headline)
            if family != .systemSmall {
                Text(onlyNeedsYou ? "Agents waiting on you show up here." : "Agents show up here while they run in a worktree Vigil watches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Vigil has quit, or has not written for a long while: the states would be stale.
struct NotRunningView: View {
    let family: WidgetFamily

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "eye.slash.fill")
                .font(family == .systemSmall ? .title : .largeTitle)
                .foregroundStyle(.secondary)
            Text("Vigil isn't running")
                .font(.headline)
            if family != .systemSmall {
                Text("Open Vigil to see your agents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(URL(string: "vigil://open"))
    }
}

extension AgentWidgetSnapshot {
    /// What the widget gallery shows before Vigil has written anything.
    static var sample: AgentWidgetSnapshot {
        let now = Date()
        return AgentWidgetSnapshot(writtenAt: now, agents: [
            .init(worktreePath: "/sample/plan", repository: "harbor", worktree: "plan", agent: "Codex", state: .needsYou,
                  status: "needs permission · Bash", since: now.addingTimeInterval(-74), task: "Plan the release",
                  steps: [.init(tool: "Bash", target: "rm -rf dist", running: true), .init(tool: "Edit", target: "PLAN.md")]),
            .init(worktreePath: "/sample/main", repository: "AcmeStore", worktree: "main", agent: "Claude Code", state: .working,
                  status: "working · Edit", since: now.addingTimeInterval(-312), task: "Tidy the onboarding screens",
                  steps: [.init(tool: "Edit", target: "Onboarding/Welcome.swift", running: true), .init(tool: "Bash", target: "swift test")]),
            .init(worktreePath: "/sample/docs", repository: "Vigil", worktree: "docs", agent: "Hermes", state: .ready,
                  status: "ready for your next prompt", since: now.addingTimeInterval(-900), task: "Summarise what we built",
                  steps: [.init(tool: "read_file", target: "README.md")]),
        ])
    }
}
