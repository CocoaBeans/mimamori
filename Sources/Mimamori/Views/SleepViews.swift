import MimamoriCore
import SwiftUI

/// An agent asleep: its glyph greyed in a disc, with a moon.
struct SleepingBadge: View {
    let agent: AgentKind
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: agent.symbolName)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Color.secondary.opacity(0.14), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: size * 0.32, weight: .bold))
                    .foregroundStyle(.indigo)
                    .padding(2)
                    .background(Circle().fill(.background))
                    .offset(x: 3, y: 3)
            }
            .accessibilityHidden(true)
    }
}

/// The agents put to sleep in a worktree, above its diff: when each slept, its last task, and
/// Wake, which opens a terminal resuming its session.
struct SleepingAgentsBanner: View {
    @Environment(AppModel.self) private var model
    let sleepers: [SleepingAgent]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(sleepers) { sleeper in
                row(sleeper)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.indigo.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.indigo.opacity(0.2), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func row(_ sleeper: SleepingAgent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SleepingBadge(agent: sleeper.agent, size: 30)
                .padding(.top, -3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Text(sleeper.agent.displayName))\u{2002}\(Text("Asleep").fontWeight(.regular).foregroundStyle(.secondary))")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("Slept " + Format.relative(sleeper.sleptAt, to: now))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Put to sleep \(sleeper.sleptAt.formatted(date: .abbreviated, time: .shortened))")
                        .fixedSize()
                    buttons(sleeper)
                }
                if let task = sleeper.task, !task.isEmpty {
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
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(sleeper.agent.displayName), asleep")
    }

    private func buttons(_ sleeper: SleepingAgent) -> some View {
        HStack(spacing: 6) {
            if let command = sleeper.resumeCommand {
                CopyButton(help: "Copy the command that resumes it: \(command)") { Workspace.copy(command) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            Button("Wake") { model.wake(sleeper) }
                .controlSize(.small)
                .help("Open a terminal in this worktree that resumes \(sleeper.agent.displayName)'s session")
                .accessibilityLabel("Wake \(sleeper.agent.displayName)")
            Button {
                model.forgetSleeper(sleeper.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Forget it without waking it. Its session stays with \(sleeper.agent.displayName), to resume by hand.")
            .accessibilityLabel("Forget sleeping \(sleeper.agent.displayName)")
        }
        .fixedSize()
    }
}

/// Asks before putting agents to sleep, and says when they can't be put to sleep or woken.
struct SleepDialogs: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Put \(model.sleepRequest?.names ?? "the agent") to sleep?",
                                isPresented: Binding(get: { model.sleepRequest != nil },
                                                     set: { if !$0 { model.sleepRequest = nil } }),
                                presenting: model.sleepRequest) { request in
                Button("Put to Sleep") { Task { await model.putToSleep(request) } }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text(Self.message(for: request))
            }
            .alert(model.sleepProblem?.title ?? "", isPresented: Binding(get: { model.sleepProblem != nil },
                                                                          set: { if !$0 { model.sleepProblem = nil } }),
                   presenting: model.sleepProblem) { _ in
                Button("OK", role: .cancel) {}
            } message: { problem in
                Text(problem.message)
            }
    }

    static func message(for request: SleepRequest) -> String {
        let commands = request.candidates.compactMap { candidate in
            candidate.sessionID.flatMap { AgentResume.command(for: candidate.agent, session: $0) }
        }
        // Built in steps: CI's older compiler gives up type-checking a long chain of `+`.
        let one = request.candidates.count == 1
        let its = one ? "its" : "their"
        let stop = "Mimamori stops \(its) \(one ? "process" : "processes"), as closing \(its) \(one ? "terminal" : "terminals") would, "
        let keep = "and keeps \(its) \(one ? "session" : "sessions"). "
        let wake = "Wake opens a terminal in this worktree that resumes \(one ? "it" : "them") with \(commands.joined(separator: " and ")). "
        let lost = "Anything typed in \(its) prompt and not sent is lost."
        return [stop, keep, wake, lost].joined()
    }
}
