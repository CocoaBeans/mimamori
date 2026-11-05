/// The color that marks a repository wherever it appears: its monogram, the tag on its agents'
/// rows. One of the system's named colors, so it reads in light and dark and in the widgets.
public enum RepositoryColor: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown

    public var title: String { rawValue.capitalized }
}
