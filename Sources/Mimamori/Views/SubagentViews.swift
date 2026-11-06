import MimamoriCore
import SwiftUI

/// An agent's subagents, under its card in the Agents window and in the banner above the diff:
/// each one's kind, what it was asked, how many steps it has taken and for how long, and while it
/// runs, its latest step. A finished one stays a minute, so its end shows.
struct SubagentsList: View {
    let subagents: [Subagent]
    let now: Date
    var worktree: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(subagents.count == 1 ? "Subagent" : "Subagents")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(subagents) { subagent in
                SubagentLine(subagent: subagent, now: now, worktree: worktree)
            }
        }
    }
}

/// One subagent in a line, and its latest step under it while it runs.
struct SubagentLine: View {
    let subagent: Subagent
    let now: Date
    var worktree: String? = nil

    private var timing: String {
        if let finished = subagent.finishedAt {
            return "done in \(Format.duration(finished.timeIntervalSince(subagent.startedAt)))"
        }
        return Format.duration(since: subagent.startedAt, to: now)
    }

    private var steps: String { subagent.steps == 1 ? "1 step" : "\(subagent.steps) steps" }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: subagent.isRunning ? AgentToolCategory.subagent.symbol : "checkmark.circle")
                    .foregroundStyle(subagent.isRunning ? AgentToolCategory.subagent.color : Color.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(subagent.title)
                    .fontWeight(.medium)
                if let description = subagent.description, !description.isEmpty {
                    Text(description)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                Text(steps)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .fixedSize()
                Text(timing)
                    .foregroundStyle(subagent.isRunning ? AnyShapeStyle(AgentToolCategory.subagent.color) : AnyShapeStyle(.tertiary))
                    .monospacedDigit()
                    .fixedSize()
            }
            if subagent.isRunning, let step = subagent.lastStep {
                StepLine(step: step, target: step.summary.map { target in worktree.map { AgentText.shortenPaths(target, in: $0) } ?? target },
                         now: now)
                    .padding(.leading, 20)
            }
        }
        .font(.caption)
        .opacity(subagent.isRunning ? 1 : 0.6)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(subagent.title) subagent, \(subagent.description ?? ""), \(steps), \(subagent.isRunning ? "running" : "finished")")
    }

    private var help: String {
        var lines = [subagent.description.map { "\(subagent.title): \($0)" } ?? subagent.title]
        if subagent.background { lines.append("Running in the background") }
        if let message = subagent.lastMessage, !message.isEmpty { lines.append("Last words: \(message)") }
        return lines.joined(separator: "\n")
    }
}

extension AgentPresence {
    /// "2 subagents", for a compact card; nil with none running.
    var runningSubagentsSummary: String? {
        let running = subagents.filter(\.isRunning).count
        guard running > 0 else { return nil }
        return running == 1 ? "1 subagent" : "\(running) subagents"
    }
}
