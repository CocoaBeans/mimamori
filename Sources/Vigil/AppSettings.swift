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
    var inspector = InspectorConfiguration()

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
        inspector = try c.decodeIfPresent(InspectorConfiguration.self, forKey: .inspector) ?? defaults.inspector
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

    init(showActivity: Bool = true, flaggedOnly: Bool = false, sortOrder: ChangeSortOrder = .recent,
         selectedWorktree: String? = nil, activityScopeAll: Bool = false) {
        self.showActivity = showActivity
        self.flaggedOnly = flaggedOnly
        self.sortOrder = sortOrder
        self.selectedWorktree = selectedWorktree
        self.activityScopeAll = activityScopeAll
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showActivity = try c.decodeIfPresent(Bool.self, forKey: .showActivity) ?? true
        flaggedOnly = try c.decodeIfPresent(Bool.self, forKey: .flaggedOnly) ?? false
        sortOrder = try c.decodeIfPresent(ChangeSortOrder.self, forKey: .sortOrder) ?? .recent
        selectedWorktree = try c.decodeIfPresent(String.self, forKey: .selectedWorktree)
        activityScopeAll = try c.decodeIfPresent(Bool.self, forKey: .activityScopeAll) ?? false
    }
}

struct PersistedState: Codable, Sendable {
    var repositories: [PersistedRepository] = []
    var settings = AppSettings()
    var worktreeSettings: [String: PersistedWorktreeSettings] = [:]
    var ui = PersistedUIState()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repositories = try c.decodeIfPresent([PersistedRepository].self, forKey: .repositories) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        worktreeSettings = try c.decodeIfPresent([String: PersistedWorktreeSettings].self, forKey: .worktreeSettings) ?? [:]
        ui = try c.decodeIfPresent(PersistedUIState.self, forKey: .ui) ?? PersistedUIState()
    }
}

enum Persistence {
    static let supportDirectory: URL = {
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
