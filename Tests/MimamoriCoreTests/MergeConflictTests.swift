import Foundation
import Testing
@testable import MimamoriCore

@Suite("Merge conflicts")
struct MergeConflictTests {
    /// A diff whose new file is `lines`, each line added, or context where it starts with "  ".
    private func diff(_ lines: [String], hunks split: [Int] = []) -> FileDiff {
        var hunks: [DiffHunk] = []
        var current: [DiffLine] = []
        for (offset, text) in lines.enumerated() {
            if split.contains(offset), !current.isEmpty {
                hunks.append(DiffHunk(id: hunks.count, header: "@@", oldStart: 1, oldCount: 0, newStart: current[0].newNumber!,
                                      newCount: current.count, lines: current))
                current = []
            }
            let context = text.hasPrefix("  ")
            current.append(DiffLine(id: offset, kind: context ? .context : .addition, text: context ? String(text.dropFirst(2)) : text,
                                    oldNumber: context ? offset + 1 : nil, newNumber: offset + 1))
        }
        hunks.append(DiffHunk(id: hunks.count, header: "@@", oldStart: 1, oldCount: 0, newStart: current[0].newNumber!,
                              newCount: current.count, lines: current))
        return FileDiff(oldPath: "f", newPath: "f", hunks: hunks)
    }

    @Test func findsEachConflictAndItsSides() throws {
        let conflicts = MergeConflicts(diff: diff([
            "<<<<<<< HEAD",            // 1
            "  let a = 1",              // 2: ours, unchanged from HEAD
            "=======",                  // 3
            "let a = 2",                // 4
            ">>>>>>> feature/euros",   // 5
            "  print(a)",               // 6
            "<<<<<<< HEAD",            // 7
            "x",                        // 8
            "||||||| merged common ancestors",  // 9
            "w",                        // 10
            "=======",                  // 11
            "y",                        // 12
            ">>>>>>> feature/euros",   // 13
        ]))
        #expect(conflicts.conflicts.count == 2)
        let first = try #require(conflicts.conflicts.first)
        #expect(first.current == "HEAD" && first.incoming == "feature/euros" && first.base == nil)
        #expect((first.opening, first.divider, first.closing) == (1, 3, 5))
        let parts = (1...13).map { conflicts.placement(ofLine: $0)?.part }
        #expect(parts == [.opening, .current, .divider, .incoming, .closing, nil,
                          .opening, .current, .baseMarker, .base, .divider, .incoming, .closing])
        #expect(conflicts.placement(ofLine: 8)?.conflict.number == 2)
        #expect(conflicts.placement(ofLine: 8)?.total == 2)
        #expect(conflicts.conflicts[1].base == "merged common ancestors")
    }

    @Test func aConflictSpansHunks() {
        // The current side is long, so the diff leaves part of it out between two hunks.
        let conflicts = MergeConflicts(diff: diff(["<<<<<<< HEAD", "  a", "  b", "=======", "c", ">>>>>>> theirs"], hunks: [3]))
        #expect(conflicts.conflicts.count == 1)
        #expect(conflicts.placement(ofLine: 3)?.part == .current)
        #expect(conflicts.placement(ofLine: 5)?.part == .incoming)
    }

    @Test func markdownUnderlinesAndQuotesAreNotConflicts() {
        let conflicts = MergeConflicts(diff: diff(["Title", "=======", "<<<<<<<<< not a marker", ">>>>>>> stray"]))
        #expect(conflicts.isEmpty)
        #expect(conflicts.placement(ofLine: 2) == nil)
    }

    @Test func contentFlagsCountConflictsNotMarkerLines() {
        let flags = AttentionRules.contentFlags(in: diff([
            "<<<<<<< HEAD", "a", "=======", "b", ">>>>>>> x",
            "<<<<<<< HEAD", "c", "=======", "d", ">>>>>>> x",
        ]), config: RuleConfiguration())
        let marker = flags.first { $0.rule == .conflictMarkers }
        #expect(marker?.message == "Conflict markers (2 places)")
        #expect(marker?.line == 1)
    }

    // MARK: Operations in progress

    private func gitDir(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitdir-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func readsAMergeAndNamesWhatIsMerged() throws {
        let dir = try gitDir(["MERGE_HEAD": "1a2b3c4d\n", "MERGE_MSG": "Merge branch 'feature/euros'\n\n# Conflicts:\n#\tmoney.ts\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = try #require(WorktreeOperationReader.read(gitDir: dir))
        #expect(found.operation.kind == .merge)
        #expect(found.operation.incoming == "feature/euros")
        #expect(found.incomingOID == nil)
        #expect(found.operation.title(currentBranch: "main") == "Merging feature/euros into main")
        #expect(WorktreeOperationReader.mergedName("Merge remote-tracking branch 'origin/fix' into main") == "origin/fix")
        #expect(WorktreeOperationReader.mergedName("Revert \"x\"") == nil)
    }

    @Test func readsARebaseWithItsProgress() throws {
        let dir = try gitDir(["rebase-merge/head-name": "refs/heads/feature/login\n", "rebase-merge/onto": "abcdef1234\n",
                              "rebase-merge/msgnum": "3\n", "rebase-merge/end": "7\n",
                              "rebase-merge/done": "pick 1111111 First\npick 2222222 Second\npick 3333333 Third\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = try #require(WorktreeOperationReader.read(gitDir: dir))
        #expect(found.operation.kind == .rebase)
        #expect(found.operation.branch == "feature/login")
        #expect(found.ontoOID == "abcdef1234")
        #expect(found.incomingOID == "3333333")
        #expect(found.operation.progress == "3 of 7")
        var named = found.operation
        named.onto = "main"
        named.conflicted = 2
        #expect(named.title(currentBranch: nil) == "Rebasing feature/login onto main")
        #expect(named.detail == "2 files conflicted")
    }

    @Test func readsPatchesPicksRevertsAndBisects() throws {
        let patches = try gitDir(["rebase-apply/applying": "", "rebase-apply/next": "2", "rebase-apply/last": "4"])
        let pick = try gitDir(["CHERRY_PICK_HEAD": "9f8e7d6\n"])
        let revert = try gitDir(["REVERT_HEAD": "5a5a5a5\n"])
        let bisect = try gitDir(["BISECT_LOG": "git bisect start\n"])
        let plain = try gitDir(["HEAD": "ref: refs/heads/main\n"])
        defer { for dir in [patches, pick, revert, bisect, plain] { try? FileManager.default.removeItem(at: dir) } }
        #expect(WorktreeOperationReader.read(gitDir: patches)?.operation.kind == .applyingPatches)
        #expect(WorktreeOperationReader.read(gitDir: patches)?.operation.progress == "2 of 4")
        #expect(WorktreeOperationReader.read(gitDir: pick)?.incomingOID == "9f8e7d6")
        #expect(WorktreeOperationReader.read(gitDir: revert)?.operation.kind == .revert)
        #expect(WorktreeOperationReader.read(gitDir: bisect)?.operation.kind == .bisect)
        #expect(WorktreeOperationReader.read(gitDir: plain) == nil)
    }
}

/// The real git binary, stopping on real conflicts.
@Suite("Merge conflicts (integration)", .serialized)
struct MergeConflictIntegrationTests {
    private func repo() async throws -> (GitClient, URL, URL) {
        let git = try #require(await GitClient.locate())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimamori-conflict-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await run(git, repo, ["init", "-q", "-b", "main"])
        try "let currency = \"USD\"\nprint(currency)\n".write(to: repo.appendingPathComponent("money.swift"), atomically: true, encoding: .utf8)
        try await run(git, repo, ["add", "-A"])
        try await run(git, repo, ["commit", "-q", "-m", "Money"])
        try await run(git, repo, ["switch", "-q", "-c", "feature/euros"])
        try "let currency = \"EUR\"\nprint(currency)\n".write(to: repo.appendingPathComponent("money.swift"), atomically: true, encoding: .utf8)
        try await run(git, repo, ["commit", "-q", "-am", "Prices in euros"])
        try await run(git, repo, ["switch", "-q", "main"])
        try "let currency = \"GBP\"\nprint(currency)\n".write(to: repo.appendingPathComponent("money.swift"), atomically: true, encoding: .utf8)
        try await run(git, repo, ["commit", "-q", "-am", "Prices in pounds"])
        return (git, root, repo)
    }

    @discardableResult
    private func run(_ git: GitClient, _ repo: URL, _ arguments: [String], allowFailure: Bool = false) async throws -> ProcessResult {
        try await git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + arguments,
                          in: repo, options: GitClient.Options(allowedExitCodes: allowFailure ? [0, 1] : [0]))
    }

    @Test func aStoppedMergeShowsItsOperationAndConflictedFile() async throws {
        let (git, root, repo) = try await repo()
        defer { try? FileManager.default.removeItem(at: root) }
        try await run(git, repo, ["merge", "feature/euros"], allowFailure: true)
        let inspector = try await WorktreeInspector(git: git, worktree: repo, shadowIndexDirectory: root.appendingPathComponent("index"))
        let state = try await inspector.refresh(baseline: .head)
        let operation = try #require(state.operation)
        #expect(operation.kind == .merge)
        #expect(operation.title(currentBranch: state.branch.branch) == "Merging feature/euros into main")
        #expect(operation.conflicted == 1)
        let change = try #require(state.changes.first { $0.path == "money.swift" })
        #expect(change.kind == .unmerged)
        #expect(change.flags.contains { $0.message == "Unresolved merge conflict" })
    }

    @Test func aStoppedRebaseNamesItsBranchAndWhereItIsGoing() async throws {
        let (git, root, repo) = try await repo()
        defer { try? FileManager.default.removeItem(at: root) }
        try await run(git, repo, ["switch", "-q", "feature/euros"])
        try await run(git, repo, ["rebase", "main"], allowFailure: true)
        let inspector = try await WorktreeInspector(git: git, worktree: repo, shadowIndexDirectory: root.appendingPathComponent("index"))
        let state = try await inspector.refresh(baseline: .head)
        let operation = try #require(state.operation)
        #expect(operation.kind == .rebase)
        #expect(operation.title(currentBranch: nil) == "Rebasing feature/euros onto main")
        #expect(operation.incoming?.hasSuffix("Prices in euros") == true)
        #expect(operation.conflicted == 1)
    }
}
