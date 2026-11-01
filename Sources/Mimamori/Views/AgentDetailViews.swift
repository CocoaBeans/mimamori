import SwiftUI
import MimamoriCore

// Pieces shared by the Agents window's rows and the agent banner above the diff.

enum AgentText {
    /// Paths inside the worktree read better relative to it, and others from ~.
    static func shortenPaths(_ text: String, in worktree: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return text.replacingOccurrences(of: worktree + "/", with: "")
            .replacingOccurrences(of: home + "/", with: "~/")
    }
}

/// One recent tool call: what kind of step, what it acted on, and how long ago.
extension AgentToolCategory {
    /// The step's symbol and colour, as step lines and turn timelines draw it: colour for what
    /// acts (edits, commands, lookups, subagents, questions), grey for reading and searching.
    var symbol: String {
        switch self {
        case .edit: "pencil"
        case .command: "terminal"
        case .read: "doc.text"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .subagent: "person.2"
        case .question: "questionmark.bubble"
        case .other: "wrench.and.screwdriver"
        }
    }

    var color: Color {
        switch self {
        case .edit: .blue
        case .command: .green
        case .read, .search, .other: .secondary
        case .web: .teal
        case .subagent: .purple
        case .question: .orange
        }
    }
}

/// A turn's tool calls as marks along a thin strip, coloured by kind as the step lines are, a
/// failed one red and one waiting on you orange: the turn's rhythm at a glance, and a long empty
/// stretch at the end for an agent gone quiet.
struct TurnTimelineStrip: View {
    let timeline: TurnTimeline
    var height: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2),
                         with: .style(.quaternary))
            for mark in timeline.marks {
                // Wide enough to see, however short the call.
                let width = min(size.width, max(3, mark.length * size.width))
                let rect = CGRect(x: min(mark.start * size.width, size.width - width), y: 0, width: width, height: size.height)
                let color = mark.failed ? Color.red : mark.waiting ? Color.orange : mark.category.color
                context.fill(Path(roundedRect: rect, cornerRadius: min(2, size.height / 2)),
                             with: .color(mark.running ? color.opacity(0.6) : color))
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .help(description)
        .accessibilityElement()
        .accessibilityLabel(description)
    }

    /// "12 steps over 4m: 6 edits, 3 commands, 3 reads. Quiet for 1m."
    private var description: String {
        let steps = timeline.marks.count
        var text = timeline.missedCalls > 0
            ? "The last \(steps) of \(steps + timeline.missedCalls) steps, over \(Format.duration(timeline.duration))"
            : "\(steps == 1 ? "1 step" : "\(steps) steps") over \(Format.duration(timeline.duration))"
        let kinds = AgentToolCategory.describe(timeline.counts)
        if !kinds.isEmpty { text += ": " + kinds }
        text += "."
        if let quiet = timeline.quietFor, quiet >= 60 { text += " Quiet for \(Format.duration(quiet))." }
        return text
    }
}

struct StepLine: View {
    let step: AgentToolCall
    let target: String?
    let now: Date
    /// The step is waiting for your permission rather than running.
    var waiting = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: step.category.symbol)
                .foregroundStyle(step.category.color)
                .frame(width: 14)
            Text(step.toolName)
                .fontWeight(.medium)
                .lineLimit(1)
                .layoutPriority(1)
            if let target, !target.isEmpty {
                Text(target)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if let finished = step.finishedAt {
                Text(step.failed ? "failed " + Format.relative(finished, to: now) : Format.relative(finished, to: now))
                    .foregroundStyle(step.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                    .fixedSize()
            } else if waiting {
                Text("needs you")
                    .foregroundStyle(.orange)
                    .fixedSize()
            } else {
                Text("running")
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
            }
        }
        .font(.system(.caption, design: .monospaced))
    }
}

/// Chips for the files touched this turn; flagged ones tinted. Click one to open its diff.
struct FileChips: View {
    let files: [FileChange]
    let onOpen: (String) -> Void
    private static let limit = 6

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(files.prefix(Self.limit)) { file in
                Button {
                    onOpen(file.path)
                } label: {
                    HStack(spacing: 4) {
                        FileTypeIcon(path: file.path)
                            .imageScale(.small)
                        Text(file.fileName)
                        if !file.isBinary, let additions = file.additions, let deletions = file.deletions {
                            DiffBar(additions: additions, deletions: deletions, block: 5)
                        }
                    }
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(file.isFlagged ? AnyShapeStyle(Color.orange.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                                in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(file.isFlagged ? Color.orange : Color.primary)
                }
                .buttonStyle(.plain)
                .help(([file.path, file.isBinary ? "binary" : file.additions.map { "+\($0) −\(file.deletions ?? 0)" }].compactMap { $0 }
                       + file.flags.map(\.message)).joined(separator: "\n"))
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

/// Lays children out left to right, wrapping onto new lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
