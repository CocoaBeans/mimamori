import Foundation

public struct AppSettings: Codable, Hashable, Sendable {
    public var gitPathOverride: String = ""
    public var refreshDebounceMilliseconds: Int = 400
    public var maxRefreshLatencySeconds: Double = 2.5
    /// How often a worktree is refreshed with no file event to prompt it. File events are reliable,
    /// so this is a rare backstop; it was `safetyPollSeconds`, every 45 s, which with dozens of
    /// worktrees ran git every second or two. The new name leaves that saved value behind.
    public var backstopPollSeconds: Double = 600
    public var snapshotsEnabled: Bool = true
    public var snapshotMinimumIntervalSeconds: Double = 15
    public var maxSnapshotsPerWorktree: Int = 200
    public var notificationsEnabled: Bool = false
    public var notifyMinimumSeverity: Severity = .warning
    public var showMenuBarExtra: Bool = true
    public var recencyWindowSeconds: Double = 90
    public var wrapDiffLines: Bool = true
    public var diffFontSize: Double = 12
    public var syntaxHighlighting: Bool = true
    public var diffLayout: DiffLayout = .unified
    /// Offer Discard Hunk in uncommitted diffs: the one thing that has Mimamori write to a working tree.
    public var allowsDiscardingChanges: Bool = false
    public var summaryOptions = SessionSummaryOptions()
    /// How long the activity feed is kept on disk.
    public var activityRetentionDays: Int = 7
    public var inspector = InspectorConfiguration()
    public var agentScanEnabled: Bool = true
    public var agentScanIntervalSeconds: Double = 3
    public var agentToolCallsInFeed: AgentToolCallFeedMode = .mutating
    public var notifyOnAgentPermission: Bool = true
    public var notifyOnAgentTurnFinished: Bool = false
    /// Let Claude Code's permission requests be answered in Mimamori as well as in its own prompt.
    public var answerPermissionsInMimamori: Bool = true
    /// Answer a permission request by itself when you have not, after `autoAnswerSeconds`.
    public var autoAnswerPermissions: Bool = false
    public var autoAnswer: PermissionAutoAnswer = .deny
    public var autoAnswerSeconds: Int = 30
    /// Notify when two agents in one worktree edit the same file.
    public var notifyOnAgentCollision: Bool = true
    /// Whether desktop widgets may show agents' tasks and steps, which anyone near the screen can read.
    public var showTasksInWidgets: Bool = true
    public var customAgentNames: [String] = []
    public var agentsWindowFloats: Bool = false
    /// Rows show the task, recent steps and files; off for one-line-per-agent rows.
    public var agentsWindowDetailed: Bool = true
    /// Sections of the Agents window folded to their headers (`AgentSection.key`).
    public var agentsWindowCollapsed: [String] = []
    /// Sections of the menu-bar panel folded to their headers: "agents", "worktrees", and the
    /// agents' groups as "agents." plus their `AgentSection.key`.
    public var menuBarCollapsed: [String] = []
    /// The agent banner above the diff shows the task, steps and files; off for one line.
    public var agentBannerExpanded: Bool = true
    /// What to do when an agent works in a git repository Mimamori does not watch.
    public var agentRepositoryPolicy: AgentRepositoryPolicy = .ask
    /// Repositories you asked not to be offered again.
    public var ignoredAgentRepositories: [String] = []

    public init() {}

    // Tolerate older/newer files: a key that is missing or can't be read keeps its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        gitPathOverride = c.decode(.gitPathOverride, or: defaults.gitPathOverride)
        refreshDebounceMilliseconds = c.decode(.refreshDebounceMilliseconds, or: defaults.refreshDebounceMilliseconds)
        maxRefreshLatencySeconds = c.decode(.maxRefreshLatencySeconds, or: defaults.maxRefreshLatencySeconds)
        backstopPollSeconds = c.decode(.backstopPollSeconds, or: defaults.backstopPollSeconds)
        snapshotsEnabled = c.decode(.snapshotsEnabled, or: defaults.snapshotsEnabled)
        snapshotMinimumIntervalSeconds = c.decode(.snapshotMinimumIntervalSeconds, or: defaults.snapshotMinimumIntervalSeconds)
        maxSnapshotsPerWorktree = c.decode(.maxSnapshotsPerWorktree, or: defaults.maxSnapshotsPerWorktree)
        notificationsEnabled = c.decode(.notificationsEnabled, or: defaults.notificationsEnabled)
        notifyMinimumSeverity = c.decode(.notifyMinimumSeverity, or: defaults.notifyMinimumSeverity)
        showMenuBarExtra = c.decode(.showMenuBarExtra, or: defaults.showMenuBarExtra)
        recencyWindowSeconds = c.decode(.recencyWindowSeconds, or: defaults.recencyWindowSeconds)
        wrapDiffLines = c.decode(.wrapDiffLines, or: defaults.wrapDiffLines)
        diffFontSize = c.decode(.diffFontSize, or: defaults.diffFontSize)
        syntaxHighlighting = c.decode(.syntaxHighlighting, or: defaults.syntaxHighlighting)
        diffLayout = c.decode(.diffLayout, or: defaults.diffLayout)
        allowsDiscardingChanges = c.decode(.allowsDiscardingChanges, or: defaults.allowsDiscardingChanges)
        summaryOptions = c.decode(.summaryOptions, or: defaults.summaryOptions)
        activityRetentionDays = c.decode(.activityRetentionDays, or: defaults.activityRetentionDays)
        inspector = c.decode(.inspector, or: defaults.inspector)
        agentScanEnabled = c.decode(.agentScanEnabled, or: defaults.agentScanEnabled)
        agentScanIntervalSeconds = c.decode(.agentScanIntervalSeconds, or: defaults.agentScanIntervalSeconds)
        agentToolCallsInFeed = c.decode(.agentToolCallsInFeed, or: defaults.agentToolCallsInFeed)
        notifyOnAgentPermission = c.decode(.notifyOnAgentPermission, or: defaults.notifyOnAgentPermission)
        notifyOnAgentTurnFinished = c.decode(.notifyOnAgentTurnFinished, or: defaults.notifyOnAgentTurnFinished)
        answerPermissionsInMimamori = c.decode(.answerPermissionsInMimamori, or: defaults.answerPermissionsInMimamori)
        autoAnswerPermissions = c.decode(.autoAnswerPermissions, or: defaults.autoAnswerPermissions)
        autoAnswer = c.decode(.autoAnswer, or: defaults.autoAnswer)
        autoAnswerSeconds = c.decode(.autoAnswerSeconds, or: defaults.autoAnswerSeconds)
        notifyOnAgentCollision = c.decode(.notifyOnAgentCollision, or: defaults.notifyOnAgentCollision)
        showTasksInWidgets = c.decode(.showTasksInWidgets, or: defaults.showTasksInWidgets)
        customAgentNames = c.decode(.customAgentNames, or: defaults.customAgentNames)
        agentsWindowFloats = c.decode(.agentsWindowFloats, or: defaults.agentsWindowFloats)
        agentsWindowDetailed = c.decode(.agentsWindowDetailed, or: defaults.agentsWindowDetailed)
        agentsWindowCollapsed = c.decode(.agentsWindowCollapsed, or: defaults.agentsWindowCollapsed)
        menuBarCollapsed = c.decode(.menuBarCollapsed, or: defaults.menuBarCollapsed)
        agentBannerExpanded = c.decode(.agentBannerExpanded, or: defaults.agentBannerExpanded)
        agentRepositoryPolicy = c.decode(.agentRepositoryPolicy, or: defaults.agentRepositoryPolicy)
        ignoredAgentRepositories = c.decode(.ignoredAgentRepositories, or: defaults.ignoredAgentRepositories)
    }
}

/// Which entries the activity feed shows, by whether an agent was behind them.
public enum ActivityAgentFilter: String, Codable, CaseIterable, Sendable {
    case all
    /// Agents' own events, and file changes traced to them.
    case agentsOnly
    /// Everything but agents' own events: file changes, commits, flags.
    case hideAgentEvents

    public var title: String {
        switch self {
        case .all: "All activity"
        case .agentsOnly: "Agents only"
        case .hideAgentEvents: "Hide agent events"
        }
    }

    public func includes(_ entry: ActivityEntry) -> Bool {
        switch self {
        case .all: true
        case .agentsOnly: entry.isAgentWork
        case .hideAgentEvents: !entry.kind.isAgentEvent
        }
    }
}

public enum DiffLayout: String, Codable, CaseIterable, Sendable {
    /// One column: deletions above additions.
    case unified
    /// Old on the left, new on the right.
    case sideBySide
}

public enum AgentToolCallFeedMode: String, Codable, CaseIterable, Sendable {
    case none, mutating, all

    public var title: String {
        switch self {
        case .none: "None"
        case .mutating: "Edits and commands"
        case .all: "Every tool call"
        }
    }
}

/// How Mimamori answers a permission request you have not answered in time.
public enum PermissionAutoAnswer: String, Codable, CaseIterable, Sendable {
    case allow, deny

    public var title: String { self == .allow ? "Allow" : "Deny" }
}

/// What happens when an agent works in a git repository Mimamori does not watch.
public enum AgentRepositoryPolicy: String, Codable, CaseIterable, Sendable {
    case ask, watch, ignore

    public var title: String {
        switch self {
        case .ask: "Offer to watch it"
        case .watch: "Watch it"
        case .ignore: "Do nothing"
        }
    }
}

public enum ChangeSortOrder: String, Codable, CaseIterable, Sendable {
    case recent, path, severity, size

    public var title: String {
        switch self {
        case .recent: "Most Recent"
        case .path: "Path"
        case .severity: "Attention"
        case .size: "Size of Change"
        }
    }
}
