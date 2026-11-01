import Foundation

/// The blocks of a diffstat bar. Like GitHub's, five blocks, green for the share of lines added
/// and red for the share removed; unlike GitHub's, how many are lit says how much changed, on a
/// log scale, so a list shows its big edits at a glance: a line or two lights one block, ten
/// lines two, a hundred four, and a few hundred all five.
public struct DiffBlocks: Equatable, Sendable {
    public static let count = 5

    public let added: Int
    public let removed: Int
    public var empty: Int { Self.count - added - removed }

    public init(additions: Int, deletions: Int) {
        let additions = max(0, additions), deletions = max(0, deletions)
        let total = additions + deletions
        guard total > 0 else {
            added = 0
            removed = 0
            return
        }
        let lit = min(Self.count, max(1, Int((log10(Double(total) + 1) / 3 * Double(Self.count)).rounded(.up))))
        // Split by plain rounding: two lines removed among three hundred added light no red
        // block, which would claim a fifth of the change. The numbers beside the bar say "−2".
        added = Int((Double(lit) * Double(additions) / Double(total)).rounded())
        removed = lit - added
    }
}

/// The SF Symbol for a file, from its name: what kind of file it is at a glance.
public enum FileSymbol {
    public static func name(for path: String) -> String {
        let fileName = (path as NSString).lastPathComponent
        if isTest(fileName) { return "testtube.2" }
        let name = fileName.lowercased()
        if let symbol = byName[name] { return symbol }
        return byExtension[(name as NSString).pathExtension] ?? "doc"
    }

    /// `FooTests.swift`, `foo.test.ts`, `foo.spec.js`, `foo_test.go`, `test_foo.py`; not `Contest.swift`.
    private static func isTest(_ fileName: String) -> Bool {
        let stem = (fileName as NSString).deletingPathExtension
        let lower = stem.lowercased()
        return stem.hasSuffix("Tests") || stem.hasSuffix("Test") || stem.hasSuffix("Spec")
            || ["_test", "_tests", "-test", "_spec"].contains { lower.hasSuffix($0) } || lower.hasPrefix("test_")
            || lower == "test" || lower == "tests" || fileName.contains(".test.") || fileName.contains(".spec.")
    }

    private static let byName: [String: String] = [
        "dockerfile": "shippingbox", "makefile": "hammer", "package.swift": "shippingbox",
        "package.resolved": "lock", "package-lock.json": "lock", "yarn.lock": "lock", "cargo.lock": "lock",
        "gemfile.lock": "lock", "podfile.lock": "lock", "license": "doc.plaintext", ".gitignore": "eye.slash",
        ".env": "key",
    ]

    private static let code = "chevron.left.forwardslash.chevron.right"

    private static let byExtension: [String: String] = {
        var map: [String: String] = ["swift": "swift"]
        for ext in ["c", "h", "m", "mm", "cpp", "cc", "hpp", "rs", "go", "py", "rb", "js", "mjs", "cjs", "ts", "tsx", "jsx",
                    "java", "kt", "kts", "cs", "php", "lua", "dart", "scala", "ex", "exs", "zig", "vue", "svelte"] {
            map[ext] = code
        }
        for ext in ["sh", "zsh", "bash", "fish", "command"] { map[ext] = "terminal" }
        for ext in ["md", "markdown", "txt", "rst", "adoc", "org"] { map[ext] = "doc.text" }
        for ext in ["json", "jsonc", "json5"] { map[ext] = "curlybraces" }
        for ext in ["yml", "yaml", "toml", "plist", "xml", "ini", "cfg", "conf", "entitlements", "xcconfig", "pbxproj", "env"] {
            map[ext] = "gearshape"
        }
        for ext in ["html", "htm", "css", "scss", "sass", "less"] { map[ext] = "globe" }
        for ext in ["png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "ico", "icns", "tiff", "bmp"] { map[ext] = "photo" }
        map["pdf"] = "doc.richtext"
        for ext in ["csv", "tsv", "xlsx", "numbers"] { map[ext] = "tablecells" }
        for ext in ["sql", "sqlite", "db"] { map[ext] = "cylinder" }
        for ext in ["zip", "tar", "gz", "tgz", "xz", "bz2", "7z", "dmg"] { map[ext] = "archivebox" }
        for ext in ["mp4", "mov", "m4v", "webm"] { map[ext] = "film" }
        for ext in ["mp3", "wav", "aiff", "m4a", "caf", "flac"] { map[ext] = "waveform" }
        for ext in ["strings", "xcstrings", "stringsdict", "po"] { map[ext] = "character.bubble" }
        for ext in ["lock"] { map[ext] = "lock" }
        for ext in ["ttf", "otf", "woff", "woff2"] { map[ext] = "textformat" }
        return map
    }()

    /// Every symbol it can return, for checking they exist.
    public static var allNames: Set<String> {
        Set(byName.values).union(byExtension.values).union(["doc", "testtube.2"])
    }
}
