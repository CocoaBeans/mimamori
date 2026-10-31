import Foundation
import Testing
@testable import VigilCore

@Suite("Attention rules")
struct AttentionRulesTests {
    let config = RuleConfiguration()

    private func change(_ path: String, kind: ChangeKind = .modified, additions: Int? = 1, deletions: Int? = 0,
                        oldMode: String = "100644", newMode: String = "100644", binary: Bool = false) -> FileChange {
        FileChange(path: path, kind: kind, oldMode: kind == .added ? "000000" : oldMode, newMode: kind == .deleted ? "000000" : newMode,
                   oldOID: kind == .added ? nil : "a", newOID: kind == .deleted ? nil : "b",
                   additions: binary ? nil : additions, deletions: binary ? nil : deletions, isBinary: binary)
    }

    private func rules(_ change: FileChange, size: Int64? = nil) -> Set<RuleID> {
        Set(AttentionRules.pathFlags(for: change, config: config, fileSize: size).map(\.rule))
    }

    @Test func pathRules() {
        #expect(rules(change("package-lock.json")).contains(.lockfile))
        #expect(rules(change(".env")).contains(.secretsFile))
        #expect(rules(change("config/.env.production")).contains(.secretsFile))
        #expect(rules(change("certs/server.pem", kind: .added)).contains(.secretsFile))
        #expect(rules(change(".github/workflows/ci.yml")).contains(.ciConfig))
        #expect(rules(change("CLAUDE.md")).contains(.agentConfig))
        #expect(rules(change(".claude/settings.json")).contains(.agentConfig))
        #expect(rules(change(".gitignore")).contains(.gitConfig))
        #expect(rules(change("App.xcodeproj/project.pbxproj")).contains(.buildConfig))
        #expect(rules(change("src/main.swift")).isEmpty)
    }

    @Test func envTemplateIsOnlyInfo() {
        let flags = AttentionRules.pathFlags(for: change(".env.example"), config: config)
        #expect(flags.first?.rule == .secretsFile)
        #expect(flags.first?.severity == .info)
    }

    @Test func deletedImportantFilesSayTheyAreGone() {
        func messages(_ path: String) -> [String] {
            AttentionRules.pathFlags(for: change(path, kind: .deleted, additions: 0, deletions: 10), config: config)
                .filter { $0.rule != .massDeletion }.map(\.message)
        }
        #expect(messages("package-lock.json") == ["Dependency lockfile deleted"])
        #expect(messages(".github/workflows/ci.yml") == ["GitHub Actions workflow deleted"])
        #expect(messages("AGENTS.md") == ["Agent instructions deleted"])
        #expect(messages(".gitignore") == ["Ignore rules deleted"])
        #expect(messages("App.xcodeproj/project.pbxproj") == ["Xcode project file deleted"])
        #expect(messages("requirements.txt") == ["Dependency list deleted"])
        // Still flagged as before, at the same severity.
        let workflow = AttentionRules.pathFlags(for: change(".github/workflows/ci.yml", kind: .deleted), config: config)
        #expect(workflow.contains { $0.rule == .ciConfig && $0.severity == .warning })
        // Edits keep their wording.
        let edited = AttentionRules.pathFlags(for: change("package-lock.json"), config: config)
        #expect(edited.map(\.message) == ["Dependency lockfile changed"])
    }

    @Test func aDeletedSecretsFileIsAWarningToRotate() {
        let deleted = AttentionRules.pathFlags(for: change(".env", kind: .deleted, additions: 0, deletions: 3), config: config)
        let secret = try? #require(deleted.first { $0.rule == .secretsFile })
        #expect(secret?.severity == .warning)
        #expect(secret?.message == "Environment file deleted: rotate it if it was committed")
        let template = AttentionRules.pathFlags(for: change(".env.example", kind: .deleted), config: config)
        #expect(template.first { $0.rule == .secretsFile }?.message == "Environment file template deleted")
        #expect(template.first { $0.rule == .secretsFile }?.severity == .info)
        // Adding one is still critical.
        let added = AttentionRules.pathFlags(for: change(".env", kind: .added), config: config)
        #expect(added.first { $0.rule == .secretsFile }?.severity == .critical)
    }

    @Test func deletionsAndSizes() {
        #expect(rules(change("tests/test_app.py", kind: .deleted, additions: 0, deletions: 80)).isSuperset(of: [.testDeleted, .massDeletion]))
        let big = AttentionRules.pathFlags(for: change("src/a.py", deletions: 1200), config: config)
        #expect(big.contains { $0.rule == .massDeletion && $0.severity == .critical })
        #expect(rules(change("gen.txt", additions: 5000)).contains(.largeAddition))
        #expect(rules(change("logo.png", binary: true)).contains(.binary))
        #expect(rules(change("data.bin"), size: 5_000_000).contains(.hugeFile))
        #expect(rules(change("run.sh", oldMode: "100644", newMode: "100755")).contains(.modeChange))
    }

    @Test func scopeRule() {
        var scoped = RuleConfiguration()
        scoped.scopePrefixes = ["src/"]
        let outside = AttentionRules.pathFlags(for: change("docs/readme.md"), config: scoped)
        let inside = AttentionRules.pathFlags(for: change("src/a.swift"), config: scoped)
        #expect(outside.contains { $0.rule == .outsideScope })
        #expect(!inside.contains { $0.rule == .outsideScope })
    }

    private func diff(adding lines: [String]) -> FileDiff {
        let diffLines = lines.enumerated().map { DiffLine(id: $0.offset, kind: .addition, text: $0.element, oldNumber: nil, newNumber: $0.offset + 1) }
        return FileDiff(oldPath: "f", newPath: "f", hunks: [DiffHunk(id: 0, header: "@@", oldStart: 1, oldCount: 0, newStart: 1, newCount: lines.count, lines: diffLines)])
    }

    @Test func contentRules() {
        let flags = AttentionRules.contentFlags(in: diff(adding: [
            "AWS_KEY = \"AKIAIOSFODNN7EXAMPLE\"",
            "password = \"correct-horse-battery-staple\"",
            "password = os.environ.get(\"PASSWORD\")",
            "@pytest.mark.skip",
            "// eslint-disable-next-line",
            "console.log('debug')",
            "<<<<<<< HEAD",
            "=======",
            ">>>>>>> branch",
        ]), config: config)
        let byRule = Dictionary(grouping: flags, by: \.rule)
        #expect(byRule[.secretContent]?.count == 2)
        #expect(byRule[.secretContent]?.first?.line == 1)
        #expect(byRule[.testDisabled] != nil)
        #expect(byRule[.lintSuppressed] != nil)
        #expect(byRule[.debugLeftover] != nil)
        #expect(byRule[.conflictMarkers]?.first?.message.contains("3 places") == true)
    }

    @Test func swiftUIDisabledModifierIsNotATestFlag() {
        let flags = AttentionRules.contentFlags(in: diff(adding: [
            "    Button(\"Save\") { save() }.disabled(!isValid)",
            "    @Test(\"skips\", .disabled(\"flaky\")) func skipped() {}",
        ]), config: config)
        let testFlags = flags.filter { $0.rule == .testDisabled }
        #expect(testFlags.count == 1)
        #expect(testFlags.first?.line == 2)
    }

    @Test func markersNeedWordBoundaries() {
        let flags = AttentionRules.contentFlags(in: diff(adding: [
            "iconutil.waitUntilExit()",
            "let profit = computeProfit(x)",
            "xit('is skipped', () => {})",
        ]), config: config)
        let testFlags = flags.filter { $0.rule == .testDisabled }
        #expect(testFlags.count == 1)
        #expect(testFlags.first?.line == 3)
    }

    @Test func placeholdersAreNotSecrets() {
        let flags = AttentionRules.contentFlags(in: diff(adding: [
            "api_key = \"your-api-key-here\"",
            "password = \"${DB_PASSWORD}\"",
            "token = process.env.TOKEN_VALUE_HERE",
        ]), config: config)
        #expect(!flags.contains { $0.rule == .secretContent })
    }
}

@Suite("State differ")
struct StateDifferTests {
    private func state(head: String?, branch: String? = "main", changes: [FileChange]) -> WorktreeState {
        WorktreeState(timestamp: Date(), branch: BranchInfo(headOID: head, branch: branch),
                      baseline: ResolvedBaseline(baseline: .head, treeish: head, label: "HEAD"),
                      defaultBranch: "main", changes: changes, headChanges: changes, excludedLargeFiles: [], shadowTreeOID: nil)
    }

    @Test func fileEvents() {
        let before = state(head: "h1", changes: [
            FileChange(path: "a.txt", kind: .modified, oldOID: "1", newOID: "2", additions: 1, deletions: 1),
            FileChange(path: "gone.txt", kind: .modified, oldOID: "1", newOID: "3"),
        ])
        let after = state(head: "h1", changes: [
            FileChange(path: "a.txt", kind: .modified, oldOID: "1", newOID: "4", additions: 2, deletions: 1),
            FileChange(path: "new.txt", kind: .added, newOID: "5", additions: 10, deletions: 0),
            FileChange(path: "del.txt", kind: .deleted, oldOID: "6"),
        ])
        let events = StateDiffer.events(previous: before, current: after, worktreePath: "/r", commits: [])
        let kinds = Dictionary(grouping: events, by: \.kind)
        #expect(kinds[.modified]?.first?.path == "a.txt")
        #expect(kinds[.created]?.first?.path == "new.txt")
        #expect(kinds[.deleted]?.first?.path == "del.txt")
        #expect(kinds[.reverted]?.first?.path == "gone.txt")
    }

    @Test func commitEventsReplaceReverts() {
        let before = state(head: "h1", changes: [FileChange(path: "a.txt", kind: .modified, oldOID: "1", newOID: "2")])
        let after = state(head: "h2", changes: [])
        let events = StateDiffer.events(previous: before, current: after, worktreePath: "/r",
                                        commits: [CommitSummary(oid: "h2", subject: "Do the thing")])
        #expect(events.count == 1)
        #expect(events[0].kind == .committed)
        #expect(events[0].title == "Do the thing")
    }

    @Test func newFlagsBecomeEvents() {
        var flagged = FileChange(path: ".env", kind: .added, newOID: "1", additions: 1)
        flagged.flags = [AttentionFlag(rule: .secretsFile, message: "Environment file")]
        let before = state(head: "h1", changes: [])
        let after = state(head: "h1", changes: [flagged])
        let events = StateDiffer.events(previous: before, current: after, worktreePath: "/r", commits: [])
        #expect(events.contains { $0.kind == .flagged && $0.severity == .critical })
    }
}
