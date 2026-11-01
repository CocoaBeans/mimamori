import Foundation

public enum Severity: Int, Codable, Sendable, Hashable, Comparable, CaseIterable {
    case info = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .info: "Info"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

/// Identifies one heuristic in `AttentionRules`. The raw value is persisted in settings.
public enum RuleID: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case lockfile
    case secretsFile
    case secretContent
    case ciConfig
    case agentConfig
    case gitConfig
    case buildConfig
    case massDeletion
    case largeAddition
    case binary
    case testDisabled
    case testDeleted
    case conflictMarkers
    case lintSuppressed
    case debugLeftover
    case modeChange
    case symlink
    case hugeFile
    case outsideScope

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lockfile: "Dependency lockfile"
        case .secretsFile: "Secret or credential file"
        case .secretContent: "Secret-looking content"
        case .ciConfig: "CI configuration"
        case .agentConfig: "Agent instructions"
        case .gitConfig: "Git configuration"
        case .buildConfig: "Build or project configuration"
        case .massDeletion: "Mass deletion"
        case .largeAddition: "Very large addition"
        case .binary: "Binary file"
        case .testDisabled: "Test disabled or skipped"
        case .testDeleted: "Test file deleted"
        case .conflictMarkers: "Conflict markers"
        case .lintSuppressed: "Lint or type check suppressed"
        case .debugLeftover: "Debug leftovers"
        case .modeChange: "Permission change"
        case .symlink: "Symlink"
        case .hugeFile: "Huge file"
        case .outsideScope: "Outside watched scope"
        }
    }

    /// What the rule looks for, in a sentence, for its switch in Settings.
    public var explanation: String {
        switch self {
        case .lockfile: "Flags changes to dependency lockfiles such as package-lock.json, Podfile.lock or Cargo.lock."
        case .secretsFile: "Flags .env files, private keys, certificates and other files that usually hold credentials."
        case .secretContent: "Flags added lines that look like API keys, tokens or passwords."
        case .ciConfig: "Flags changes to CI pipelines such as GitHub Actions workflows."
        case .agentConfig: "Flags changes to agent instructions and settings such as CLAUDE.md, AGENTS.md or .claude/."
        case .gitConfig: "Flags changes to .gitignore, .gitattributes, submodules and git hooks."
        case .buildConfig: "Notes changes to project, build, container and infrastructure files."
        case .massDeletion: "Flags deleted files and edits that remove many lines at once."
        case .largeAddition: "Notes files that gain a very large number of lines."
        case .binary: "Notes binary files that were added or changed."
        case .testDisabled: "Flags tests marked skipped, disabled or focused."
        case .testDeleted: "Flags deleted test files."
        case .conflictMarkers: "Flags unresolved merge conflicts and leftover conflict markers."
        case .lintSuppressed: "Notes added comments that silence a linter or type checker."
        case .debugLeftover: "Notes added print statements, debugger calls and similar leftovers."
        case .modeChange: "Notes files whose permissions changed, such as becoming executable."
        case .symlink: "Flags symbolic links that were added or changed."
        case .hugeFile: "Flags files above the size threshold."
        case .outsideScope: "Flags changes outside the path prefixes you allow for a worktree."
        }
    }

    public var defaultSeverity: Severity {
        switch self {
        case .secretsFile, .secretContent, .conflictMarkers: .critical
        case .lockfile, .ciConfig, .agentConfig, .gitConfig, .massDeletion,
             .testDisabled, .testDeleted, .symlink, .hugeFile, .outsideScope: .warning
        case .buildConfig, .largeAddition, .binary, .lintSuppressed, .debugLeftover, .modeChange: .info
        }
    }

    public var systemImage: String {
        switch self {
        case .lockfile: "lock.doc"
        case .secretsFile, .secretContent: "key.fill"
        case .ciConfig: "gearshape.2"
        case .agentConfig: "brain"
        case .gitConfig: "arrow.triangle.branch"
        case .buildConfig: "hammer"
        case .massDeletion: "trash"
        case .largeAddition: "plus.rectangle.on.rectangle"
        case .binary: "doc.zipper"
        case .testDisabled, .testDeleted: "checkmark.seal.trianglebadge.exclamationmark"
        case .conflictMarkers: "exclamationmark.triangle"
        case .lintSuppressed: "eye.slash"
        case .debugLeftover: "ladybug"
        case .modeChange: "lock.open"
        case .symlink: "link"
        case .hugeFile: "externaldrive"
        case .outsideScope: "scope"
        }
    }
}

/// Something about a change that deserves a human look.
public struct AttentionFlag: Hashable, Sendable, Codable, Identifiable {
    public var rule: RuleID
    public var severity: Severity
    public var message: String
    /// Line number in the new file, when the flag came from content.
    public var line: Int?

    public init(rule: RuleID, severity: Severity? = nil, message: String, line: Int? = nil) {
        self.rule = rule
        self.severity = severity ?? rule.defaultSeverity
        self.message = message
        self.line = line
    }

    public var id: String { "\(rule.rawValue):\(line ?? 0):\(message)" }
}
