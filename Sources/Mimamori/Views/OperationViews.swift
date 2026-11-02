import SwiftUI
import MimamoriCore

extension WorktreeOperation {
    /// Red while files are conflicted, orange once they are resolved but not yet committed or
    /// continued.
    var tint: Color { conflicted > 0 ? .red : .orange }

    /// "Rebasing feature/login onto main · 3 of 7 · 2 files conflicted", for a tooltip.
    func summary(currentBranch: String?) -> String {
        ([title(currentBranch: currentBranch), progress, detail].compactMap { $0 }).joined(separator: " · ")
    }
}

/// Above the change list: what the worktree is in the middle of, and what it waits for.
struct OperationBanner: View {
    let operation: WorktreeOperation
    let currentBranch: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: operation.symbolName)
                .foregroundStyle(operation.tint)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(operation.title(currentBranch: currentBranch))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let progress = operation.progress {
                        Text(progress)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                if let detail = operation.detail {
                    Text(detail)
                        .foregroundStyle(operation.conflicted > 0 ? AnyShapeStyle(operation.tint) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                // A rebase or pick names the commit it stopped on.
                if operation.kind == .rebase, let incoming = operation.incoming {
                    Text("Stopped at \(incoming)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(operation.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(operation.tint.opacity(0.3)))
        .help(operation.summary(currentBranch: currentBranch))
        .accessibilityElement(children: .combine)
    }
}

/// In a sidebar row: the operation's symbol, and its conflicted files when there are any.
struct OperationChip: View {
    let operation: WorktreeOperation
    let currentBranch: String?

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: operation.symbolName)
                .imageScale(.small)
            if operation.conflicted > 0 {
                Text(operation.conflicted, format: .number)
            }
        }
        .font(.caption2.monospacedDigit().weight(.semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(operation.tint.opacity(0.16), in: Capsule())
        .foregroundStyle(operation.tint)
        .fixedSize()
        .help(operation.summary(currentBranch: currentBranch))
        .accessibilityLabel(operation.summary(currentBranch: currentBranch))
    }
}
