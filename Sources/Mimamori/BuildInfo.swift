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

    /// The standard About window, with the commit under the version, linked to it on GitHub.
    static func showAboutPanel() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let commit {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let style: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
            let credits = NSMutableAttributedString(string: "Built from commit ", attributes: style)
            var link = style
            link[.link] = repository.appendingPathComponent("commit").appendingPathComponent(commit)
            link[.font] = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            credits.append(NSAttributedString(string: commit, attributes: link))
            if hasUncommittedChanges {
                credits.append(NSAttributedString(string: "\nwith uncommitted changes", attributes: style))
            }
            options[.credits] = credits
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
        NSApplication.shared.activate()
    }
}
