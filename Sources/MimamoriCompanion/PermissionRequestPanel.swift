import MimamoriShared
import SwiftUI

/// A Claude Code permission request on its agent's card: the tool and the exact command or file,
/// then Allow and Deny, and the Mac's countdown to answering by itself; or, for Claude's questions,
/// each question's options and an Answer button. Claude Code's own prompt stays open meanwhile,
/// and whichever is answered first counts.
struct PermissionRequestPanel: View {
    let request: AgentWidgetSnapshot.PermissionRequest
    /// "Claude Code", for the accessibility labels.
    let agent: String
    let answer: AnswerState?
    let onAnswer: (CompanionReply) -> Void

    var body: some View {
        if let questions = request.questions {
            questionsPanel(questions)
        } else {
            permissionPanel
        }
    }

    // MARK: Questions

    private func questionsPanel(_ questions: [AgentQuestion]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(questions.count == 1 ? "Has a question for you" : "Has \(questions.count) questions for you",
                  systemImage: "questionmark.bubble.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            switch answer {
            case .sending:
                Label {
                    Text("Answering…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .sent:
                Label("Answered from this iPhone. Waiting for the Mac…", systemImage: "paperplane")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case nil:
                EmptyView()
            }
            // Kept in place while it's shown, so what you chose survives a failed send.
            if !isSending && !isSent {
                PhoneQuestionForm(questions: questions, agent: agent) { onAnswer(.answers($0)) }
            }
        }
    }

    private var isSending: Bool {
        if case .sending = answer { true } else { false }
    }

    // MARK: Allow and Deny

    private var permissionPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Asks to use \(request.tool)", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            if let detail = request.detail, !detail.isEmpty {
                // The exact command: what Allow lets run on the Mac.
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(10)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Command: \(detail)")
            }
            if let plan = request.autoAnswer, !isSent {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(plan.at.timeIntervalSince(context.date).rounded(.up)))
                    Text(left > 0 ? "\(plan.allow ? "Allowing" : "Denying") in \(CompanionAlerts.duration(left)) unless you answer"
                         : "\(plan.allow ? "Allowing" : "Denying") now…")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(plan.allow ? .orange : .secondary)
                }
            }
            controls
        }
    }

    private var isSent: Bool {
        if case .sent = answer { true } else { false }
    }

    @ViewBuilder private var controls: some View {
        switch answer {
        case .sending(let allow):
            Label {
                Text(allow ? "Allowing…" : "Denying…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .sent(let allow):
            Label(allow ? "Allowed from this iPhone. Waiting for the Mac…" : "Denied from this iPhone. Waiting for the Mac…",
                  systemImage: "paperplane")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                buttons
            }
        case nil:
            buttons
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button {
                onAnswer(.allow)
            } label: {
                Label("Allow", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .help("Let \(agent) go ahead on your Mac, after Face ID")
            .accessibilityLabel("Allow \(request.tool)")
            .accessibilityHint("Asks for Face ID or your passcode, then lets \(agent) go ahead on your Mac")
            Button(role: .destructive) {
                onAnswer(.deny)
            } label: {
                Label("Deny", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help("Tell \(agent) no; it carries on without this step")
            .accessibilityLabel("Deny \(request.tool)")
            .accessibilityHint("Tells \(agent) no; it carries on without this step")
        }
        .controlSize(.regular)
    }
}

/// Claude's questions on the phone: each one's options, a round mark where one is chosen and a
/// square one where several may be, and a field for an answer of your own, as its own prompt
/// offers. Answer asks for Face ID or the passcode, then sends them all.
private struct PhoneQuestionForm: View {
    let questions: [AgentQuestion]
    /// "Claude Code", for the accessibility hint.
    let agent: String
    let onAnswer: ([String: String]) -> Void

    /// The options chosen, by question.
    @State private var chosen: [String: Set<String>] = [:]
    /// Answers of your own, by question.
    @State private var typed: [String: String] = [:]

    private var answers: [String: String]? {
        var all: [String: String] = [:]
        for question in questions {
            guard let answer = question.answer(choosing: chosen[question.question] ?? [], other: typed[question.question] ?? "")
            else { return nil }
            all[question.question] = answer
        }
        return all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(questions, id: \.question) { question in
                questionView(question)
            }
            Button {
                if let answers { onAnswer(answers) }
            } label: {
                Label(questions.count == 1 ? "Answer" : "Answer All", systemImage: "arrowshape.turn.up.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(answers == nil)
            .accessibilityHint(answers == nil ? "Choose an answer to every question first"
                               : "Asks for Face ID or your passcode, then sends your answers to \(agent)")
        }
    }

    private func questionView(_ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = question.header {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(question.question)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(question.options, id: \.label) { option in
                optionButton(option, of: question)
            }
            TextField("Other answer", text: Binding(get: { typed[question.question] ?? "" }, set: { text in
                typed[question.question] = text
                // One answer only: words of your own replace a chosen option.
                if !question.multiSelect, !text.trimmingCharacters(in: .whitespaces).isEmpty { chosen[question.question] = [] }
            }))
            .textFieldStyle(.roundedBorder)
            .font(.subheadline)
            .accessibilityLabel("Other answer to: \(question.question)")
        }
    }

    private func optionButton(_ option: AgentQuestion.Option, of question: AgentQuestion) -> some View {
        let isChosen = chosen[question.question]?.contains(option.label) == true
        return Button {
            var picks = chosen[question.question] ?? []
            if question.multiSelect {
                if isChosen { picks.remove(option.label) } else { picks.insert(option.label) }
            } else {
                picks = [option.label]
                typed[question.question] = nil
            }
            chosen[question.question] = picks
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: question.multiSelect ? (isChosen ? "checkmark.square.fill" : "square")
                                                       : (isChosen ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(isChosen ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .foregroundStyle(.primary)
                    if let description = option.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityValue(option.description ?? "")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}
