import Foundation
import Testing
@testable import MimamoriCore

/// Exercises the real git binary against a throwaway repository.
@Suite("Worktree inspector (integration)", .serialized)
struct InspectorIntegrationTests {
    struct Sandbox {
        let git: GitClient
        let root: URL
        let repo: URL
        let indexDir: URL

        func sh(_ args: [String]) async throws {
            try await git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + args, in: repo)
        }

        func write(_ path: String, _ contents: String) throws {
            let url = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        func remove(_ path: String) throws {
            try FileManager.default.removeItem(at: repo.appendingPathComponent(path))
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeSandbox() async throws -> Sandbox {
        let git = try #require(await GitClient.locate())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimamori-test-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        let indexDir = root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let box = Sandbox(git: git, root: root, repo: repo, indexDir: indexDir)
        try await box.sh(["init", "-q", "-b", "main"])
        try box.write("README.md", "# Demo\n")
        try box.write("src/app.py", "def greet(name):\n    return f\"Hello, {name}!\"\n")
        try box.write(".gitignore", "ignored/\n")
        try await box.sh(["add", "-A"])
        try await box.sh(["commit", "-q", "-m", "Initial commit"])
        return box
    }

    @Test func uncommittedChangesIncludeUntrackedFiles() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        try box.write("src/app.py", "def greet(name):\n    return f\"Howdy, {name}!\"\n\n\ndef add(a, b):\n    return a + b\n")
        try box.write("notes.txt", "untracked\n")
        try box.write("ignored/junk.txt", "should not appear\n")
        try box.write(".env", "API_KEY=sk-live-abcdefghijklmnopqrstuvwxyz0123\n")
        try box.remove("README.md")

        let inspector = try await WorktreeInspector(git: box.git, worktree: box.repo, shadowIndexDirectory: box.indexDir)
        let state = try await inspector.refresh(baseline: .head)

        let byPath = Dictionary(uniqueKeysWithValues: state.changes.map { ($0.path, $0) })
        #expect(Set(byPath.keys) == ["src/app.py", "notes.txt", ".env", "README.md"])
        #expect(byPath["src/app.py"]?.kind == .modified)
        #expect(byPath["src/app.py"]?.additions == 5)
        #expect(byPath["src/app.py"]?.deletions == 1)
        #expect(byPath["notes.txt"]?.kind == .added)
        #expect(byPath["notes.txt"]?.isUntracked == true)
        #expect(byPath["README.md"]?.kind == .deleted)
        #expect(byPath[".env"]?.flags.contains { $0.rule == .secretsFile } == true)
        #expect(byPath[".env"]?.flags.contains { $0.rule == .secretContent } == true)
        #expect(state.branch.branch == "main")
        #expect(state.branch.headSubject == "Initial commit")
        #expect(state.baseline.isAvailable)

        // The repository's own index must stay untouched.
        let status = try await box.git.status(in: box.repo)
        #expect(status.entries.allSatisfy { !$0.isStaged })

        let diff = try await inspector.diff(for: byPath["src/app.py"]!, base: state.baseline.treeish!)
        #expect(diff?.hunks.isEmpty == false)
        #expect(diff?.additions == 5)
    }

    @Test func branchPointAndStartBaselines() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        try await box.sh(["checkout", "-q", "-b", "feature"])
        try box.write("feature.txt", "one\n")
        try await box.sh(["add", "-A"])
        try await box.sh(["commit", "-q", "-m", "Add feature file"])

        let inspector = try await WorktreeInspector(git: box.git, worktree: box.repo, shadowIndexDirectory: box.indexDir)

        // Nothing uncommitted, but the branch point view shows the committed file.
        let head = try await inspector.refresh(baseline: .head)
        #expect(head.changes.isEmpty)
        let branchPoint = try await inspector.refresh(baseline: .branchPoint)
        #expect(branchPoint.baseline.isAvailable)
        #expect(branchPoint.changes.map(\.path) == ["feature.txt"])

        // Mark start, then make more changes: only those show in the start view.
        let start = try await inspector.takeSnapshot(markStart: true)
        #expect(start?.isStart == true)
        try box.write("after-start.txt", "two\n")
        let sinceStart = try await inspector.refresh(baseline: .start)
        #expect(sinceStart.baseline.isAvailable)
        #expect(sinceStart.changes.map(\.path) == ["after-start.txt"])

        // Snapshots are listed and unchanged trees are not re-snapshotted.
        let second = try await inspector.takeSnapshot()
        #expect(second != nil)
        let third = try await inspector.takeSnapshot()
        #expect(third == nil)
        let snapshots = await inspector.snapshots()
        #expect(snapshots.count == 2)
        #expect(snapshots.contains { $0.isStart })

        // Commits between HEADs are reported for the feed.
        let before = await box.git.revParse("HEAD", in: box.repo)
        try await box.sh(["add", "-A"])
        try await box.sh(["commit", "-q", "-m", "Second commit"])
        let after = await box.git.revParse("HEAD", in: box.repo)
        let commits = await inspector.commits(from: before, to: after)
        #expect(commits.map(\.subject) == ["Second commit"])

        await inspector.deleteAllSnapshots()
        #expect(await inspector.snapshots().isEmpty)
    }

    /// A refresh and a snapshot both run `git add` on the shadow index, and two at once fail on
    /// git's index.lock. Each round starts a new shadow index over 1,500 new files, as when a
    /// repository is first added, so the two would overlap if the inspector let them.
    @Test func refreshAndSnapshotTakeTurnsAtTheShadowIndex() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        for number in 0..<1500 {
            try box.write("many/\(number / 100)/file\(number).txt", "line \(number)\n")
        }
        for round in 0..<3 {
            let indexDir = box.root.appendingPathComponent("index-\(round)")
            let inspector = try await WorktreeInspector(git: box.git, worktree: box.repo, shadowIndexDirectory: indexDir)
            async let refreshed = inspector.refresh(baseline: .head)
            async let snapshot = inspector.takeSnapshot(force: true)
            let (state, record) = try await (refreshed, snapshot)
            #expect(state.changes.count == 1500)
            #expect(record != nil)
        }
    }

    @Test func snapshotDiskUsageCountsOnlyWhatSnapshotsAloneKeep() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        let inspector = try await WorktreeInspector(git: box.git, worktree: box.repo, shadowIndexDirectory: box.indexDir)
        #expect(await inspector.snapshotDiskUsage() == 0)

        // An untracked file only the snapshot keeps. Random bytes, so compression cannot hide it.
        let bytes = Data((0..<200_000).map { _ in UInt8.random(in: 0...255) })
        try bytes.write(to: box.repo.appendingPathComponent("scratch.bin"))
        _ = try await inspector.takeSnapshot(force: true)
        let withScratch = try #require(await inspector.snapshotDiskUsage())
        #expect(withScratch > 190_000)

        // Once a branch has the file too, deleting the snapshot would not free it.
        try await box.sh(["add", "scratch.bin"])
        try await box.sh(["commit", "-q", "-m", "Keep scratch"])
        let committed = try #require(await inspector.snapshotDiskUsage())
        #expect(committed < 10_000)

        await inspector.deleteAllSnapshots()
        #expect(await inspector.snapshotDiskUsage() == 0)
    }

    @Test func ignoredFoldersAreLearnedSoTheirChangesNeedNoGit() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        try box.write(".gitignore", "ignored/\n.build/\nlogs/\n*.o\n")
        try box.write("logs/keep.txt", "kept\n")
        try await box.sh(["add", "-A"])
        try await box.sh(["add", "-f", "logs/keep.txt"])
        try await box.sh(["commit", "-q", "-m", "Ignore rules"])
        try box.write(".build/debug/obj/a.o", "x")
        try box.write("pkg/Foo/.build/z", "x")
        try box.write("logs/new.log", "x")
        let inspector = try await WorktreeInspector(git: box.git, worktree: box.repo, shadowIndexDirectory: box.indexDir)

        #expect(await inspector.allIgnored([".build/debug/obj/a.o", "pkg/Foo/.build/z"]))
        #expect(await inspector.ignoredFolders == [".build", "pkg/Foo/.build"])
        // Ignored, but git tracks a file in there: the folder stays watched.
        #expect(await inspector.allIgnored(["logs/new.log"]))
        #expect(await inspector.ignoredFolders.contains("logs") == false)
        #expect(await inspector.allIgnored(["src/app.py"]) == false)
        #expect(await inspector.allIgnored([".build/debug/obj/a.o", "src/app.py"]) == false)
        // Known folders answer without asking git; a path that merely starts the same does not count.
        #expect(WorktreeInspector.isInside(".build/release/b.o", await inspector.ignoredFolders))
        #expect(WorktreeInspector.isInside(".build", await inspector.ignoredFolders))
        #expect(!WorktreeInspector.isInside(".buildrc", await inspector.ignoredFolders))
        #expect(!WorktreeInspector.isInside("pkg/Foo/Sources/a.swift", await inspector.ignoredFolders))

        await inspector.forgetIgnoredFolders()
        #expect(await inspector.ignoredFolders.isEmpty)
    }

    @Test func linkedWorktreeIsDiscovered() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        let linked = box.root.appendingPathComponent("linked")
        try await box.sh(["worktree", "add", "-q", "-b", "wt-branch", linked.path])
        let list = try await box.git.worktrees(in: box.repo)
        #expect(list.count == 2)
        #expect(list[0].isMain)
        #expect(list[1].branch == "wt-branch")

        let inspector = try await WorktreeInspector(git: box.git, worktree: linked, shadowIndexDirectory: box.indexDir)
        #expect(inspector.layout.isLinkedWorktree)
        try "x\n".write(to: linked.appendingPathComponent("only-here.txt"), atomically: true, encoding: .utf8)
        let state = try await inspector.refresh(baseline: .head)
        #expect(state.changes.map(\.path) == ["only-here.txt"])
        #expect(state.branch.branch == "wt-branch")
    }

    @Test func diffSinceReviewShowsOnlyTheLaterEdit() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        let inspector = try await WorktreeInspector(git: box.git, worktree: box.repo, shadowIndexDirectory: box.indexDir)

        // First edit, which you review.
        try box.write("src/app.py", "def greet(name):\n    return f\"Howdy, {name}!\"\n")
        let first = try #require(try await inspector.refresh(baseline: .head).changes.first { $0.path == "src/app.py" })
        // Full object names, so a mark stays unambiguous as the object store grows.
        #expect((first.newOID?.count ?? 0) >= 40)
        var ledger = ReviewLedger()
        ledger.markReviewed(first)

        // The agent edits the file again; the blob you saw is still in the object store.
        try box.write("src/app.py", "def greet(name):\n    return f\"Howdy, {name}!\"\n\n\ndef add(a, b):\n    return a + b\n")
        let second = try #require(try await inspector.refresh(baseline: .head).changes.first { $0.path == "src/app.py" })
        guard case .changedSinceReview(let mark) = ledger.status(of: second) else {
            Issue.record("expected the second edit to read as changed since review")
            return
        }
        let blob = try #require(mark.blob)
        let sinceReview = try #require(try await inspector.diffSinceReview(for: second, reviewedBlob: blob))
        #expect(sinceReview.path == "src/app.py")
        #expect(sinceReview.additions == 4)
        #expect(sinceReview.deletions == 0)
        #expect(!sinceReview.addedLines.contains { $0.text.contains("Howdy") })

        // Against the baseline, the full diff still carries both edits.
        let full = try #require(try await inspector.diff(for: second, base: "HEAD"))
        #expect(full.addedLines.contains { $0.text.contains("Howdy") })

        // A blob that was never stored gives no diff rather than an error.
        let missing = try await inspector.diffSinceReview(for: second, reviewedBlob: String(repeating: "1", count: 40))
        #expect(missing == nil)
    }

    @Test func ignoredPathsAreDetected() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        let inspector = try await WorktreeInspector(git: box.git, worktree: box.repo, shadowIndexDirectory: box.indexDir)
        #expect(await inspector.allIgnored(["ignored/a.txt", "ignored/b/c.txt"]))
        #expect(!(await inspector.allIgnored(["ignored/a.txt", "src/app.py"])))
    }
}
