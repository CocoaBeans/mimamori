import MimamoriShared
import SwiftUI

/// A Claude Code permission request on its agent's card: the tool and the exact command or file,
/// then Allow and Deny, and the Mac's countdown to answering by itself. Claude Code's own prompt
/// stays open meanwhile, and whichever is answered first counts.
struct PermissionRequestPanel: View {
    let request: AgentWidgetSnapshot.PermissionRequest
    /// "Claude Code", for the accessibility labels.
    let agent: String
    let answer: AnswerState?
    let onAnswer: (Bool) -> Void

    var body: some View {
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
                onAnswer(true)
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
                onAnswer(false)
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
