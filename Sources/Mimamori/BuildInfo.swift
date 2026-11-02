import AppKit

/// What the running app was built from. `Scripts/make-app.sh` stamps the commit into Info.plist
/// as `MimamoriCommit`; a build made any other way (straight from Xcode, `swift run`) has none.
enum BuildInfo {
    static let repository = URL(string: "https://github.com/CocoaBeans/mimamori")!

    static let version = info("CFBundleShortVersionString") ?? "(no version)"
    static let build = info("CFBundleVersion") ?? "-"

    /// The commit's first eight characters, without the "-dirty" mark.
    static let commit: String? = stamp.map { $0.hasSuffix("-dirty") ? String($0.dropLast(6)) : $0 }
    /// Whether tracked files had changes not yet committed when it was built.
    static let hasUncommittedChanges = stamp?.hasSuffix("-dirty") ?? false

    /// "0.1.0 (1), commit 6e2b1b37 with uncommitted changes".
    static var summary: String {
        var text = "\(version) (\(build))"
        if let commit { text += ", commit \(commit)" + (hasUncommittedChanges ? " with uncommitted changes" : "") }
        return text
    }

    private static let stamp: String? = info("MimamoriCommit")

    private static func info(_ key: String) -> String? {
        guard let value = Bundle.main.infoDictionary?[key] as? String, !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    /// What Mimamori is, as the README opens.
    static let introduction = [
        "Mimamori (見守り, mee-mah-MOH-ree) is Japanese for watching over someone with care: the way you watch children at play, ready to step in.",
        "A small, native macOS app that keeps watch over git worktrees while coding agents work in them. It sits beside Claude Code, Codex, Aider, Cursor or whatever you run, and answers two questions at a glance: what is it doing right now, and should I be worried.",
    ].joined(separator: "\n")

    /// The standard About window, with what Mimamori is under the version, then the commit it
    /// was built from, linked to it on GitHub.
    static func showAboutPanel() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 8
        let style: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString(string: introduction, attributes: style)
        if let commit {
            var quiet = style
            quiet[.foregroundColor] = NSColor.secondaryLabelColor
            credits.append(NSAttributedString(string: "\nBuilt from commit ", attributes: quiet))
            var link = quiet
            link[.link] = repository.appendingPathComponent("commit").appendingPathComponent(commit)
            link[.font] = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            credits.append(NSAttributedString(string: commit, attributes: link))
            if hasUncommittedChanges {
                credits.append(NSAttributedString(string: "\nwith uncommitted changes", attributes: quiet))
            }
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApplication.shared.activate()
    }
}
