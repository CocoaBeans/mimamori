import MimamoriShared
import SwiftUI

/// An agent's list of actions, from tapping its card: the card as it is now, then every step of
/// the turn under way, newest first, then the turns before it under their prompts. The Mac sends
/// them while this is on screen.
struct AgentActionsView: View {
    let model: CompanionModel
    let worktree: String

    private var agent: AgentWidgetSnapshot.Agent? {
        model.snapshot?.agents.first { $0.id == worktree }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            List {
                if let agent {
                    Section {
                        AgentCardView(agent: agent, detailed: true, now: context.date,
                                      answer: agent.permissionRequest.flatMap { model.answers[$0.id] }) { reply in
                            if let request = agent.permissionRequest {
                                Task { await model.answer(request, reply) }
                            }
                        }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                if let actions = model.actions, actions.worktreePath == worktree {
                    if actions.turns.isEmpty {
                        Text("No steps yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(actions.turns.enumerated()), id: \.element.id) { index, turn in
                        Section {
                            if turn.calls.isEmpty {
                                Text("No steps yet.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(turn.calls) { call in
                                ActionRow(call: call, waiting: call.id == actions.waitingCallID, now: context.date,
                                          subagent: call.agentID.map { actions.subagentTitles?[$0] ?? "Subagent" })
                            }
                        } header: {
                            TurnHeader(turn: turn, current: index == 0 && agent.map { $0.state == .working || $0.state == .needsYou } == true)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Asking \(model.connectedMac ?? "your Mac") for its steps…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle(agent.map { "\($0.repository) › \($0.worktree)" } ?? "Actions")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.watch(worktree) }
        .onDisappear { model.watch(nil) }
    }
}

/// "This turn" or "Earlier", with the prompt that started it and when.
private struct TurnHeader: View {
    let turn: AgentActions.Turn
    let current: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(current ? "This turn" : turn.startedAt == nil ? "Before" : "Earlier")
                Spacer()
                if let started = turn.startedAt {
                    Text(started.formatted(date: .omitted, time: .shortened))
                }
                Text(turn.calls.count == 1 ? "1 step" : "\(turn.calls.count) steps")
            }
            if let prompt = turn.prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .textCase(nil)
                    .lineLimit(3)
            }
        }
    }
}

/// One step: what kind, which tool on what, when, for how long, and whether it failed, runs or
/// waits on you.
private struct ActionRow: View {
    let call: AgentToolCall
    let waiting: Bool
    let now: Date
    /// The subagent that took the step: "Explore"; nil for the agent itself.
    var subagent: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: call.category.symbol)
                .foregroundStyle(call.category.color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(call.toolName)
                        .font(.subheadline.weight(.medium))
                    if let subagent {
                        Label(subagent, systemImage: AgentToolCategory.subagent.symbol)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(AgentToolCategory.subagent.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(AgentToolCategory.subagent.color.opacity(0.12), in: Capsule())
                            .accessibilityLabel("by the \(subagent) subagent")
                    }
                }
                if let target = call.summary, !target.isEmpty {
                    Text(target)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(call.startedAt.formatted(date: .omitted, time: .standard))
                    .foregroundStyle(.secondary)
                state
            }
            .font(.caption.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var state: some View {
        if let finished = call.finishedAt {
            let took = Format.duration(finished.timeIntervalSince(call.startedAt))
            Text(call.failed ? "failed after \(took)" : took)
                .foregroundStyle(call.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
        } else if waiting {
            Text("needs you")
                .foregroundStyle(.orange)
        } else {
            Text("running \(Format.duration(now.timeIntervalSince(call.startedAt)))")
                .foregroundStyle(Color.accentColor)
        }
    }
}
