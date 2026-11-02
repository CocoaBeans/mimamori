import Foundation

/// User-tunable knobs for the attention heuristics.
public struct RuleConfiguration: Sendable, Hashable, Codable {
    public var disabledRules: Set<RuleID> = []
    /// Repository-relative prefixes the agent is expected to stay inside. Empty disables the scope rule.
    public var scopePrefixes: [String] = []
    public var massDeletionThreshold: Int = 200
    public var largeAdditionThreshold: Int = 1000
    public var hugeFileBytes: Int = 1_000_000

    public init() {}

    public func isEnabled(_ rule: RuleID) -> Bool { !disabledRules.contains(rule) }
}

/// Heuristics that decide which changes deserve a human look.
///
/// Path rules need only the `FileChange`; content rules need the parsed diff
/// and look at added lines only, so reverting someone else's secret never flags.
public enum AttentionRules {

    // MARK: Path rules

    public static func pathFlags(for change: FileChange, config: RuleConfiguration, fileSize: Int64? = nil) -> [AttentionFlag] {
        var flags: [AttentionFlag] = []
        let path = change.path
        let name = change.fileName
        let lowerName = name.lowercased()
        let lowerPath = path.lowercased()
        let components = lowerPath.split(separator: "/").map(String.init)

        func add(_ rule: RuleID, _ message: String, severity: Severity? = nil) {
            guard config.isEnabled(rule) else { return }
            flags.append(AttentionFlag(rule: rule, severity: severity, message: message))
        }

        // Deleting one of these files deserves the same look as editing it (a removed CI
        // workflow or AGENTS.md is a change too), but the message should say it is gone.
        let deleted = change.kind == .deleted
        func worded(_ reason: String) -> String {
            guard deleted else { return reason }
            for suffix in [" changed", " edited"] where reason.hasSuffix(suffix) {
                return reason.dropLast(suffix.count) + " deleted"
            }
            return reason + " deleted"
        }

        if lockfileNames.contains(name) {
            add(.lockfile, worded("Dependency lockfile changed"))
        }

        if let secretReason = secretsFileReason(lowerName: lowerName, lowerPath: lowerPath, components: components) {
            if secretReason.isTemplate {
                add(.secretsFile, worded(secretReason.message), severity: .info)
            } else if deleted {
                // Usually cleanup, not a leak; but if it was ever committed, its secrets are out.
                add(.secretsFile, "\(secretReason.message) deleted: rotate it if it was committed", severity: .warning)
            } else {
                add(.secretsFile, secretReason.message)
            }
        }

        if let reason = ciConfigReason(lowerPath: lowerPath, lowerName: lowerName) {
            add(.ciConfig, worded(reason))
        }

        if let reason = agentConfigReason(lowerPath: lowerPath, lowerName: lowerName, components: components) {
            add(.agentConfig, worded(reason))
        }

        if let reason = gitConfigReason(lowerPath: lowerPath, lowerName: lowerName, components: components) {
            add(.gitConfig, worded(reason))
        }

        if let (reason, severity) = buildConfigReason(lowerPath: lowerPath, lowerName: lowerName) {
            add(.buildConfig, worded(reason), severity: severity)
        }

        if change.kind == .deleted {
            let lines = change.deletions ?? 0
            if isTestPath(lowerPath) {
                add(.testDeleted, "Test file deleted")
            }
            if lines >= 50 {
                add(.massDeletion, "File deleted (\(lines) lines)")
            } else if !change.isBinary {
                add(.massDeletion, "File deleted", severity: .info)
            }
        } else if let deletions = change.deletions, deletions >= config.massDeletionThreshold {
            let severity: Severity = deletions >= config.massDeletionThreshold * 5 ? .critical : .warning
            add(.massDeletion, "\(deletions) lines removed", severity: severity)
        }

        if let additions = change.additions, additions >= config.largeAdditionThreshold {
            add(.largeAddition, "\(additions) lines added")
        }

        if change.isBinary && change.kind != .deleted {
            add(.binary, "Binary file changed")
        }

        if let fileSize, fileSize >= Int64(config.hugeFileBytes), change.kind != .deleted {
            add(.hugeFile, "File is \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")
        }

        if change.modeChanged {
            add(.modeChange, "Mode changed \(change.oldMode) to \(change.newMode)")
        }

        if change.isSymlink && change.kind != .deleted {
            add(.symlink, "Symbolic link")
        }

        if !config.scopePrefixes.isEmpty, config.isEnabled(.outsideScope) {
            let inside = config.scopePrefixes.contains { prefix in
                let clean = prefix.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if clean.isEmpty { return true }
                return path == clean || path.hasPrefix(clean + "/")
            }
            if !inside { add(.outsideScope, "Outside the watched scope") }
        }

        return flags
    }

    // MARK: Content rules

    public static func contentFlags(in diff: FileDiff, config: RuleConfiguration, maxLines: Int = 5000) -> [AttentionFlag] {
        guard !diff.isBinary else { return [] }
        struct Hit { var count = 0; var firstLine: Int?; var sample = "" }
        var hits: [String: Hit] = [:]  // key: rule + label
        var order: [String] = []
        var sawConflictOpen = false

        func record(_ rule: RuleID, _ label: String, line: Int?, sample: String) {
            guard config.isEnabled(rule) else { return }
            let key = rule.rawValue + "|" + label
            if hits[key] == nil {
                hits[key] = Hit(count: 0, firstLine: line, sample: sample)
                order.append(key)
            }
            hits[key]!.count += 1
        }

        var scanned = 0
        outer: for hunk in diff.hunks {
            for line in hunk.lines where line.kind == .addition {
                scanned += 1
                if scanned > maxLines { break outer }
                let text = line.text
                guard !text.isEmpty else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let number = line.newNumber

                // One count per conflict, at its opening marker; a closing marker with none
                // before it is a leftover, and counts too.
                if trimmed.hasPrefix("<<<<<<< ") {
                    sawConflictOpen = true
                    record(.conflictMarkers, "Conflict markers", line: number, sample: trimmed)
                } else if !sawConflictOpen, trimmed.hasPrefix(">>>>>>> ") {
                    record(.conflictMarkers, "Conflict markers", line: number, sample: trimmed)
                }

                if text.count <= 20_000 {
                    if let label = secretLabel(in: text) {
                        record(.secretContent, label, line: number, sample: trimmed)
                    }
                    if let label = testDisabledLabel(in: text) {
                        record(.testDisabled, label, line: number, sample: trimmed)
                    }
                    if let label = lintSuppressedLabel(in: text) {
                        record(.lintSuppressed, label, line: number, sample: trimmed)
                    }
                    if let label = debugLeftoverLabel(in: text) {
                        record(.debugLeftover, label, line: number, sample: trimmed)
                    }
                }
            }
        }

        return order.compactMap { key in
            guard let hit = hits[key] else { return nil }
            let pieces = key.split(separator: "|", maxSplits: 1)
            guard let rule = RuleID(rawValue: String(pieces[0])) else { return nil }
            let label = pieces.count > 1 ? String(pieces[1]) : rule.title
            var message = label
            if hit.count > 1 { message += " (\(hit.count) places)" }
            return AttentionFlag(rule: rule, message: message, line: hit.firstLine)
        }
    }

    // MARK: Path helpers

    public static let lockfileNames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "npm-shrinkwrap.json", "bun.lockb", "bun.lock",
        "Cargo.lock", "Gemfile.lock", "poetry.lock", "Pipfile.lock", "uv.lock", "pdm.lock", "composer.lock",
        "go.sum", "Package.resolved", "Podfile.lock", "mix.lock", "pubspec.lock", "flake.lock",
        "packages.lock.json", "gradle.lockfile", "Manifest.toml", "renv.lock", "conan.lock", "deno.lock",
    ]

    private static func secretsFileReason(lowerName: String, lowerPath: String, components: [String]) -> (message: String, isTemplate: Bool)? {
        if lowerName == ".env" || lowerName.hasPrefix(".env.") || lowerName.hasSuffix(".env") {
            let templateMarkers = ["example", "sample", "template", "dist", "defaults", "schema"]
            if templateMarkers.contains(where: { lowerName.contains($0) }) {
                return ("Environment file template", true)
            }
            return ("Environment file", false)
        }
        let keyExtensions = [".pem", ".key", ".p12", ".pfx", ".p8", ".jks", ".keystore", ".ppk", ".kdbx", ".gpg", ".asc"]
        if keyExtensions.contains(where: { lowerName.hasSuffix($0) }) && !lowerName.hasSuffix(".pub") {
            return ("Key or certificate material", false)
        }
        if ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"].contains(where: { lowerName.hasPrefix($0) }) && !lowerName.hasSuffix(".pub") {
            return ("SSH private key", false)
        }
        if lowerName.contains("credential") || lowerName.contains("secret") || lowerName.hasPrefix("service-account") {
            return ("Credential-looking file name", false)
        }
        if [".netrc", ".npmrc", ".pypirc", ".dockercfg", ".git-credentials", ".htpasswd"].contains(lowerName) {
            return ("Credential store", false)
        }
        if components.contains(".aws") || lowerPath.hasSuffix(".tfvars") {
            return ("Often holds credentials", false)
        }
        return nil
    }

    private static func ciConfigReason(lowerPath: String, lowerName: String) -> String? {
        if lowerPath.hasPrefix(".github/workflows/") || lowerPath.hasPrefix(".github/actions/") { return "GitHub Actions workflow" }
        if lowerName == "dependabot.yml" && lowerPath.hasPrefix(".github/") { return "Dependabot configuration" }
        if lowerName == ".gitlab-ci.yml" || lowerPath.hasPrefix(".gitlab/") { return "GitLab CI configuration" }
        if lowerName == "jenkinsfile" { return "Jenkins pipeline" }
        if lowerPath.hasPrefix(".circleci/") { return "CircleCI configuration" }
        if lowerName.hasPrefix("azure-pipelines") { return "Azure Pipelines configuration" }
        if lowerName == "bitbucket-pipelines.yml" { return "Bitbucket Pipelines configuration" }
        if lowerName == ".travis.yml" { return "Travis CI configuration" }
        if lowerPath.hasPrefix(".buildkite/") { return "Buildkite configuration" }
        if lowerName == "fastfile" || lowerPath.hasPrefix("fastlane/") { return "Fastlane configuration" }
        if lowerName == ".drone.yml" || lowerName == "cloudbuild.yaml" || lowerName == "codemagic.yaml" || lowerName == "appveyor.yml" {
            return "CI configuration"
        }
        if lowerName == "dangerfile" { return "Danger configuration" }
        return nil
    }

    private static func agentConfigReason(lowerPath: String, lowerName: String, components: [String]) -> String? {
        if lowerName == "claude.md" { return "Claude instructions" }
        if lowerName == "agents.md" { return "Agent instructions" }
        if lowerName == "gemini.md" || lowerName == "codex.md" || lowerName == "copilot-instructions.md" { return "Agent instructions" }
        if components.contains(".claude") { return "Claude configuration" }
        if components.contains(".cursor") || lowerName == ".cursorrules" || lowerName == ".cursorignore" { return "Cursor configuration" }
        if components.contains(".windsurf") || lowerName == ".windsurfrules" { return "Windsurf configuration" }
        if components.contains(".gemini") || components.contains(".codex") || components.contains(".roo") || components.contains(".hermes") {
            return "Agent configuration"
        }
        if lowerName.hasPrefix(".aider") || lowerName == ".clinerules" { return "Agent configuration" }
        if lowerName == ".mcp.json" || lowerName == "mcp.json" { return "MCP server configuration" }
        return nil
    }

    private static func gitConfigReason(lowerPath: String, lowerName: String, components: [String]) -> String? {
        switch lowerName {
        case ".gitignore": return "Ignore rules changed"
        case ".gitattributes": return "Git attributes changed"
        case ".gitmodules": return "Submodule configuration changed"
        case ".git-blame-ignore-revs", ".mailmap": return "Git metadata changed"
        case ".pre-commit-config.yaml", "lefthook.yml", ".lefthook.yml": return "Git hook configuration changed"
        default: break
        }
        if components.first == ".husky" || components.first == ".githooks" { return "Git hook changed" }
        if lowerName.hasPrefix("commitlint.config") { return "Commit lint configuration changed" }
        return nil
    }

    private static func buildConfigReason(lowerPath: String, lowerName: String) -> (String, Severity)? {
        if lowerName == "project.pbxproj" { return ("Xcode project file edited", .warning) }
        if lowerName.hasSuffix(".entitlements") { return ("Entitlements changed", .warning) }
        if lowerName.hasSuffix(".tf") || lowerName.hasSuffix(".tfvars") || lowerName.hasSuffix(".hcl") { return ("Infrastructure definition", .warning) }
        if lowerName.hasPrefix("dockerfile") || lowerName.hasPrefix("docker-compose") || lowerName == "compose.yaml" || lowerName == "compose.yml" {
            return ("Container configuration", .info)
        }
        let manifests: Set<String> = [
            "makefile", "cmakelists.txt", "package.swift", "package.json", "pyproject.toml", "setup.py", "setup.cfg",
            "cargo.toml", "go.mod", "gemfile", "pom.xml", "podfile", "pubspec.yaml", "mix.exs", "procfile", "fly.toml",
            "vercel.json", "netlify.toml", "serverless.yml", "tox.ini", "info.plist",
        ]
        if manifests.contains(lowerName) { return ("Project manifest changed", .info) }
        if lowerName.hasPrefix("requirements") && lowerName.hasSuffix(".txt") { return ("Dependency list changed", .info) }
        if lowerName.hasPrefix("build.gradle") || lowerName.hasPrefix("settings.gradle") { return ("Gradle configuration", .info) }
        if lowerName.hasPrefix("tsconfig") || lowerName.hasPrefix("webpack.config") || lowerName.hasPrefix("vite.config")
            || lowerName.hasPrefix("babel.config") || lowerName.hasPrefix(".eslintrc") || lowerName.hasPrefix("eslint.config")
            || lowerName.hasPrefix(".prettierrc") || lowerName.hasSuffix(".xcconfig") {
            return ("Tooling configuration", .info)
        }
        if lowerName.hasSuffix(".csproj") || lowerName.hasSuffix(".sln") { return ("Project file changed", .info) }
        return nil
    }

    /// True when the path looks like a test file.
    public static func isTestPath(_ lowerPath: String) -> Bool {
        let components = lowerPath.split(separator: "/").map(String.init)
        guard let name = components.last else { return false }
        let directories = components.dropLast()
        if directories.contains(where: { ["test", "tests", "__tests__", "spec", "specs", "testing"].contains($0) }) { return true }
        let stem = (name as NSString).deletingPathExtension
        if name.hasPrefix("test_") || name.hasPrefix("test") && name.hasSuffix(".py") { return true }
        if stem.hasSuffix("_test") || stem.hasSuffix("_spec") || stem.hasSuffix(".test") || stem.hasSuffix(".spec") { return true }
        if stem.hasSuffix("tests") || stem.hasSuffix("test") && name.hasSuffix(".swift") { return true }
        return false
    }

    // MARK: Content helpers

    private struct Pattern: @unchecked Sendable {
        let label: String
        let regex: NSRegularExpression
        init(_ label: String, _ pattern: String, options: NSRegularExpression.Options = []) {
            self.label = label
            self.regex = try! NSRegularExpression(pattern: pattern, options: options)
        }
        func matches(_ text: String) -> Bool {
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    private static let secretPatterns: [Pattern] = [
        Pattern("AWS access key", #"\bAKIA[0-9A-Z]{16}\b"#),
        Pattern("Private key", #"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY"#),
        Pattern("GitHub token", #"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})\b"#),
        Pattern("Slack token", #"\bxox[baprs]-[0-9A-Za-z-]{10,}\b"#),
        Pattern("API key", #"\bsk-(?:proj-|ant-|live-)?[A-Za-z0-9_-]{20,}\b"#),
        Pattern("Google API key", #"\bAIza[0-9A-Za-z_-]{35}\b"#),
        Pattern("Stripe key", #"\b[sr]k_live_[0-9a-zA-Z]{10,}\b"#),
        Pattern("JSON web token", #"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}"#),
        Pattern("Credentials in URL", #"https?://[^/\s:@]+:[^@\s]{6,}@"#, options: [.caseInsensitive]),
    ]

    /// Names a secret goes by, with any prefix or suffix: `password`, `DB_PASSWORD`, `stripeSecretKey`.
    private static let secretName = #"[A-Za-z0-9_-]*(?:api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|password|passwd|client[_-]?secret|private[_-]?key)[A-Za-z0-9_-]*"#
    /// A string literal of twelve or more characters given to a secret's name, in code or config:
    /// `password = "…"`, `"api_key": "…"`, `password := "…"`, `'password' => '…'`. A value read
    /// from somewhere (`password = passwordField.text`) is no literal, so it is not flagged.
    private static let quotedSecret = Pattern("Hard-coded secret",
        #"\b"# + secretName + #"["']?\s*(?::=|=>|[:=])\s*["'][^"'\s]{12,}["']"#, options: [.caseInsensitive])
    /// A config line that is only a secret's name and an unquoted value: `DB_PASSWORD=…` in an env
    /// file, `client_secret: …` in YAML. The value is captured.
    private static let unquotedSecret = try! NSRegularExpression(
        pattern: #"^\s*(?:export\s+)?["']?"# + secretName + #"["']?\s*[:=]\s*([A-Za-z0-9/+_.=-]{12,})\s*(?:#.*)?$"#,
        options: [.caseInsensitive])
    /// `settings.db_password`, `config.apiKey`: a value read from elsewhere, not a secret.
    private static let dottedPath = try! NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+$"#)

    private static let secretPlaceholders = [
        "xxx", "your", "example", "changeme", "change_me", "placeholder", "<", "${", "{{", "process.env",
        "environ", "getenv", "todo", "dummy", "fake", "redacted", "******", "insert", "replace",
    ]

    private static func secretLabel(in text: String) -> String? {
        if let pattern = secretPatterns.first(where: { $0.matches(text) }) { return pattern.label }
        // A name and a value: only a literal, and not one that stands in for the real thing.
        let lower = text.lowercased()
        guard !secretPlaceholders.contains(where: { lower.contains($0) }) else { return nil }
        if quotedSecret.matches(text) { return quotedSecret.label }
        let whole = NSRange(text.startIndex..., in: text)
        if let match = unquotedSecret.firstMatch(in: text, range: whole),
           let range = Range(match.range(at: 1), in: text) {
            let value = String(text[range])
            // A real one has a digit somewhere; a word or a dotted path is a name, not a secret.
            if value.contains(where: \.isNumber),
               dottedPath.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) == nil {
                return quotedSecret.label
            }
        }
        return nil
    }

    private static let testDisabledMarkers: [(String, String)] = [
        ("xit(", "Test skipped"), ("xdescribe(", "Test suite skipped"), ("xtest(", "Test skipped"),
        ("it.skip(", "Test skipped"), ("describe.skip(", "Test suite skipped"), ("test.skip(", "Test skipped"),
        ("it.only(", "Focused test"), ("describe.only(", "Focused test"), ("test.only(", "Focused test"), ("fit(", "Focused test"),
        ("@pytest.mark.skip", "Test skipped"), ("@pytest.mark.xfail", "Test marked expected failure"), ("pytest.skip(", "Test skipped"),
        ("@unittest.skip", "Test skipped"), ("#[ignore]", "Test ignored"), ("t.Skip(", "Test skipped"), ("t.SkipNow(", "Test skipped"),
        ("@Ignore", "Test ignored"), ("@Disabled", "Test disabled"), ("XCTSkip", "Test skipped"),
        ("skip: true", "Test skipped"), ("this.skip()", "Test skipped"),
        ("markTestSkipped", "Test skipped"), ("markTestIncomplete", "Test incomplete"),
    ]

    private static func testDisabledLabel(in text: String) -> String? {
        // Swift Testing: @Test(.disabled(...)) or @Test("name", .disabled(...)).
        // Plain ".disabled(" is a common SwiftUI modifier, so require the @Test attribute.
        if text.contains("@Test(") && text.contains(".disabled(") { return "Test disabled" }
        for (marker, label) in testDisabledMarkers where containsToken(marker, in: text) {
            return label
        }
        return nil
    }

    /// `text.contains(marker)`, but a marker that starts with an identifier character must not be
    /// the tail of a longer identifier: "waitUntilExit(" is not "xit(", "profit(" is not "fit(".
    static func containsToken(_ marker: String, in text: String) -> Bool {
        guard let first = marker.first else { return false }
        let needsBoundary = first.isLetter || first.isNumber || first == "_"
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: marker, range: searchRange) {
            if !needsBoundary || range.lowerBound == text.startIndex {
                return true
            }
            let before = text[text.index(before: range.lowerBound)]
            if !(before.isLetter || before.isNumber || before == "_" || before == ".") {
                return true
            }
            searchRange = range.upperBound..<text.endIndex
        }
        return false
    }

    private static let lintMarkers: [(String, String)] = [
        ("eslint-disable", "ESLint disabled"), ("@ts-ignore", "TypeScript check ignored"), ("@ts-nocheck", "TypeScript check disabled"),
        ("@ts-expect-error", "TypeScript error expected"), ("type: ignore", "Type check ignored"), ("# noqa", "Lint ignored"),
        ("pylint: disable", "Pylint disabled"), ("pyright: ignore", "Pyright ignored"), ("swiftlint:disable", "SwiftLint disabled"),
        ("#pragma warning disable", "Compiler warning disabled"), ("nolint", "Lint ignored"), ("#[allow(", "Lint allowed"),
        ("@SuppressWarnings", "Warnings suppressed"), ("rubocop:disable", "RuboCop disabled"), (" as any", "Cast to any"),
        ("@unchecked Sendable", "Unchecked Sendable"),
    ]

    private static func lintSuppressedLabel(in text: String) -> String? {
        for (marker, label) in lintMarkers where text.contains(marker) { return label }
        return nil
    }

    private static let debugMarkers: [(String, String)] = [
        ("console.log(", "console.log left in"), ("debugger", "debugger statement"), ("breakpoint()", "breakpoint() left in"),
        ("pdb.set_trace", "pdb left in"), ("import pdb", "pdb left in"), ("binding.pry", "pry left in"), ("byebug", "byebug left in"),
        ("dbg!(", "dbg! left in"), ("TODO: remove", "Temporary code"), ("HACK", "Marked as hack"),
    ]

    private static func debugLeftoverLabel(in text: String) -> String? {
        for (marker, label) in debugMarkers where containsToken(marker, in: text) {
            if marker == "debugger" {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard trimmed == "debugger" || trimmed == "debugger;" else { continue }
            }
            return label
        }
        return nil
    }
}
