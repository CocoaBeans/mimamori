import Foundation
import VigilCore

struct AppSettings: Codable, Hashable, Sendable {
    var gitPathOverride: String = ""
    var refreshDebounceMilliseconds: Int = 400
    var maxRefreshLatencySeconds: Double = 2.5
    var safetyPollSeconds: Double = 45
    var snapshotsEnabled: Bool = true
    var snapshotMinimumIntervalSeconds: Double = 15
    var maxSnapshotsPerWorktree: Int = 200
    var notificationsEnabled: Bool = false
    var notifyMinimumSeverity: Severity = .warning
    var showMenuBarExtra: Bool = true
    var recencyWindowSeconds: Double = 90
    var wrapDiffLines: Bool = true
    var diffFontSize: Double = 12
    var syntaxHighlighting: Bool = true
    var diffLayout: DiffLayout = .unified
    var inspector = InspectorConfiguration()
    var agentScanEnabled: Bool = true
    var agentScanIntervalSeconds: Double = 3
    var agentToolCallsInFeed: AgentToolCallFeedMode = .mutating
    var notifyOnAgentPermission: Bool = true
    var notifyOnAgentTurnFinished: Bool = false
    var customAgentNames: [String] = []
    var agentsWindowFloats: Bool = false

    init() {}

    // Tolerate older/newer files: every key is optional on decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        gitPathOverride = try c.decodeIfPresent(String.self, forKey: .gitPathOverride) ?? defaults.gitPathOverride
        refreshDebounceMilliseconds = try c.decodeIfPresent(Int.self, forKey: .refreshDebounceMilliseconds) ?? defaults.refreshDebounceMilliseconds
        maxRefreshLatencySeconds = try c.decodeIfPresent(Double.self, forKey: .maxRefreshLatencySeconds) ?? defaults.maxRefreshLatencySeconds
        safetyPollSeconds = try c.decodeIfPresent(Double.self, forKey: .safetyPollSeconds) ?? defaults.safetyPollSeconds
        snapshotsEnabled = try c.decodeIfPresent(Bool.self, forKey: .snapshotsEnabled) ?? defaults.snapshotsEnabled
        snapshotMinimumIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .snapshotMinimumIntervalSeconds) ?? defaults.snapshotMinimumIntervalSeconds
        maxSnapshotsPerWorktree = try c.decodeIfPresent(Int.self, forKey: .maxSnapshotsPerWorktree) ?? defaults.maxSnapshotsPerWorktree
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? defaults.notificationsEnabled
        notifyMinimumSeverity = try c.decodeIfPresent(Severity.self, forKey: .notifyMinimumSeverity) ?? defaults.notifyMinimumSeverity
        showMenuBarExtra = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarExtra) ?? defaults.showMenuBarExtra
        recencyWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .recencyWindowSeconds) ?? defaults.recencyWindowSeconds
        wrapDiffLines = try c.decodeIfPresent(Bool.self, forKey: .wrapDiffLines) ?? defaults.wrapDiffLines
        diffFontSize = try c.decodeIfPresent(Double.self, forKey: .diffFontSize) ?? defaults.diffFontSize
        syntaxHighlighting = try c.decodeIfPresent(Bool.self, forKey: .syntaxHighlighting) ?? defaults.syntaxHighlighting
        diffLayout = try c.decodeIfPresent(DiffLayout.self, forKey: .diffLayout) ?? defaults.diffLayout
        inspector = try c.decodeIfPresent(InspectorConfiguration.self, forKey: .inspector) ?? defaults.inspector
        agentScanEnabled = try c.decodeIfPresent(Bool.self, forKey: .agentScanEnabled) ?? defaults.agentScanEnabled
        agentScanIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .agentScanIntervalSeconds) ?? defaults.agentScanIntervalSeconds
        agentToolCallsInFeed = try c.decodeIfPresent(AgentToolCallFeedMode.self, forKey: .agentToolCallsInFeed) ?? defaults.agentToolCallsInFeed
        notifyOnAgentPermission = try c.decodeIfPresent(Bool.self, forKey: .notifyOnAgentPermission) ?? defaults.notifyOnAgentPermission
        notifyOnAgentTurnFinished = try c.decodeIfPresent(Bool.self, forKey: .notifyOnAgentTurnFinished) ?? defaults.notifyOnAgentTurnFinished
        customAgentNames = try c.decodeIfPresent([String].self, forKey: .customAgentNames) ?? defaults.customAgentNames
        agentsWindowFloats = try c.decodeIfPresent(Bool.self, forKey: .agentsWindowFloats) ?? defaults.agentsWindowFloats
    }
}

enum DiffLayout: String, Codable, CaseIterable, Sendable {
    /// One column: deletions above additions.
    case unified
    /// Old on the left, new on the right.
    case sideBySide
}

enum AgentToolCallFeedMode: String, Codable, CaseIterable, Sendable {
    case none, mutating, all

    var title: String {
        switch self {
        case .none: "None"
        case .mutating: "Edits and commands"
        case .all: "Every tool call"
        }
    }
}

struct PersistedRepository: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var path: String
    var addedAt: Date
}

struct PersistedWorktreeSettings: Codable, Hashable, Sendable {
    var baseline: Baseline = .head
    var scopePrefixes: [String] = []
    var reviews = ReviewLedger()

    init(baseline: Baseline = .head, scopePrefixes: [String] = [], reviews: ReviewLedger = ReviewLedger()) {
        self.baseline = baseline
        self.scopePrefixes = scopePrefixes
        self.reviews = reviews
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseline = try c.decodeIfPresent(Baseline.self, forKey: .baseline) ?? .head
        scopePrefixes = try c.decodeIfPresent([String].self, forKey: .scopePrefixes) ?? []
        reviews = try c.decodeIfPresent(ReviewLedger.self, forKey: .reviews) ?? ReviewLedger()
    }
}

enum ChangeSortOrder: String, Codable, CaseIterable, Sendable {
    case recent, path, severity, size

    var title: String {
        switch self {
        case .recent: "Most Recent"
        case .path: "Path"
        case .severity: "Attention"
        case .size: "Size of Change"
        }
    }
}

struct PersistedUIState: Codable, Hashable, Sendable {
    var showActivity: Bool = true
    var flaggedOnly: Bool = false
    var sortOrder: ChangeSortOrder = .recent
    var selectedWorktree: String?
    var activityScopeAll: Bool = false
    var hideReviewed: Bool = false

    init(showActivity: Bool = true, flaggedOnly: Bool = false, sortOrder: ChangeSortOrder = .recent,
         selectedWorktree: String? = nil, activityScopeAll: Bool = false, hideReviewed: Bool = false) {
        self.showActivity = showActivity
        self.flaggedOnly = flaggedOnly
        self.sortOrder = sortOrder
        self.selectedWorktree = selectedWorktree
        self.activityScopeAll = activityScopeAll
        self.hideReviewed = hideReviewed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showActivity = try c.decodeIfPresent(Bool.self, forKey: .showActivity) ?? true
        flaggedOnly = try c.decodeIfPresent(Bool.self, forKey: .flaggedOnly) ?? false
        sortOrder = try c.decodeIfPresent(ChangeSortOrder.self, forKey: .sortOrder) ?? .recent
        selectedWorktree = try c.decodeIfPresent(String.self, forKey: .selectedWorktree)
        activityScopeAll = try c.decodeIfPresent(Bool.self, forKey: .activityScopeAll) ?? false
        hideReviewed = try c.decodeIfPresent(Bool.self, forKey: .hideReviewed) ?? false
    }
}

struct PersistedState: Codable, Sendable {
    var repositories: [PersistedRepository] = []
    var settings = AppSettings()
    var worktreeSettings: [String: PersistedWorktreeSettings] = [:]
    var ui = PersistedUIState()
    /// Repositories whose sidebar section is collapsed.
    var collapsedRepositories: Set<UUID> = []
    /// Worktree paths the user hid; they are not watched until shown again.
    var hiddenWorktrees: Set<String> = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repositories = try c.decodeIfPresent([PersistedRepository].self, forKey: .repositories) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        worktreeSettings = try c.decodeIfPresent([String: PersistedWorktreeSettings].self, forKey: .worktreeSettings) ?? [:]
        ui = try c.decodeIfPresent(PersistedUIState.self, forKey: .ui) ?? PersistedUIState()
        collapsedRepositories = try c.decodeIfPresent(Set<UUID>.self, forKey: .collapsedRepositories) ?? []
        hiddenWorktrees = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenWorktrees) ?? []
    }
}

enum Persistence {
    static let supportDirectory: URL = {
        // Debug hook: a throwaway folder, so a scripted run never touches the real state or socket.
        if let override = ProcessInfo.processInfo.environment["VIGIL_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Vigil", isDirectory: true)
    }()

    static var stateURL: URL { supportDirectory.appendingPathComponent("state.json") }
    static var shadowIndexDirectory: URL { supportDirectory.appendingPathComponent("index", isDirectory: true) }

    static func load() -> PersistedState {
        guard let data = try? Data(contentsOf: stateURL) else { return PersistedState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PersistedState.self, from: data)) ?? PersistedState()
    }

    static func save(_ state: PersistedState) {
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("Vigil: could not save state: \(error)")
        }
    }
}
