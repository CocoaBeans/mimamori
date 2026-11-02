import SwiftUI
import MimamoriCore

extension RepositoryColor {
    /// The system color it names, which adapts to light and dark.
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        }
    }

    /// The color half grayed: marks that tell repositories apart without shouting.
    var muted: Color { color.mix(with: .gray, by: 0.45) }
}

extension EnvironmentValues {
    /// Inside Mimamori, each worktree's repository icon, by worktree path. The widgets have none
    /// and show the repository's color alone.
    @Entry var repositoryIcons: [String: NSImage] = [:]
}

/// The repository on an agent's row: its icon or a dot of its color, then its name, on a plain tag.
struct RepositoryTag: View {
    let name: String
    let color: RepositoryColor?
    var icon: NSImage?

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 11, height: 11)
            } else if let color {
                Circle()
                    .fill(color.muted)
                    .frame(width: 6, height: 6)
            }
            Text(name)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
