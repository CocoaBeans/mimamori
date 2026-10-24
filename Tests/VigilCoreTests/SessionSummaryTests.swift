import Foundation
import Testing
@testable import VigilCore

@Suite("Session summary")
struct SessionSummaryTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    private func change(_ path: String, _ kind: ChangeKind, _ add: Int, _ del: Int, flags: [AttentionFlag] = [],
                        oldPath: String? = nil) -> FileChange {
        FileChange(path: path, oldPath: oldPath, kind: kind, additions: add, deletions: del, flags: flags)
    }

    private func sample() -> SessionSummary {
        let secret = AttentionFlag(rule: .secretContent, message: "AWS access key", line: 3)
        let lockfile = AttentionFlag(rule: .lockfile, message: "Dependency lockfile changed")
        let files: [SessionSummary.File] = [
            .init(change: change("Sources/Cart.swift", .modified, 12, 2), review: .reviewed(at: at(0)),
                  attribution: ChangeAttribution(agent: "Claude Code", tool: "Edit", at: at(5))),
            .init(change: change("config/credentials.txt", .added, 1, 0, flags: [secret])),
            .init(change: change("package-lock.json", .modified, 40, 10, flags: [lockfile])),
            .init(change: change("src/new.py", .renamed, 0, 0, oldPath: "src/old.py"),
                  review: .changedSinceReview(ReviewMark(fingerprint: "x", blob: "b", reviewedAt: at(0)))),
            .init(change: change("README.md", .deleted, 0, 4)),
        ]
        let activity = [
            ActivityEntry(date: at(10), worktreePath: "/w", kind: .agentTurn, title: "Claude Code started a turn", detail: "add a discount"),
            ActivityEntry(date: at(11), worktreePath: "/w", kind: .agentTool, title: "Claude Code: Edit", detail: "Sources/Cart.swift"),
            ActivityEntry(date: at(12), worktreePath: "/w", kind: .modified, path: "Sources/Cart.swift", title: "Sources/Cart.swift"),
            ActivityEntry(date: at(13), worktreePath: "/w", kind: .agentAttention, title: "Claude Code needs permission: Bash", detail: "git push"),
            ActivityEntry(date: at(14), worktreePath: "/w", kind: .committed, title: "Add a discount", detail: "abc1234"),
            ActivityEntry(date: at(15), worktreePath: "/w", kind: .agentTurn, title: "Claude Code finished a turn", detail: "1 tool calls in 5s"),
        ]
        return SessionSummary(
            title: "feature/discount", repository: "shop", worktreePath: "/w", baselineLabel: "since start at 9:00 AM",
            generatedAt: at(100), files: files,
            commits: [CommitSummary(oid: "abc1234def5678", subject: "Add a discount")],
            activity: activity, activitySince: at(0),
            agent: .init(names: ["Claude Code"], state: "ready for your next prompt", toolCallNoun: "edits and commands"))
    }

    @Test func overviewCountsWhatHappened() {
        let text = sample().markdown(timeZone: utc, locale: posix)
        #expect(text.hasPrefix("# Session summary: feature/discount\n"))
        #expect(text.contains("**shop** · `/w` · changes since start at 9:00 AM"))
        #expect(text.contains("- **5 files changed** (+53 −16): 1 added, 2 modified, 1 deleted, 1 renamed"))
        #expect(text.contains("- **2 need attention** (1 critical)"))
        #expect(text.contains("- **Reviewed 1 of 5**; 1 changed since your review"))
        #expect(text.contains("- **Agent:** Claude Code · 1 turn, 1 edits and commands, 1 permission request · now ready for your next prompt"))
        #expect(text.contains("- **1 commit** since start at 9:00 AM\n"))
    }

    @Test func attentionListsCriticalFirstWithLines() throws {
        let text = sample().markdown(timeZone: utc, locale: posix)
        let section = try #require(text.components(separatedBy: "## Needs attention\n\n").last?.components(separatedBy: "\n\n").first)
        let lines = section.split(separator: "\n").map(String.init)
        #expect(lines == [
            "- **Critical** `config/credentials.txt`: AWS access key (line 3)",
            "- **Warning** `package-lock.json`: Dependency lockfile changed",
        ])
    }

    @Test func filesShowKindCountsReviewAndAttribution() {
        let text = sample().markdown(timeZone: utc, locale: posix)
        #expect(text.contains("- `Sources/Cart.swift`: modified · +12 −2 · reviewed · Claude Code · Edit"))
        #expect(text.contains("- `src/old.py` → `src/new.py`: renamed · +0 −0 · changed since your review"))
        #expect(text.contains("## Not yet reviewed\n\n- `README.md`\n- `config/credentials.txt`\n- `package-lock.json`\n- `src/new.py` (changed since your review)\n"))
        #expect(text.contains("## Commits\n\n- `abc1234` Add a discount\n"))
    }

    @Test func activityKeepsAgentWorkAndCommitsButNotFileChurn() {
        let text = sample().markdown(timeZone: utc, locale: posix)
        #expect(text.contains("_What Vigil saw since"))
        #expect(text.contains("· Claude Code started a turn: add a discount"))
        #expect(text.contains("· Claude Code needs permission: Bash: git push"))
        #expect(text.contains("· Add a discount: abc1234"))
        #expect(!text.contains("· Sources/Cart.swift\n"))   // the plain file event is left to the Files section
    }

    @Test func activityPathsAreRelativeToTheWorktree() {
        var summary = sample()
        summary.activity = [ActivityEntry(date: at(1), worktreePath: "/w", kind: .agentTool, title: "Claude Code: Edit",
                                          detail: "/w/Sources/Cart.swift")]
        #expect(summary.markdown(timeZone: utc, locale: posix).contains("· Claude Code: Edit: Sources/Cart.swift\n"))
    }

    @Test func optionsLeaveSectionsOut() {
        var options = SessionSummaryOptions()
        options.files = false
        options.activity = false
        options.commits = false
        let text = sample().markdown(options: options, timeZone: utc, locale: posix)
        #expect(!text.contains("## Files"))
        #expect(!text.contains("## Agent activity"))
        #expect(!text.contains("## Commits"))
        #expect(text.contains("## Needs attention"))
    }

    @Test func notYetReviewedOnlyAppearsOnceReviewingStarted() {
        var summary = sample()
        summary.files = summary.files.map { SessionSummary.File(change: $0.change) }
        let text = summary.markdown(timeZone: utc, locale: posix)
        #expect(!text.contains("## Not yet reviewed"))
        #expect(!text.contains("Reviewed 0"))
    }

    @Test func activityIsCappedToTheMostRecent() {
        var summary = sample()
        var options = SessionSummaryOptions()
        options.maxActivityEntries = 2
        let text = summary.markdown(options: options, timeZone: utc, locale: posix)
        #expect(text.contains("_3 earlier entries not shown._"))
        #expect(!text.contains("started a turn: add a discount"))
        #expect(text.contains("finished a turn"))
        summary.activity = []
        #expect(!summary.markdown(timeZone: utc, locale: posix).contains("## Agent activity"))
    }

    @Test func diffsAreFencedAndBudgeted() {
        var summary = sample()
        summary.diffs = [
            "Sources/Cart.swift": "@@ -1 +1 @@\n-a\n+b\n",
            "package-lock.json": String(repeating: "+x\n", count: 50),
            "README.md": "has ``` inside\n",
        ]
        var options = SessionSummaryOptions()
        options.diffs = true
        options.maxDiffLines = 20
        let text = summary.markdown(options: options, timeZone: utc, locale: posix)
        #expect(text.contains("### `Sources/Cart.swift`\n\n```diff\n@@ -1 +1 @@\n-a\n+b\n```\n"))
        #expect(text.contains("````diff\nhas ``` inside\n````"))   // a longer fence around backticks
        #expect(text.contains("_Diffs left out to keep this summary short: `package-lock.json`._"))
    }

    @Test func pathsWithBackticksStayCode() {
        var summary = sample()
        summary.files = [.init(change: change("odd`name.txt", .added, 1, 0))]
        #expect(summary.markdown(timeZone: utc, locale: posix).contains("``odd`name.txt``"))
    }

    @Test func emptySessionsSaySo() {
        let summary = SessionSummary(title: "main", repository: "shop", worktreePath: "/w", baselineLabel: "HEAD abc1234", files: [])
        let text = summary.markdown(timeZone: utc, locale: posix)
        #expect(text.contains("- **No changes** against HEAD abc1234."))
        #expect(!text.contains("## Files"))
    }
}
