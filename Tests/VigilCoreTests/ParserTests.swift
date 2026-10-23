import Foundation
import Testing
@testable import VigilCore

private func nulJoined(_ tokens: [String]) -> Data {
    var data = Data()
    for token in tokens {
        data.append(contentsOf: Array(token.utf8))
        data.append(0)
    }
    return data
}

@Suite("Porcelain v2 status")
struct PorcelainStatusParserTests {
    @Test func parsesHeadersAndEntries() {
        let data = nulJoined([
            "# branch.oid 1234567890abcdef1234567890abcdef12345678",
            "# branch.head feature/x",
            "# branch.upstream origin/feature/x",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 abc abc src/app with space.py",
            "1 A. N... 000000 100644 100644 000 def staged.txt",
            "2 R. N... 100644 100644 100644 abc abc R100 new name.txt",
            "old name.txt",
            "u UU N... 100644 100644 100644 100644 a b c conflicted.txt",
            "? untracked.txt",
            "? dir/",
        ])
        let status = PorcelainStatusParser.parse(data)
        #expect(status.headOID == "1234567890abcdef1234567890abcdef12345678")
        #expect(status.branch == "feature/x")
        #expect(status.upstream == "origin/feature/x")
        #expect(status.ahead == 2)
        #expect(status.behind == 1)
        #expect(status.entries.count == 4)
        #expect(status.entries[0].path == "src/app with space.py")
        #expect(status.entries[0].hasWorktreeChanges)
        #expect(!status.entries[0].isStaged)
        #expect(status.entries[1].isStaged)
        #expect(status.entries[2].path == "new name.txt")
        #expect(status.entries[2].originalPath == "old name.txt")
        #expect(status.entries[3].isUnmerged)
        #expect(status.untracked == ["untracked.txt", "dir/"])
        #expect(status.isUntracked("dir/nested/file.txt"))
        #expect(status.isUntracked("untracked.txt"))
        #expect(!status.isUntracked("staged.txt"))
    }

    @Test func unbornAndDetached() {
        let data = nulJoined(["# branch.oid (initial)", "# branch.head (detached)"])
        let status = PorcelainStatusParser.parse(data)
        #expect(status.headOID == nil)
        #expect(status.branch == nil)
        #expect(status.branchInfo.isUnborn)
    }
}

@Suite("Worktree list")
struct WorktreeListParserTests {
    @Test func parsesMainAndLinked() {
        let text = """
        worktree /repo
        HEAD aaaa
        branch refs/heads/main

        worktree /repo/.claude/worktrees/feature
        HEAD bbbb
        branch refs/heads/feature/x
        locked

        worktree /tmp/detached
        HEAD cccc
        detached

        """
        let list = WorktreeListParser.parse(text)
        #expect(list.count == 3)
        #expect(list[0].isMain)
        #expect(list[0].branch == "main")
        #expect(!list[1].isMain)
        #expect(list[1].branch == "feature/x")
        #expect(list[1].isLocked)
        #expect(list[2].isDetached)
        #expect(list[2].branch == nil)
    }
}

@Suite("Raw diff and numstat")
struct RawAndNumstatTests {
    @Test func rawEntriesIncludingRename() {
        let data = nulJoined([
            ":100644 100644 aaaa bbbb M", "src/a.swift",
            ":000000 100644 0000000000000000000000000000000000000000 cccc A", "new file.txt",
            ":100644 100644 dddd eeee R095", "old.txt", "renamed.txt",
            ":100644 000000 ffff 0000000000000000000000000000000000000000 D", "gone.txt",
        ])
        let entries = RawDiffParser.parse(data)
        #expect(entries.count == 4)
        #expect(entries[0].status == "M")
        #expect(entries[1].path == "new file.txt")
        #expect(entries[1].isNullOld)
        #expect(entries[2].status == "R")
        #expect(entries[2].score == 95)
        #expect(entries[2].oldPath == "old.txt")
        #expect(entries[2].path == "renamed.txt")
        #expect(entries[3].isNullNew)
    }

    @Test func numstatIncludingRenameAndBinary() {
        let data = nulJoined([
            "3\t1\tsrc/a.swift",
            "-\t-\timage.png",
            "0\t0\t", "old.txt", "renamed.txt",
        ])
        let entries = NumstatParser.parse(data)
        #expect(entries.count == 3)
        #expect(entries[0].additions == 3)
        #expect(entries[0].deletions == 1)
        #expect(entries[1].isBinary)
        #expect(entries[2].path == "renamed.txt")
        #expect(entries[2].oldPath == "old.txt")
    }
}

@Suite("Unified diff parser")
struct DiffParserTests {
    @Test func parsesModifiedFileWithTwoHunks() {
        let patch = """
        diff --git a/src/app.py b/src/app.py
        index 1111111..2222222 100644
        --- a/src/app.py
        +++ b/src/app.py
        @@ -1,3 +1,4 @@
         def greet(name):
        -    return f"Hello, {name}!"
        +    return f"Howdy, {name}!"
        +
        
        @@ -10,2 +11,3 @@ def add(a, b):
             return a + b
        +# trailing
         # end
        \\ No newline at end of file
        """
        let diffs = DiffParser.parse(patch)
        #expect(diffs.count == 1)
        let diff = diffs[0]
        #expect(diff.path == "src/app.py")
        #expect(diff.hunks.count == 2)
        #expect(diff.additions == 3)
        #expect(diff.deletions == 1)
        let first = diff.hunks[0]
        #expect(first.oldStart == 1 && first.newStart == 1)
        #expect(first.lines[0].kind == .context && first.lines[0].oldNumber == 1 && first.lines[0].newNumber == 1)
        #expect(first.lines[1].kind == .deletion && first.lines[1].oldNumber == 2 && first.lines[1].newNumber == nil)
        #expect(first.lines[2].kind == .addition && first.lines[2].newNumber == 2)
        #expect(first.lines[4].kind == .context && first.lines[4].text == "")
        #expect(diff.hunks[1].lines.last?.kind == .noNewline)
    }

    @Test func parsesNewDeletedRenamedAndBinary() {
        let patch = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..e69de29
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +hello
        +world
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index e69de29..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/old name.txt b/new name.txt
        similarity index 90%
        rename from old name.txt
        rename to new name.txt
        diff --git a/logo.png b/logo.png
        index 1111111..2222222 100644
        Binary files a/logo.png and b/logo.png differ
        diff --git a/dir with space/file.txt b/dir with space/file.txt
        old mode 100644
        new mode 100755
        """
        let diffs = DiffParser.parse(patch)
        #expect(diffs.count == 5)
        #expect(diffs[0].isNewFile && diffs[0].oldPath == nil && diffs[0].newPath == "new.txt" && diffs[0].additions == 2)
        #expect(diffs[1].isDeletedFile && diffs[1].newPath == nil && diffs[1].oldPath == "gone.txt")
        #expect(diffs[2].isRename && diffs[2].oldPath == "old name.txt" && diffs[2].newPath == "new name.txt" && diffs[2].similarity == 90)
        #expect(diffs[3].isBinary && diffs[3].path == "logo.png")
        #expect(diffs[4].path == "dir with space/file.txt" && diffs[4].oldMode == "100644" && diffs[4].newMode == "100755")
    }

    @Test func unquotesCStyle() {
        #expect(DiffParser.unquote("\"a\\303\\251.txt\"") == "aé.txt")
        #expect(DiffParser.unquote("\"tab\\there\"") == "tab\there")
        #expect(DiffParser.unquote("plain.txt") == "plain.txt")
    }

    @Test func headerPathsWithSpaces() {
        let pair = DiffParser.pathsFromGitHeader("a/some dir/file b.txt b/some dir/file b.txt")
        #expect(pair?.0 == "some dir/file b.txt")
        #expect(pair?.1 == "some dir/file b.txt")
    }
}
