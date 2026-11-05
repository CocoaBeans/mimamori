import Foundation
import Testing
@testable import MimamoriCore

@Suite("Discarding a hunk")
struct HunkPatchTests {
    private func hunk(_ diff: String) throws -> DiffHunk {
        try #require(DiffParser.parse(diff).first?.hunks.first)
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    private let sevenLines = "a\nb\nc\nd\ne\nf\ng\n"
    private let changedD = "a\nb\nc\nD\ne\nf\ng\n"
    private let diffD = """
        diff --git a/f.txt b/f.txt
        index 1111111..2222222 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,7 +1,7 @@ section
         a
         b
         c
        -d
        +D
         e
         f
         g

        """

    @Test func discardPatchIsTheHunkBuiltFromTheBlobs() throws {
        let patch = try HunkPatch.build(path: "f.txt", hunk: try hunk(diffD), old: Data(sevenLines.utf8), new: Data(changedD.utf8))
        #expect(text(patch.discard) == """
            diff --git a/f.txt b/f.txt
            --- a/f.txt
            +++ b/f.txt
            @@ -1,7 +1,7 @@
             a
             b
             c
            -d
            +D
             e
             f
             g

            """)
    }

    @Test func discardingSwapsOnlyTheHunksLines() throws {
        let result = try HunkPatch.discarding(try hunk(diffD), old: Data(sevenLines.utf8), new: Data(changedD.utf8))
        #expect(text(result) == sevenLines)
    }

    @Test func discardingKeepsTheOtherHunks() throws {
        let old = (1...30).map { "line \($0)\n" }.joined()
        let new = old.replacingOccurrences(of: "line 3\n", with: "line three\n")
            .replacingOccurrences(of: "line 25\n", with: "line twenty-five\nextra\n")
        let diff = """
            diff --git a/n.txt b/n.txt
            --- a/n.txt
            +++ b/n.txt
            @@ -1,6 +1,6 @@
             line 1
             line 2
            -line 3
            +line three
             line 4
             line 5
             line 6
            @@ -22,7 +22,8 @@
             line 22
             line 23
             line 24
            -line 25
            +line twenty-five
            +extra
             line 26
             line 27
             line 28

            """
        let second = try #require(DiffParser.parse(diff).first?.hunks.last)
        let result = try HunkPatch.discarding(second, old: Data(old.utf8), new: Data(new.utf8))
        #expect(text(result) == old.replacingOccurrences(of: "line 3\n", with: "line three\n"))
        // Put back, the lines start where the discard left the baseline's: line 22 on both sides.
        let patch = try HunkPatch.build(path: "n.txt", hunk: second, old: Data(old.utf8), new: Data(new.utf8))
        #expect(text(patch.restore).contains("@@ -22,7 +22,8 @@\n"))
    }

    @Test func restoreStartsFollowTheNewSide() {
        func starts(_ oldStart: Int, _ oldCount: Int, _ newStart: Int, _ newCount: Int) -> [Int] {
            let value = HunkPatch.restoreStarts(of: DiffHunk(id: 0, header: "", oldStart: oldStart, oldCount: oldCount,
                                                             newStart: newStart, newCount: newCount))
            return [value.old, value.new]
        }
        #expect(starts(10, 3, 12, 5) == [12, 12])
        // Lines only added: the old side names the line before them.
        #expect(starts(5, 0, 7, 2) == [6, 7])
        // Lines only removed: the new side names the line before.
        #expect(starts(5, 2, 6, 0) == [7, 6])
    }

    @Test func aMissingFinalNewlineIsKept() throws {
        let old = "a\nb"
        let new = "a\nb\nc\n"
        let diff = """
            diff --git a/f b/f
            --- a/f
            +++ b/f
            @@ -1,2 +1,3 @@
             a
            -b
            \\ No newline at end of file
            +b
            +c

            """
        let parsed = try hunk(diff)
        let patch = try HunkPatch.build(path: "f", hunk: parsed, old: Data(old.utf8), new: Data(new.utf8))
        #expect(text(patch.discard).hasSuffix(" a\n-b\n\\ No newline at end of file\n+b\n+c\n"))
        #expect(text(try HunkPatch.discarding(parsed, old: Data(old.utf8), new: Data(new.utf8))) == old)
    }

    @Test func carriageReturnsComeFromTheBlobs() throws {
        // The lines as a parser reads them, without their carriage returns.
        let parsed = DiffHunk(id: 0, header: "@@ -1,2 +1,2 @@", oldStart: 1, oldCount: 2, newStart: 1, newCount: 2, lines: [
            DiffLine(id: 0, kind: .context, text: "a", oldNumber: 1, newNumber: 1),
            DiffLine(id: 1, kind: .deletion, text: "b", oldNumber: 2, newNumber: nil),
            DiffLine(id: 2, kind: .addition, text: "B", oldNumber: nil, newNumber: 2),
        ])
        let old = Data("a\r\nb\r\n".utf8)
        let new = Data("a\r\nB\r\n".utf8)
        let patch = try HunkPatch.build(path: "w.txt", hunk: parsed, old: old, new: new)
        #expect(text(patch.discard).hasSuffix("@@ -1,2 +1,2 @@\n a\r\n-b\r\n+B\r\n"))
        #expect(try HunkPatch.discarding(parsed, old: old, new: new) == old)
    }

    @Test func aHunkThatDoesNotMatchTheBlobsIsRefused() throws {
        let elsewhere = changedD.replacingOccurrences(of: "D", with: "X")
        #expect(throws: HunkDiscardError.mismatch) {
            try HunkPatch.build(path: "f.txt", hunk: try hunk(diffD), old: Data(sevenLines.utf8), new: Data(elsewhere.utf8))
        }
    }

    @Test func aHunkCutShortIsRefused() throws {
        var partial = try hunk(diffD)
        partial.lines = Array(partial.lines.prefix(4))
        #expect(throws: HunkDiscardError.mismatch) {
            try HunkPatch.build(path: "f.txt", hunk: partial, old: Data(sevenLines.utf8), new: Data(changedD.utf8))
        }
    }

    @Test func pathsAreQuotedOnlyWhenGitWouldQuoteThem() {
        #expect(String(decoding: HunkPatch.quoted("a/src/my file é.txt"), as: UTF8.self) == "a/src/my file é.txt")
        #expect(String(decoding: HunkPatch.quoted("a/we\"ird\tname"), as: UTF8.self) == "\"a/we\\\"ird\\tname\"")
        #expect(String(decoding: HunkPatch.quoted("a/bell\u{1}"), as: UTF8.self) == "\"a/bell\\001\"")
    }

    @Test func onlyFilesWithTextOnBothSidesQualify() {
        let modified = FileChange(path: "a.txt", kind: .modified, oldMode: "100644", newMode: "100644", oldOID: "1", newOID: "2")
        #expect(Discarding.hunkUnsupportedReason(for: modified) == nil)
        var renamed = modified
        renamed.kind = .renamed
        renamed.oldPath = "b.txt"
        #expect(Discarding.hunkUnsupportedReason(for: renamed) == nil)
        var added = modified
        added.kind = .added
        added.oldOID = nil
        #expect(Discarding.hunkUnsupportedReason(for: added) != nil)
        var binary = modified
        binary.isBinary = true
        #expect(Discarding.hunkUnsupportedReason(for: binary) != nil)
        var conflicted = modified
        conflicted.hasConflict = true
        #expect(Discarding.hunkUnsupportedReason(for: conflicted) != nil)
        var link = modified
        link.newMode = "120000"
        #expect(Discarding.hunkUnsupportedReason(for: link) != nil)
    }

    @Test func wholeFilesQualifyUnlessTheySpanTwoPaths() {
        let modified = FileChange(path: "a.txt", kind: .modified, oldMode: "100644", newMode: "100644", oldOID: "1", newOID: "2")
        #expect(Discarding.fileUnsupportedReason(for: modified) == nil)
        var binary = modified
        binary.isBinary = true
        #expect(Discarding.fileUnsupportedReason(for: binary) == nil)
        let added = FileChange(path: "a.txt", kind: .added, newMode: "100644", newOID: "2")
        #expect(Discarding.fileUnsupportedReason(for: added) == nil)
        let deleted = FileChange(path: "a.txt", kind: .deleted, oldMode: "100644", oldOID: "1")
        #expect(Discarding.fileUnsupportedReason(for: deleted) == nil)
        var renamed = modified
        renamed.kind = .renamed
        renamed.oldPath = "b.txt"
        #expect(Discarding.fileUnsupportedReason(for: renamed) != nil)
        var conflicted = modified
        conflicted.hasConflict = true
        #expect(Discarding.fileUnsupportedReason(for: conflicted) != nil)
        var submodule = modified
        submodule.newMode = "160000"
        #expect(Discarding.fileUnsupportedReason(for: submodule) != nil)
    }
}

/// Discards and puts back hunks in a throwaway repository, with the real git binary.
@Suite("Discarding a hunk (integration)", .serialized)
struct HunkDiscardIntegrationTests {
    struct Sandbox {
        let git: GitClient
        let root: URL
        let repo: URL

        func sh(_ args: [String]) async throws {
            try await git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + args, in: repo)
        }

        func write(_ path: String, _ contents: String) throws {
            try Data(contents.utf8).write(to: repo.appendingPathComponent(path))
        }

        func read(_ path: String) throws -> String {
            String(decoding: try Data(contentsOf: repo.appendingPathComponent(path)), as: UTF8.self)
        }

        func inspector() async throws -> WorktreeInspector {
            try await WorktreeInspector(git: git, worktree: repo, shadowIndexDirectory: root.appendingPathComponent("index"))
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static let committed = (1...30).map { "line \($0)\n" }.joined()
    private static let edited = committed.replacingOccurrences(of: "line 3\n", with: "line three\n")
        .replacingOccurrences(of: "line 25\n", with: "line twenty-five\nextra\n")

    /// A repository with notes.txt committed, then edited in two places far apart.
    private func makeSandbox() async throws -> Sandbox {
        let git = try #require(await GitClient.locate())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimamori-discard-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let box = Sandbox(git: git, root: root, repo: repo)
        try await box.sh(["init", "-q", "-b", "main"])
        try box.write("notes.txt", Self.committed)
        try await box.sh(["add", "-A"])
        try await box.sh(["commit", "-q", "-m", "Initial commit"])
        try box.write("notes.txt", Self.edited)
        return box
    }

    /// The change and its diff as the Uncommitted view shows them.
    private func uncommitted(_ path: String, in inspector: WorktreeInspector) async throws -> (FileChange, FileDiff) {
        let state = try await inspector.refresh(baseline: .head)
        let change = try #require(state.changes.first { $0.path == path })
        let base = try #require(state.baseline.treeish)
        let diff = try #require(try await inspector.diff(for: change, base: base))
        return (change, diff)
    }

    private func indexBytes(_ box: Sandbox) throws -> Data {
        try Data(contentsOf: box.repo.appendingPathComponent(".git/index"))
    }

    @Test func discardsOneHunkAndPutsItBack() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        let inspector = try await box.inspector()
        let (change, diff) = try await uncommitted("notes.txt", in: inspector)
        #expect(diff.hunks.count == 2)
        let index = try indexBytes(box)

        let discarded = try await inspector.discard(diff.hunks[1], of: change)
        #expect(try box.read("notes.txt") == Self.committed.replacingOccurrences(of: "line 3\n", with: "line three\n"))
        #expect(discarded.additions == 2 && discarded.deletions == 1)

        // The snapshot taken first has the file as it was.
        #expect(await inspector.snapshots().contains { $0.id == discarded.snapshot.id })
        let snapshotted = try await box.git.run(["show", "\(discarded.snapshot.commitOID):notes.txt"], in: box.repo).stdoutText
        #expect(snapshotted == Self.edited)

        // The repository's own index is as it was, unlocked, with nothing staged.
        #expect(try indexBytes(box) == index)
        #expect(!FileManager.default.fileExists(atPath: box.repo.appendingPathComponent(".git/index.lock").path))
        #expect(try await box.git.status(in: box.repo).entries.allSatisfy { !$0.isStaged })

        let restored = try await inspector.restore(discarded)
        #expect(restored.exact)
        #expect(try box.read("notes.txt") == Self.edited)
        #expect(try indexBytes(box) == index)
    }

    @Test func refusesWhenTheFileChangedSinceTheDiff() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        let inspector = try await box.inspector()
        let (change, diff) = try await uncommitted("notes.txt", in: inspector)
        let snapshotsBefore = await inspector.snapshots().count
        let later = Self.edited + "one more\n"
        try box.write("notes.txt", later)

        await #expect(throws: HunkDiscardError.fileChanged) {
            _ = try await inspector.discard(diff.hunks[0], of: change)
        }
        #expect(try box.read("notes.txt") == later)
        #expect(await inspector.snapshots().count == snapshotsBefore)
    }

    @Test func refusesWhenHeadMovedSinceTheDiff() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        let inspector = try await box.inspector()
        let (change, diff) = try await uncommitted("notes.txt", in: inspector)
        // A commit of another version of the file, leaving the working tree as it was.
        try box.write("notes.txt", Self.committed + "tail\n")
        try await box.sh(["commit", "-q", "-am", "Tail"])
        try box.write("notes.txt", Self.edited)

        await #expect(throws: HunkDiscardError.headMoved) {
            _ = try await inspector.discard(diff.hunks[0], of: change)
        }
        #expect(try box.read("notes.txt") == Self.edited)
    }

    @Test func gitChecksTheHunkAgainstTheWorkingTree() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        let inspector = try await box.inspector()
        let (change, diff) = try await uncommitted("notes.txt", in: inspector)
        let old = try await box.git.blob(try #require(change.oldOID), in: box.repo)
        let new = try await box.git.blob(try #require(change.newOID), in: box.repo)
        let patch = try HunkPatch.build(path: "notes.txt", hunk: diff.hunks[0], old: old, new: new)
        try await box.git.applyToWorkingTree(patch.discard, reverse: true, checkOnly: true, in: box.repo)

        // Once the hunk's own lines change, git says it no longer comes out, and writes nothing.
        let rewritten = Self.edited.replacingOccurrences(of: "line three\n", with: "line 3, rewritten\n")
        try box.write("notes.txt", rewritten)
        await #expect(throws: GitError.self) {
            try await box.git.applyToWorkingTree(patch.discard, reverse: true, checkOnly: true, in: box.repo)
        }
        #expect(try box.read("notes.txt") == rewritten)
    }

    @Test func restoreFitsTheHunkBackAfterEditsElsewhere() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        let inspector = try await box.inspector()
        let (change, diff) = try await uncommitted("notes.txt", in: inspector)
        let discarded = try await inspector.discard(diff.hunks[1], of: change)

        // An edit far from the hunk: it goes back in around it.
        let afterDiscard = try box.read("notes.txt")
        try box.write("notes.txt", afterDiscard.replacingOccurrences(of: "line 12\n", with: "line twelve\n"))
        let restored = try await inspector.restore(discarded)
        #expect(!restored.exact)
        #expect(try box.read("notes.txt") == Self.edited.replacingOccurrences(of: "line 12\n", with: "line twelve\n"))
    }

    @Test func restoreRefusesWhenTheHunksSurroundingsChanged() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        let inspector = try await box.inspector()
        let (change, diff) = try await uncommitted("notes.txt", in: inspector)
        let discarded = try await inspector.discard(diff.hunks[1], of: change)

        let rewritten = try box.read("notes.txt").replacingOccurrences(of: "line 25\n", with: "line 25, again\n")
        try box.write("notes.txt", rewritten)
        await #expect(throws: HunkDiscardError.self) {
            _ = try await inspector.restore(discarded)
        }
        #expect(try box.read("notes.txt") == rewritten)
    }

    @Test func aMissingFinalNewlineSurvives() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        try box.write("short.txt", "a\nb")
        try await box.sh(["add", "short.txt"])
        try await box.sh(["commit", "-q", "-m", "Short"])
        try box.write("short.txt", "a\nb\nc\n")
        let inspector = try await box.inspector()
        let (change, diff) = try await uncommitted("short.txt", in: inspector)

        let discarded = try await inspector.discard(diff.hunks[0], of: change)
        #expect(try box.read("short.txt") == "a\nb")
        _ = try await inspector.restore(discarded)
        #expect(try box.read("short.txt") == "a\nb\nc\n")
    }

    @Test func permissionsAreKept() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        let url = box.repo.appendingPathComponent("notes.txt")
        try box.write("notes.txt", Self.committed)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try await box.sh(["add", "notes.txt"])
        try await box.sh(["commit", "-q", "-m", "Executable"])
        try box.write("notes.txt", Self.committed + "more\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let inspector = try await box.inspector()
        let (change, diff) = try await uncommitted("notes.txt", in: inspector)

        _ = try await inspector.discard(diff.hunks[0], of: change)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        #expect(try box.read("notes.txt") == Self.committed)
    }

    /// Windows line endings: the discard is either exact or refused, never a file rewritten wrong.
    @Test func carriageReturnsAreKeptOrTheFileIsLeftAlone() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        let committed = "one\r\ntwo\r\nthree\r\n"
        try box.write("crlf.txt", committed)
        try await box.sh(["add", "crlf.txt"])
        try await box.sh(["commit", "-q", "-m", "CRLF"])
        let edited = "one\r\nTWO\r\nthree\r\n"
        try box.write("crlf.txt", edited)
        let inspector = try await box.inspector()
        let (change, diff) = try await uncommitted("crlf.txt", in: inspector)
        let hunk = try #require(diff.hunks.first)

        do {
            _ = try await inspector.discard(hunk, of: change)
            #expect(try box.read("crlf.txt") == committed)
        } catch {
            #expect(error is HunkDiscardError)
            #expect(try box.read("crlf.txt") == edited)
        }
    }

    private func mode(_ box: Sandbox, _ path: String) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: box.repo.appendingPathComponent(path).path)[.posixPermissions] as? Int)
    }

    @Test func discardingAWholeFileGivesBackHeadsBytesAndMode() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        let url = box.repo.appendingPathComponent("notes.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let inspector = try await box.inspector()
        let (change, _) = try await uncommitted("notes.txt", in: inspector)
        let index = try indexBytes(box)

        let discarded = try await inspector.discardFile(change, trashNewFiles: false)
        #expect(try box.read("notes.txt") == Self.committed)
        #expect(try mode(box, "notes.txt") & 0o111 == 0)
        #expect(discarded.summary == "Discarded the changes to notes.txt")
        #expect(try indexBytes(box) == index)

        let restored = try await inspector.restore(discarded)
        #expect(restored.exact)
        #expect(try box.read("notes.txt") == Self.edited)
        #expect(try mode(box, "notes.txt") == 0o755)
    }

    @Test func discardingANewFileRemovesItAndUndoBringsItBack() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        try FileManager.default.createDirectory(at: box.repo.appendingPathComponent("drafts"), withIntermediateDirectories: true)
        try box.write("drafts/plan.md", "# Plan\n")
        let inspector = try await box.inspector()
        let (change, _) = try await uncommitted("drafts/plan.md", in: inspector)

        let discarded = try await inspector.discardFile(change, trashNewFiles: false)
        #expect(!FileManager.default.fileExists(atPath: box.repo.appendingPathComponent("drafts/plan.md").path))
        // Only the snapshot has it now.
        let kept = try await box.git.run(["show", "\(discarded.snapshot.commitOID):drafts/plan.md"], in: box.repo).stdoutText
        #expect(kept == "# Plan\n")

        _ = try await inspector.restore(discarded)
        #expect(try box.read("drafts/plan.md") == "# Plan\n")
    }

    @Test func discardingADeletionBringsTheFileBack() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        try FileManager.default.removeItem(at: box.repo.appendingPathComponent("notes.txt"))
        let inspector = try await box.inspector()
        let (change, _) = try await uncommitted("notes.txt", in: inspector)
        #expect(change.kind == .deleted)

        let discarded = try await inspector.discardFile(change, trashNewFiles: false)
        #expect(try box.read("notes.txt") == Self.committed)
        _ = try await inspector.restore(discarded)
        #expect(!FileManager.default.fileExists(atPath: box.repo.appendingPathComponent("notes.txt").path))
    }

    @Test func aWholeFileChangedSinceIsNotDiscardedOrPutBack() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        let inspector = try await box.inspector()
        let (change, _) = try await uncommitted("notes.txt", in: inspector)

        try box.write("notes.txt", Self.edited + "later\n")
        await #expect(throws: HunkDiscardError.fileChanged) {
            _ = try await inspector.discardFile(change, trashNewFiles: false)
        }
        #expect(try box.read("notes.txt") == Self.edited + "later\n")

        // Discarded, then edited again: Undo would lose the edit, so it doesn't.
        try box.write("notes.txt", Self.edited)
        let (fresh, _) = try await uncommitted("notes.txt", in: inspector)
        let discarded = try await inspector.discardFile(fresh, trashNewFiles: false)
        try box.write("notes.txt", Self.committed + "agent again\n")
        await #expect(throws: HunkDiscardError.restoreBlocked) {
            _ = try await inspector.restore(discarded)
        }
        #expect(try box.read("notes.txt") == Self.committed + "agent again\n")
    }

    @Test func aNewFileIsNotDiscardedAHunkAtATime() async throws {
        let box = try await makeSandbox()
        defer { box.cleanup() }
        try box.write("fresh.txt", "new\n")
        let inspector = try await box.inspector()
        let (change, diff) = try await uncommitted("fresh.txt", in: inspector)
        await #expect(throws: HunkDiscardError.self) {
            _ = try await inspector.discard(diff.hunks[0], of: change)
        }
        #expect(try box.read("fresh.txt") == "new\n")
    }
}
