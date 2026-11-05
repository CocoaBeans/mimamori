import Foundation
import Testing
@testable import MimamoriCore

@Suite("Saved state")
struct StateFileTests {
    // What Fixtures/state holds: two repositories, three worktrees, review marks, and in 1.1.0 notes.
    static let store = "/Users/sample/Projects/acme-store"
    static let login = "/Users/sample/Projects/acme-store-worktrees/feature-login"
    static let bottles = "/Users/sample/Projects/99-bottles"
    static let bottlesID = UUID(uuidString: "A2B3C4D5-E6F7-4809-9A1B-2C3D4E5F6071")!

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/state"))
        return try Data(contentsOf: url)
    }

    private func copiesKeptAside(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("state.unreadable-") }
    }

    /// The repositories, marks and notes every fixture holds.
    private func expectSample(_ state: PersistedState, notes: Bool) throws {
        #expect(state.repositories.map(\.path) == [Self.store, Self.bottles])
        #expect(state.repositories.last?.hidesIcon == true)
        #expect(state.collapsedRepositories == [Self.bottlesID])
        #expect(state.hiddenWorktrees == ["/Users/sample/Projects/acme-store-worktrees/old-spike"])

        let store = try #require(state.worktreeSettings[Self.store])
        #expect(store.baseline == .snapshot("refs/monitor/1a2b3c4d5e6f/snapshots/20261101T100000Z"))
        #expect(store.scopePrefixes == ["Sources/Checkout"])
        #expect(Set(store.reviews.marks.keys) == ["Sources/Checkout/Cart.swift", "Package.resolved"])
        #expect(store.reviews.marks["Sources/Checkout/Cart.swift"]?.fingerprint == "100644:3b18e512dba79e4c8300dd08aeb37f8e728b8dad")
        #expect(state.worktreeSettings[Self.login]?.reviews.marks.count == 1)
        #expect(state.worktreeSettings[Self.bottles]?.baseline == .start)

        let settings = state.settings
        #expect(settings.notificationsEnabled)
        #expect(settings.notifyMinimumSeverity == .critical)
        #expect(settings.inspector.maxContentScanFiles == 300)
        #expect(settings.inspector.rules.massDeletionThreshold == 500)
        #expect(settings.summaryOptions.diffs)
        #expect(settings.customAgentNames == ["Builder"])
        #expect(settings.agentRepositoryPolicy == .watch)
        #expect(state.ui.selectedWorktree == Self.store)
        #expect(state.ui.welcomeShown)

        guard notes else {
            #expect(store.notes.isEmpty)
            return
        }
        #expect(store.notes.all.map(\.text) == ["Taxes are left out here.", "Why did this move to a branch?", "Keep this check."])
        let first = try #require(store.notes.all.first)
        #expect(first.lines == 12...14)
        #expect(first.quote.count == 3)
        #expect(first.sentTo == "Claude Code")
        #expect(store.notes.all.last?.side == .old)
        #expect(store.notes.all.last?.isResolved == true)
    }

    @Test(arguments: ["1.0.0", "1.1.0"])
    func readsWhatEachReleaseSaved(_ version: String) throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = try fixture(version)
        let file = StateFile(url: folder.appendingPathComponent("state.json"))
        try saved.write(to: file.url)

        let loaded = file.load()
        #expect(loaded.problem == nil)
        #expect(loaded.keptAside == nil)
        #expect(loaded.state.schemaVersion == 0)
        try expectSample(loaded.state, notes: version != "1.0.0")
        #expect(loaded.state.settings.diffLayout == .sideBySide)
        #expect(loaded.state.settings.inspector.rules.disabledRules == [.lockfile, .debugLeftover])
        #expect(loaded.state.settings.allowsDiscardingChanges == (version != "1.0.0"))

        // Saving it writes this version's shape, keeps the release's file as the previous copy,
        // and reads back the same.
        file.save(loaded.state)
        #expect(try Data(contentsOf: file.previousURL) == saved)
        let again = StateFile(url: file.url).load()
        #expect(again.problem == nil)
        #expect(again.state.schemaVersion == PersistedState.currentSchemaVersion)
        var expected = loaded.state
        expected.schemaVersion = PersistedState.currentSchemaVersion
        #expect(again.state == expected)
        #expect(try copiesKeptAside(in: folder).isEmpty)
    }

    @Test func readsAFileFromANewerVersion() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = try fixture("future")
        let file = StateFile(url: folder.appendingPathComponent("state.json"))
        try saved.write(to: file.url)

        let loaded = file.load()
        try expectSample(loaded.state, notes: true)
        // What this version doesn't know falls back, and the rest stays.
        #expect(loaded.state.schemaVersion == 7)
        #expect(loaded.state.repositories.first?.color == nil)
        #expect(loaded.state.settings.diffLayout == .unified)
        #expect(loaded.state.settings.inspector.rules.disabledRules == [.lockfile, .debugLeftover])
        #expect(loaded.state.ui.sortOrder == .recent)
        #expect(loaded.state.worktreeSettings[Self.login]?.baseline == .head)
        #expect(loaded.state.worktreeSettings[Self.store]?.notes.all[1].side == .new)

        // The newer file is kept as it was before anything is saved over it.
        #expect(loaded.problem?.contains("newer Mimamori") == true)
        let aside = try #require(loaded.keptAside)
        #expect(try Data(contentsOf: aside) == saved)
        file.save(loaded.state)
        #expect(try Data(contentsOf: aside) == saved)
        #expect(!FileManager.default.fileExists(atPath: file.previousURL.path))
        #expect(StateFile(url: file.url).load().problem == nil)
    }

    @Test func keepsACorruptFileAsideAndSavesAfterIt() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let corrupt = Data("{\"repositories\": [{\"path\": \"/Users/sample/Projects/acme-st".utf8)
        let file = StateFile(url: folder.appendingPathComponent("state.json"))
        try corrupt.write(to: file.url)

        let loaded = file.load()
        #expect(loaded.state == PersistedState())
        #expect(loaded.problem != nil)
        #expect(!loaded.fromPrevious)
        let aside = try #require(loaded.keptAside)
        #expect(aside.lastPathComponent.hasPrefix("state.unreadable-"))
        #expect(try Data(contentsOf: aside) == corrupt)

        var state = loaded.state
        state.repositories = [PersistedRepository(path: Self.store)]
        file.save(state)
        #expect(try Data(contentsOf: aside) == corrupt)
        #expect(try copiesKeptAside(in: folder).map(\.lastPathComponent) == [aside.lastPathComponent])
        // The corrupt file isn't kept as the previous copy: it is aside already.
        #expect(!FileManager.default.fileExists(atPath: file.previousURL.path))
        #expect(StateFile(url: file.url).load().state.repositories.map(\.path) == [Self.store])
    }

    @Test func opensThePreviousCopyWhenTheFileCantBeRead() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = StateFile(url: folder.appendingPathComponent("state.json"))
        try Data("not json".utf8).write(to: file.url)
        try fixture("1.1.0").write(to: file.previousURL)

        let loaded = file.load()
        #expect(loaded.fromPrevious)
        #expect(loaded.keptAside != nil)
        try expectSample(loaded.state, notes: true)

        // The good copy stays the previous one through the first save.
        file.save(loaded.state)
        #expect(try Data(contentsOf: file.previousURL) == fixture("1.1.0"))
    }

    @Test func neverSavesOverAFileItCouldNotRead() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = try fixture("1.1.0")
        let file = StateFile(url: folder.appendingPathComponent("state.json"))
        try saved.write(to: file.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.url.path)

        let loaded = file.load()
        #expect(loaded.problem != nil)
        #expect(loaded.keptAside == nil)
        file.save(PersistedState())

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.url.path)
        #expect(try Data(contentsOf: file.url) == saved)
    }

    @Test func dropsOnlyTheEntriesItCantRead() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = """
        {
          "repositories": [
            {"id": "6F1C2A4E-0B3D-4C59-9E8A-1D2F3A4B5C6D", "path": "\(Self.store)", "addedAt": "2026-10-28T09:15:00Z"},
            {"id": "11111111-2222-4333-8444-555555555555", "addedAt": "2026-10-29T09:15:00Z"},
            42,
            {"path": "\(Self.bottles)", "color": "chartreuse"}
          ],
          "worktreeSettings": {
            "\(Self.store)": {
              "reviews": {"marks": {
                "Cart.swift": {"fingerprint": "100644:abc", "reviewedAt": "2026-11-01T10:05:00Z"},
                "Coupon.swift": {"fingerprint": 5, "reviewedAt": "2026-11-01T10:05:00Z"}
              }},
              "notes": {"all": [
                {"path": "Cart.swift", "createdAt": "2026-11-01T10:07:00Z"},
                {"path": "Cart.swift", "text": "Taxes are left out here.", "lines": [12, 14], "side": "new"}
              ]}
            },
            "\(Self.bottles)": "not settings"
          },
          "collapsedRepositories": ["6F1C2A4E-0B3D-4C59-9E8A-1D2F3A4B5C6D", "not a UUID"]
        }
        """
        let file = StateFile(url: folder.appendingPathComponent("state.json"))
        try Data(json.utf8).write(to: file.url)

        let loaded = file.load()
        #expect(loaded.state.repositories.map(\.path) == [Self.store, Self.bottles])
        let store = try #require(loaded.state.worktreeSettings[Self.store])
        #expect(Array(store.reviews.marks.keys) == ["Cart.swift"])
        #expect(store.notes.all.map(\.text) == ["Taxes are left out here."])
        #expect(store.notes.all.first?.lines == 12...14)
        #expect(loaded.state.worktreeSettings[Self.bottles] == nil)
        #expect(loaded.state.collapsedRepositories.count == 1)
        // What was dropped is still in the copy kept aside.
        let aside = try #require(loaded.keptAside)
        #expect(try Data(contentsOf: aside) == Data(json.utf8))
    }

    @Test func keepsThePreviousCopyOnEachSave() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = StateFile(url: folder.appendingPathComponent("state.json"))
        #expect(file.load().problem == nil)

        // Whole seconds, as the file keeps them.
        let added = Date(timeIntervalSince1970: 1_793_000_000)
        var first = PersistedState()
        first.repositories = [PersistedRepository(path: Self.store, addedAt: added)]
        file.save(first)
        #expect(!FileManager.default.fileExists(atPath: file.previousURL.path))

        var second = first
        second.repositories.append(PersistedRepository(path: Self.bottles, addedAt: added))
        file.save(second)
        file.save(second)
        let previous = StateFile(url: file.previousURL).load()
        #expect(previous.state.repositories.map(\.path) == [Self.store])
        #expect(StateFile(url: file.url).load().state == second)
    }

    @Test func settingsTakeTheirDefaultsForWhatIsMissingOrUnknown() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(AppSettings.self, from: Data("{}".utf8)) == AppSettings())
        #expect(try decoder.decode(InspectorConfiguration.self, from: Data("{}".utf8)) == InspectorConfiguration())
        #expect(try decoder.decode(SessionSummaryOptions.self, from: Data("{}".utf8)) == SessionSummaryOptions())

        let rules = try decoder.decode(RuleConfiguration.self, from: Data("""
            {"disabledRules": ["lockfile", "licenseChange"], "massDeletionThreshold": "lots", "hugeFileBytes": 5}
            """.utf8))
        #expect(rules.disabledRules == [.lockfile])
        #expect(rules.massDeletionThreshold == RuleConfiguration().massDeletionThreshold)
        #expect(rules.hugeFileBytes == 5)

        let inspector = try decoder.decode(InspectorConfiguration.self, from: Data("""
            {"maxContentScanFiles": 10, "rules": {"scopePrefixes": ["Sources"]}, "followsSubmodules": true}
            """.utf8))
        #expect(inspector.maxContentScanFiles == 10)
        #expect(inspector.rules.scopePrefixes == ["Sources"])
        #expect(inspector.largeFileLimit == InspectorConfiguration().largeFileLimit)
    }
}

// MARK: The notice at launch

extension StateFileTests {
    @Test func saysNothingWhenTheFileReadsInFullOrIsMissing() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = StateFile(url: folder.appendingPathComponent("state.json"))
        #expect(file.load().notice(stateFile: file.url) == nil)

        try fixture("1.1.0").write(to: file.url)
        #expect(file.load().notice(stateFile: file.url) == nil)
    }

    @Test func pointsAtTheCopyKeptAside() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = StateFile(url: folder.appendingPathComponent("state.json"))
        try Data("{\"repositories\": [".utf8).write(to: file.url)

        let loaded = file.load()
        let notice = try #require(loaded.notice(stateFile: file.url))
        let aside = try #require(loaded.keptAside)
        #expect(notice.file == aside)
        #expect(notice.message == "It opened what it could. It kept a copy of the file as it was.")
    }

    @Test func saysWhenItOpenedThePreviousCopy() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = StateFile(url: folder.appendingPathComponent("state.json"))
        try Data("not json".utf8).write(to: file.url)
        try fixture("1.1.0").write(to: file.previousURL)

        let loaded = file.load()
        let notice = try #require(loaded.notice(stateFile: file.url))
        #expect(notice.file == loaded.keptAside)
        #expect(notice.message.hasPrefix("It opened what it saved the time before, so your latest changes may be missing."))
    }

    @Test func saysWhenANewerMimamoriSavedIt() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = StateFile(url: folder.appendingPathComponent("state.json"))
        try fixture("future").write(to: file.url)

        let notice = try #require(file.load().notice(stateFile: file.url))
        #expect(notice.message.hasPrefix("It was saved by a newer Mimamori, so this one opened what it could."))
    }

    @Test func saysWhenNothingCouldBeKept() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = StateFile(url: folder.appendingPathComponent("state.json"))
        try fixture("1.1.0").write(to: file.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.url.path) }

        let notice = try #require(file.load().notice(stateFile: file.url))
        #expect(notice.file == file.url)
        #expect(notice.message.contains("won't be saved"))
    }
}
