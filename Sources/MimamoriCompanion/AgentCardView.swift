import MimamoriShared
import SwiftUI

/// The Agents window's groups, in its order.
enum AgentGroup: Int, CaseIterable, Identifiable {
    case needsYou, working, ready, ended

    init(_ agent: AgentWidgetSnapshot.Agent) {
        switch agent.state {
        case .needsYou: self = .needsYou
        case .working, .running: self = .working
        case .ready: self = .ready
        case .ended: self = .ended
        }
    }

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .ready: "Ready"
        case .ended: "Ended"
        }
    }

    var tint: Color {
        switch self {
        case .needsYou: .orange
        case .working: .blue
        case .ready: .green
        case .ended: .secondary
        }
    }

    /// `agents` in their groups, keeping the Mac's order; empty groups left out.
    static func group(_ agents: [AgentWidgetSnapshot.Agent]) -> [(group: AgentGroup, agents: [AgentWidgetSnapshot.Agent])] {
        let byGroup = Dictionary(grouping: agents, by: AgentGroup.init)
        return allCases.compactMap { group in byGroup[group].map { (group, $0) } }
    }
}

/// An agent's card, as the Mac's Agents window draws it: compact, one line under its status, or
/// detailed, with its task, latest steps and the files it touched.
struct AgentCardView: View {
    let agent: AgentWidgetSnapshot.Agent
    let detailed: Bool
    let now: Date
    /// What this phone sent for the agent's permission request, if anything.
    var answer: AnswerState? = nil
    /// Allow (true) or Deny (false) for the agent's permission request.
    var onAnswer: ((Bool) -> Void)? = nil

    /// A working agent this long without a tool call is probably stuck, or thinking hard.
    private static let quietAfter: TimeInterval = 3 * 60

    private var card: AgentWidgetSnapshot.Card? { agent.card }

    /// The turn's tool calls along its time, up to now while it runs.
    private var timeline: TurnTimeline? {
        guard let card, card.reportsSteps else { return nil }
        // With no turn start known, the strip starts at the first step it has.
        let shown = card.turnStartedAt != nil ? card.turnUnderway || !card.calls.isEmpty : !card.calls.isEmpty
        guard shown else { return nil }
        return TurnTimeline(calls: card.calls, turnStartedAt: card.turnStartedAt, end: card.turnUnderway ? now : agent.since,
                            totalCalls: card.turnUnderway ? card.callsThisTurn : nil, waitingCallID: card.waitingCallID)
    }

    /// With details on, the step list names the running tool, so the status line need not.
    private var statusText: String {
        if detailed, agent.state == .working, card?.reportsSteps == true, card?.calls.isEmpty == false { return "working" }
        return agent.status
    }

    /// "4 steps", beside the timer while the agent works.
    private var steps: String? {
        guard detailed, agent.state == .working, let count = card?.callsThisTurn, count > 0 else { return nil }
        return count == 1 ? "1 step" : "\(count) steps"
    }

    /// "quiet 4m": how long a working agent has gone without a tool call, once that is a while.
    private func quiet(in timeline: TurnTimeline) -> String? {
        guard agent.state == .working, let quiet = timeline.quietFor, quiet >= Self.quietAfter else { return nil }
        return "quiet \(Format.duration(quiet))"
    }

    /// The last tool call, for an agent between turns, when the status line doesn't name it.
    private var lastCall: String? {
        guard agent.state != .working, agent.state != .needsYou, let call = card?.lastCall else { return nil }
        let target = call.summary.map { " " + $0 } ?? ""
        return "last: \(call.toolName)\(target), \(Format.relative(call.finishedAt ?? call.startedAt, to: now))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
                .accessibilityElement(children: .combine)
            // Outside the combined element, so VoiceOver reaches its buttons one by one.
            if let request = agent.permissionRequest, let onAnswer {
                PermissionRequestPanel(request: request, agent: agent.agent, answer: answer, onAnswer: onAnswer)
                    .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, detailed ? 10 : 8)
        .background(agent.state.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(agent.state.tint.opacity(0.22)))
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            StateBadge(state: agent.state, symbol: agent.symbol, collision: agent.collision != nil, size: 28)
            VStack(alignment: .leading, spacing: detailed ? 5 : 3) {
                header
                Text("\(agent.agent) · \(statusText)")
                    .font(.subheadline)
                    .foregroundStyle(agent.state == .needsYou ? agent.state.tint : .primary)
                    .lineLimit(2)
                if let timeline {
                    HStack(spacing: 8) {
                        TurnTimelineStrip(timeline: timeline)
                        if let quiet = quiet(in: timeline) {
                            Label(quiet, systemImage: "hourglass")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                    .padding(.vertical, 2)
                }
                if let collision = agent.collision {
                    Label(collision, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if detailed {
                    details
                } else {
                    compactFooter
                }
                if let others = card?.others, !others.isEmpty {
                    OtherAgents(others: others)
                }
            }
        }
    }

    /// The project and how long it has been at it, then the worktree on a line of its own: a
    /// phone is too narrow for both names beside the timer.
    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let color = agent.repositoryColor {
                    Circle()
                        .fill(color.color)
                        .frame(width: 9, height: 9)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                Text(agent.repository)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let steps {
                    Text(steps)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                StateTimer(agent: agent)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(agent.state.tint.opacity(0.16), in: Capsule())
                    .fixedSize()
            }
            HStack(spacing: 4) {
                Text(agent.worktree)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if agent.others > 0 {
                    Text("+\(agent.others)")
                        .font(.caption2.weight(.bold))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var compactFooter: some View {
        HStack(spacing: 8) {
            if let lastCall {
                Text(lastCall)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let count = card?.callsThisTurn, card?.reportsSteps == true, count > 0 {
                Text(count == 1 ? "1 tool call this turn" : "\(count) tool calls this turn")
            }
            Spacer(minLength: 6)
            if let changes = card?.changes { WorktreeChangeSummary(changes: changes) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var details: some View {
        if let task = agent.task, !task.isEmpty {
            Label {
                Text(task)
                    .lineLimit(2)
            } icon: {
                Image(systemName: "text.bubble")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        if let card {
            let steps = Array(card.calls.suffix(3).reversed())
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(steps) { step in
                        StepLine(step: step, target: step.summary, now: now, waiting: step.id == card.waitingCallID)
                    }
                }
                .padding(.top, 1)
            }
            if !card.files.isEmpty {
                TouchedFileChips(files: card.files)
            }
            HStack {
                Spacer(minLength: 6)
                WorktreeChangeSummary(changes: card.changes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }
}

/// The files touched this turn, flagged ones tinted, with their diffstat bars.
private struct TouchedFileChips: View {
    let files: [AgentWidgetSnapshot.Card.File]
    private static let limit = 6

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(files.prefix(Self.limit)) { file in
                HStack(spacing: 4) {
                    FileTypeIcon(path: file.path)
                        .imageScale(.small)
                    Text(file.name)
                    if let additions = file.additions, let deletions = file.deletions {
                        DiffBar(additions: additions, deletions: deletions, block: 5)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(file.flagged ? AnyShapeStyle(Color.orange.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                            in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(file.flagged ? Color.orange : Color.primary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(file.additions.map { "\(file.path), \($0) added, \(file.deletions ?? 0) removed" } ?? file.path)
            }
            if files.count > Self.limit {
                Text("+\(files.count - Self.limit) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            }
        }
    }
}

/// "9 changed · 4 to review" plus the flagged count, for the worktree.
private struct WorktreeChangeSummary: View {
    let changes: AgentWidgetSnapshot.Card.Changes

    var body: some View {
        HStack(spacing: 6) {
            if changes.files == 0 {
                Text("clean")
            } else {
                DiffBar(additions: changes.additions, deletions: changes.deletions)
                Text(changes.toReview < changes.files ? "\(changes.files) changed · \(changes.toReview) to review" : "\(changes.files) changed")
                if changes.flagged > 0 {
                    Label("\(changes.flagged)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .monospacedDigit()
        .fixedSize()
    }
}

/// The other agents in the worktree, one line each.
private struct OtherAgents: View {
    let others: [AgentWidgetSnapshot.Card.Other]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Also here")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(others.enumerated()), id: \.offset) { _, other in
                HStack(spacing: 6) {
                    Image(systemName: other.symbol ?? other.state.symbol)
                        .foregroundStyle(other.state.tint)
                        .frame(width: 14)
                    Text(other.agent)
                        .fontWeight(.medium)
                    Text("·").foregroundStyle(.tertiary)
                    Text(other.status)
                        .foregroundStyle(other.state == .needsYou ? other.state.tint : .secondary)
                        .lineLimit(1)
                }
                .font(.caption)
            }
        }
    }
}

/// "Needs you 2" on a tab of the group's colour; tap it to fold the group away.
struct AgentGroupHeader: View {
    let group: AgentGroup
    let agents: [AgentWidgetSnapshot.Agent]
    let collapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                Text("\(agents.count)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(group.tint.opacity(0.2), in: Capsule())
                Spacer(minLength: 6)
                if collapsed {
                    HStack(spacing: 3) {
                        ForEach(agents.prefix(8)) { agent in
                            StateBadge(state: agent.state, symbol: agent.symbol, collision: agent.collision != nil, size: 18)
                        }
                    }
                }
            }
            .foregroundStyle(group.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(group.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show these agents" : "Fold these agents away")
        .accessibilityLabel("\(group.title), \(agents.count == 1 ? "1 agent" : "\(agents.count) agents")")
        .accessibilityValue(collapsed ? "collapsed" : "expanded")
        .accessibilityAddTraits(.isHeader)
    }
}
