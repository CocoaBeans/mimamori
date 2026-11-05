import Foundation

/// Everything Mimamori keeps in `state.json`: the repositories you watch, settings, and each
/// worktree's baseline, review marks and notes.
public struct PersistedState: Codable, Equatable, Sendable {
    /// The shape of the file this version writes. Raise it when a change needs more than a
    /// default for a missing key, so an older Mimamori can tell the file came from a newer one.
    public static let currentSchemaVersion = 1

    /// The shape the file was written in: 0 for files from before versions were written.
    public var schemaVersion = PersistedState.currentSchemaVersion
    public var repositories: [PersistedRepository] = []
    public var settings = AppSettings()
    public var worktreeSettings: [String: PersistedWorktreeSettings] = [:]
    public var ui = PersistedUIState()
    /// Repositories whose sidebar section is collapsed.
    public var collapsedRepositories: Set<UUID> = []
    /// Worktree paths the user hid; they are not watched until shown again.
    public var hiddenWorktrees: Set<String> = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PersistedState()
        schemaVersion = c.decode(.schemaVersion, or: 0)
        repositories = c.decode(.repositories, or: defaults.repositories)
        settings = c.decode(.settings, or: defaults.settings)
        worktreeSettings = c.decode(.worktreeSettings, or: defaults.worktreeSettings)
        ui = c.decode(.ui, or: defaults.ui)
        collapsedRepositories = c.decode(.collapsedRepositories, or: defaults.collapsedRepositories)
        hiddenWorktrees = c.decode(.hiddenWorktrees, or: defaults.hiddenWorktrees)
    }
}

public struct PersistedRepository: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    public var addedAt: Date
    /// The color picked for it by hand; nil to follow its icon or name.
    public var color: RepositoryColor?
    /// Whether its own icon is set aside for its initials.
    public var hidesIcon: Bool?

    public init(id: UUID = UUID(), path: String, addedAt: Date = Date(), color: RepositoryColor? = nil, hidesIcon: Bool? = nil) {
        self.id = id
        self.path = path
        self.addedAt = addedAt
        self.color = color
        self.hidesIcon = hidesIcon
    }

    // Only the path is needed: an entry without one is dropped, and the other repositories kept.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PersistedRepository(path: try c.decode(String.self, forKey: .path))
        path = defaults.path
        id = c.decode(.id, or: defaults.id)
        addedAt = c.decode(.addedAt, or: defaults.addedAt)
        color = c.decode(.color, or: defaults.color)
        hidesIcon = c.decode(.hidesIcon, or: defaults.hidesIcon)
    }
}

public struct PersistedWorktreeSettings: Codable, Hashable, Sendable {
    public var baseline: Baseline = .head
    public var scopePrefixes: [String] = []
    public var reviews = ReviewLedger()
    public var notes = ReviewNotes()

    public init(baseline: Baseline = .head, scopePrefixes: [String] = [], reviews: ReviewLedger = ReviewLedger(),
                notes: ReviewNotes = ReviewNotes()) {
        self.baseline = baseline
        self.scopePrefixes = scopePrefixes
        self.reviews = reviews
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PersistedWorktreeSettings()
        baseline = c.decode(.baseline, or: defaults.baseline)
        scopePrefixes = c.decode(.scopePrefixes, or: defaults.scopePrefixes)
        reviews = c.decode(.reviews, or: defaults.reviews)
        notes = c.decode(.notes, or: defaults.notes)
    }
}

public struct PersistedUIState: Codable, Hashable, Sendable {
    public var showActivity: Bool = true
    public var flaggedOnly: Bool = false
    public var sortOrder: ChangeSortOrder = .recent
    public var selectedWorktree: String?
    public var activityScopeAll: Bool = false
    public var hideReviewed: Bool = false
    public var sidebarAgentsOnly: Bool = false
    public var activityAgentFilter: ActivityAgentFilter = .all
    public var showCommits: Bool = false
    /// Whether the Agents window was open, so it opens again at launch.
    public var agentsWindowOpen: Bool = false
    /// Whether the menu-bar panel was pinned in a window of its own, so it opens again at launch.
    public var overviewWindowOpen: Bool = false
    /// Whether the welcome window has been seen, so it opens only on the first launch.
    public var welcomeShown: Bool = false

    public init(showActivity: Bool = true, flaggedOnly: Bool = false, sortOrder: ChangeSortOrder = .recent,
                selectedWorktree: String? = nil, activityScopeAll: Bool = false, hideReviewed: Bool = false,
                sidebarAgentsOnly: Bool = false, activityAgentFilter: ActivityAgentFilter = .all, showCommits: Bool = false,
                agentsWindowOpen: Bool = false, overviewWindowOpen: Bool = false, welcomeShown: Bool = false) {
        self.showActivity = showActivity
        self.flaggedOnly = flaggedOnly
        self.sortOrder = sortOrder
        self.selectedWorktree = selectedWorktree
        self.activityScopeAll = activityScopeAll
        self.hideReviewed = hideReviewed
        self.sidebarAgentsOnly = sidebarAgentsOnly
        self.activityAgentFilter = activityAgentFilter
        self.showCommits = showCommits
        self.agentsWindowOpen = agentsWindowOpen
        self.overviewWindowOpen = overviewWindowOpen
        self.welcomeShown = welcomeShown
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PersistedUIState()
        showActivity = c.decode(.showActivity, or: defaults.showActivity)
        flaggedOnly = c.decode(.flaggedOnly, or: defaults.flaggedOnly)
        sortOrder = c.decode(.sortOrder, or: defaults.sortOrder)
        selectedWorktree = c.decode(.selectedWorktree, or: defaults.selectedWorktree)
        activityScopeAll = c.decode(.activityScopeAll, or: defaults.activityScopeAll)
        hideReviewed = c.decode(.hideReviewed, or: defaults.hideReviewed)
        sidebarAgentsOnly = c.decode(.sidebarAgentsOnly, or: defaults.sidebarAgentsOnly)
        activityAgentFilter = c.decode(.activityAgentFilter, or: defaults.activityAgentFilter)
        showCommits = c.decode(.showCommits, or: defaults.showCommits)
        agentsWindowOpen = c.decode(.agentsWindowOpen, or: defaults.agentsWindowOpen)
        overviewWindowOpen = c.decode(.overviewWindowOpen, or: defaults.overviewWindowOpen)
        welcomeShown = c.decode(.welcomeShown, or: defaults.welcomeShown)
    }
}
