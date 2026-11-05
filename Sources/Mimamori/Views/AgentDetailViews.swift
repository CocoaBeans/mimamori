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

