import Foundation
import Testing
@testable import VigilCore

@Suite("Commit log parsing")
struct CommitLogParserTests {
    @Test func readsCommitsWithTheirSize() {
        let text = "\u{1e}aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\u{1f}bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb cccccccccccccccccccccccccccccccccccccccc\u{1f}Kevin\u{1f}1793400000\u{1f}Merge branch 'main' into plan\n\n 2 files changed, 10 insertions(+), 1 deletion(-)\n"
            + "\u{1e}bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\u{1f}dddddddddddddddddddddddddddddddddddddddd\u{1f}Hermes\u{1f}1793300000\u{1f}Remove the old notes\n\n 1 file changed, 4 deletions(-)\n"
            + "\u{1e}dddddddddddddddddddddddddddddddddddddddd\u{1f}\u{1f}Kevin\u{1f}1793200000\u{1f}Empty start\n"
        let commits = CommitLogParser.parse(text)
        #expect(commits.count == 3)
        #expect(commits[0].isMerge)
        #expect(commits[0].subject == "Merge branch 'main' into plan")
        #expect(commits[0].shortOID == "aaaaaaa")
        #expect(commits[0].filesChanged == 2 && commits[0].additions == 10 && commits[0].deletions == 1)
        #expect(commits[1].author == "Hermes")
        #expect(commits[1].filesChanged == 1 && commits[1].additions == 0 && commits[1].deletions == 4)
        #expect(commits[1].date == Date(timeIntervalSince1970: 1_793_300_000))
        #expect(commits[2].parents.isEmpty)
        #expect(commits[2].filesChanged == 0)
        #expect(CommitLogParser.parse("").isEmpty)
    }
}

/// Exercises the real git binary against a throwaway repository.
@Suite("Commit history (integration)", .serialized)
struct CommitHistoryIntegrationTests {
    struct Sandbox {
        let git: GitClient
        let root: URL
        let repo: URL

        func sh(_ args: [String]) async throws {
            try await git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + args, in: repo)
        }

        func write(_ path: String, _ contents: String) throws {
            let url = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        func commit(_ message: String) async throws {
            try await sh(["add", "-A"])
            try await sh(["commit", "-q", "-m", message])
        }

        func inspector() async throws -> WorktreeInspector {
            try await WorktreeInspector(git: git, worktree: repo, shadowIndexDirectory: root.appendingPathComponent("index"))
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    /// main: "Initial commit". plan: renames the notes, then adds a secret.
    private func makeSandbox() async throws -> Sandbox {
        let git = try #require(await GitClient.locate())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vigil-commits-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let box = Sandbox(git: git, root: root, repo: repo)
        try await box.sh(["init", "-q", "-b", "main"])
        try box.write("README.md", "# Demo\n")
        try box.write("notes.txt", "one\ntwo\nthree\nfour\nfive\n")
        try await box.commit("Initial commit")
        try await box.sh(["checkout", "-q", "-b", "plan"])
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try await box.sh(["mv", "notes.txt", "docs/notes.txt"])
        try await box.commit("Move the notes")
        try box.write(".env", "API_KEY=sk-live-abcdefghijklmnopqrstuvwxyz0123\n")
        try box.write("README.md", "# Demo\n\nNow with settings.\n")
        try await box.commit("Add settings")
        return box
    }

    @Test func aBranchListsWhatItAddedThenEarlierHistory() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        let inspector = try await box.inspector()
        let state = try await inspector.refresh(baseline: .head)
        let history = try await inspector.history(branch: state.branch)

        #expect(history.head == state.branch.headOID)
        #expect(history.reference == "main")
        #expect(history.sinceBranchPoint.map(\.subject) == ["Add settings", "Move the notes"])
        #expect(history.earlier.map(\.subject) == ["Initial commit"])
        #expect(!history.hasMore)
        let settings = try #require(history.sinceBranchPoint.first)
        #expect(settings.filesChanged == 2 && settings.additions == 3 && settings.deletions == 0)
        #expect(settings.author == "Test")

        // Short ids from the activity feed resolve to the same commit.
        #expect(await inspector.commit(settings.shortOID)?.oid == settings.oid)
        #expect(await inspector.commit("no-such-revision") == nil)
        #expect(await inspector.message(of: settings) == "Add settings")
    }

    @Test func aCommitsFilesAreFlaggedAndDiffedAgainstItsParent() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        let inspector = try await box.inspector()
        let history = try await inspector.history(branch: try await inspector.refresh(baseline: .head).branch)

        let settings = try #require(history.commit(history.sinceBranchPoint[0].oid))
        let changes = try await inspector.changes(in: settings)
        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
        #expect(Set(byPath.keys) == [".env", "README.md"])
        #expect(byPath[".env"]?.kind == .added)
        #expect(byPath[".env"]?.flags.contains { $0.rule == .secretContent } == true)
        #expect(byPath["README.md"]?.additions == 2)
        let diff = try await inspector.diff(for: try #require(byPath["README.md"]), in: settings)
        #expect(diff?.hunks.first?.lines.contains { $0.text == "Now with settings." } == true)

        let move = try await inspector.changes(in: history.sinceBranchPoint[1])
        #expect(move.count == 1)
        #expect(move.first?.kind == .renamed)
        #expect(move.first?.oldPath == "notes.txt")
        #expect(move.first?.path == "docs/notes.txt")

        // The first commit is compared with an empty tree.
        let initial = try await inspector.changes(in: history.earlier[0])
        #expect(Set(initial.map(\.path)) == ["README.md", "notes.txt"])
        #expect(initial.allSatisfy { $0.kind == .added })
    }

    @Test func aMergeIsMeasuredAgainstItsFirstParent() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        try await box.sh(["checkout", "-q", "main"])
        try box.write("CHANGELOG.md", "- started\n")
        try await box.commit("Start a changelog")
        try await box.sh(["checkout", "-q", "plan"])
        try await box.sh(["merge", "-q", "--no-ff", "--no-edit", "main"])
        let inspector = try await box.inspector()
        let history = try await inspector.history(branch: try await inspector.refresh(baseline: .head).branch)

        // The merge base moved up to main's new commit.
        #expect(history.sinceBranchPoint.map(\.subject).first?.hasPrefix("Merge branch 'main'") == true)
        let merge = history.sinceBranchPoint[0]
        #expect(merge.isMerge)
        #expect(merge.filesChanged == 1 && merge.additions == 1)
        let changes = try await inspector.changes(in: merge)
        #expect(changes.map(\.path) == ["CHANGELOG.md"])
    }

    @Test func theDefaultBranchListsItsHistoryInPages() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        try await box.sh(["checkout", "-q", "main"])
        for number in 1...3 {
            try box.write("log.txt", String(repeating: "line\n", count: number))
            try await box.commit("Entry \(number)")
        }
        let inspector = try await box.inspector()
        let first = try await inspector.history(branch: try await inspector.refresh(baseline: .head).branch, limit: 2)
        // No upstream to measure main against: everything is history.
        #expect(first.reference == nil)
        #expect(first.sinceBranchPoint.isEmpty)
        #expect(first.earlier.map(\.subject) == ["Entry 3", "Entry 2"])
        #expect(first.hasMore)
        let second = try await inspector.loadingMore(of: first, limit: 2)
        #expect(second.earlier.map(\.subject) == ["Entry 3", "Entry 2", "Entry 1", "Initial commit"])
        #expect(second.hasMore)
        let third = try await inspector.loadingMore(of: second, limit: 2)
        #expect(third.earlier.count == 4)
        #expect(!third.hasMore)
    }

    @Test func anEmptyRepositoryHasNoHistory() async throws {
        let git = try #require(await GitClient.locate())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vigil-commits-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await git.run(["init", "-q", "-b", "main"], in: repo)
        let inspector = try await WorktreeInspector(git: git, worktree: repo, shadowIndexDirectory: root.appendingPathComponent("index"))
        let history = try await inspector.history(branch: try await inspector.refresh(baseline: .head).branch)
        #expect(history.all.isEmpty)
        #expect(history.head == nil)
    }
}
