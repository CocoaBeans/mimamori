import ActivityKit
import MimamoriShared
import SwiftUI
import WidgetKit

// The iPhone companion's Live Activity: the agents on your Mac on the Lock Screen, in the Dynamic
// Island, and in an Apple Watch's Smart Stack. The app updates it as the Mac's snapshots arrive.

@main
struct MimamoriLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        AgentsLiveActivity()
    }
}

struct AgentsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentsActivityAttributes.self) { context in
            AgentsActivityView(macName: context.attributes.macName, state: context.state, isStale: context.isStale)
        } dynamicIsland: { context in
            let state = context.state
            let featured = state.featured
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    FeaturedBadge(state: state, size: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(featured?.worktree ?? context.attributes.macName)
                            .font(.headline)
                            .lineLimit(1)
                        if let featured {
                            AgentAndRepository(agent: featured)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let featured {
                        // The corner has room for the time alone; the badge's colour says the rest.
                        ActivityTimer(agent: featured, short: true)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .timerWidth()
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let featured {
                            Text(featured.task ?? featured.status)
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                        HStack {
                            MacLine(macName: context.attributes.macName, state: state, isStale: context.isStale)
                            Spacer(minLength: 6)
                            SummaryText(state: state)
                        }
                        .font(.caption)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                FeaturedBadge(state: state, size: 22)
            } compactTrailing: {
                CompactTrailing(state: state)
            } minimal: {
                FeaturedBadge(state: state, size: 22)
            }
            .keylineTint(featured?.state.tint ?? .secondary)
        }
        .supplementalActivityFamilies([.small])
    }
}

/// The Lock Screen's banner, or the Watch's and CarPlay's smaller one.
struct AgentsActivityView: View {
    @Environment(\.activityFamily) private var family
    let macName: String
    let state: AgentsActivityState
    let isStale: Bool

    var body: some View {
        switch family {
        case .small: small
        default: medium
        }
    }

    /// The Mac and its summary over the most pressing agent, with what it's doing, and a line for
    /// each of the next. The Lock Screen gives a Live Activity 160 points at most.
    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                MacLine(macName: macName, state: state, isStale: isStale)
                Spacer(minLength: 6)
                SummaryText(state: state, more: state.total - state.agents.count)
            }
            .font(.caption.weight(.medium))
            if let featured = state.featured {
                Group {
                    FeaturedRow(agent: featured)
                    ForEach(state.agents.dropFirst()) { agent in
                        OneLineRow(agent: agent)
                    }
                }
                .opacity(state.connected && !isStale ? 1 : 0.6)
            } else {
                Text("Agents show up here while they run on your Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// The most pressing agent alone, with the summary under it.
    private var small: some View {
        HStack(spacing: 8) {
            FeaturedBadge(state: state, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.featured?.worktree ?? macName)
                    .font(.headline)
                    .lineLimit(1)
                if let featured = state.featured {
                    ActivityTimer(agent: featured)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .timerWidth(alignment: .leading)
                }
                SummaryText(state: state)
                    .font(.caption2)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }
}

/// The most pressing agent's badge; the app's eye when there is none, crossed out when the phone
/// has lost touch with the Mac.
struct FeaturedBadge: View {
    let state: AgentsActivityState
    let size: CGFloat

    var body: some View {
        if state.connected, let featured = state.featured {
            StateBadge(state: featured.state, symbol: featured.symbol, collision: featured.collision != nil, size: size)
        } else {
            Image(systemName: state.connected ? "eye" : "eye.slash")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .accessibilityLabel(state.connected ? "No agents at work" : "Not connected to your Mac")
        }
    }
}

/// Beside the camera: how many need you, else how long the most pressing agent has worked.
struct CompactTrailing: View {
    let state: AgentsActivityState

    var body: some View {
        if !state.connected {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not connected to your Mac")
        } else if state.needingYou > 0 {
            Label("\(state.needingYou)", systemImage: "hand.raised.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityLabel(state.summary)
        } else if let featured = state.featured, featured.state == .working {
            Text(timerInterval: featured.since...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .font(.caption.weight(.semibold))
                .foregroundStyle(featured.state.tint)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 48)
        } else {
            Text("\(state.total)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel(state.summary)
        }
    }
}

/// "MacBook Pro", or that the phone lost touch with it, or hasn't heard for a while.
struct MacLine: View {
    let macName: String
    let state: AgentsActivityState
    let isStale: Bool

    var body: some View {
        if !state.connected {
            Label("Lost touch with \(macName)", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if isStale {
            Label("Not updated lately", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Label(macName, systemImage: "desktopcomputer")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// "1 needs you · 2 working", orange while someone needs you; "· 2 more" for agents not shown.
struct SummaryText: View {
    let state: AgentsActivityState
    var more = 0

    var body: some View {
        Text(more > 0 ? "\(state.summary) · \(more) more" : state.summary)
            .foregroundStyle(state.needingYou > 0 ? Color.orange : Color.secondary)
            .lineLimit(1)
    }
}

/// The most pressing agent: its badge, worktree and agent, its task or status, and its timer.
struct FeaturedRow: View {
    let agent: AgentWidgetSnapshot.Agent

    var body: some View {
        HStack(spacing: 8) {
            StateBadge(state: agent.state, symbol: agent.symbol, collision: agent.collision != nil, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(agent.worktree)
                        .font(.subheadline.weight(.semibold))
                        .layoutPriority(1)
                    Text(agent.agent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Text(agent.collision ?? agent.task ?? agent.status)
                    .font(.caption)
                    .foregroundStyle(agent.collision != nil ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            ActivityTimer(agent: agent)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .timerWidth()
        }
    }
}

/// Another agent, on one line: badge, worktree, agent and timer.
struct OneLineRow: View {
    let agent: AgentWidgetSnapshot.Agent

    var body: some View {
        HStack(spacing: 8) {
            StateBadge(state: agent.state, symbol: agent.symbol, collision: agent.collision != nil, size: 20)
                .frame(width: 26)
            Text(agent.worktree)
                .font(.footnote.weight(.semibold))
                .layoutPriority(1)
            Text(agent.agent)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            ActivityTimer(agent: agent)
                .font(.caption.weight(.semibold))
                .timerWidth()
        }
        .lineLimit(1)
    }
}

extension View {
    /// A ticking timer asks for all the width it can get, which in a Live Activity pushes the rest
    /// of its row out of sight: "Waiting 12:34" fits in this.
    func timerWidth(alignment: Alignment = .trailing) -> some View {
        multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            .frame(maxWidth: 110, alignment: alignment)
    }
}

/// "Waiting 2:03", "Ready since 4:02 PM", as `StateTimer` says it, in one `Text`: a timer `Text` of
/// its own takes all the width it's offered and pulls away from its verb.
struct ActivityTimer: View {
    let agent: AgentWidgetSnapshot.Agent
    /// The time alone: "2:03", "4:02 PM".
    var short = false

    var body: some View {
        Group {
            switch agent.state {
            case _ where short:
                if agent.state == .needsYou || agent.state == .working {
                    Text(agent.since, style: .timer).monospacedDigit()
                } else {
                    Text(agent.since, style: .time)
                }
            case .needsYou, .working:
                Text("\(agent.state.verb) \(Text(agent.since, style: .timer))")
                    .monospacedDigit()
            case .ready, .running:
                Text("\(agent.state.verb) since \(Text(agent.since, style: .time))")
            case .ended:
                Text("\(agent.state.verb) \(Text(agent.since, style: .time))")
            }
        }
        .foregroundStyle(agent.state.tint)
    }
}
