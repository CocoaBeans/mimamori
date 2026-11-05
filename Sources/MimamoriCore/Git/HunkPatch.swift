import Foundation

/// A one-hunk patch, for throwing away one hunk of an uncommitted change and for putting it back.
///
/// It is built from the two blobs the diff compared, not from the diff's text, so it carries their
/// exact bytes: carriage returns, a missing final newline, text that is not UTF-8. The parsed hunk
/// only says which lines go where, and it has to agree with the blobs line for line.
public struct HunkPatch: Sendable, Hashable {
    /// The hunk as the diff showed it, the baseline's blob to the working tree's. git checks it
    /// comes out cleanly (`git apply --check -R`) before anything is written.
    public let discard: Data
    /// The same lines, placed where the discard leaves them. Applied forward, it puts them back
    /// into a file that changed elsewhere since.
    public let restore: Data

    /// Builds the patch for `hunk` of the file at `path`, whose diff compared `old` with `new`.
    public static func build(path: String, hunk: DiffHunk, old: Data, new: Data) throws -> HunkPatch {
        let oldLines = lines(of: old)
        let newLines = lines(of: new)
        var body: [UInt8] = []
        var oldCount = 0
        var newCount = 0

        func add(_ marker: UInt8, _ line: ArraySlice<UInt8>) {
            body.append(marker)
            body.append(contentsOf: line)
            // Only a file's last line can lack its newline; the patch says so the way git does.
            if line.last != newline {
                body.append(newline)
                body.append(contentsOf: Array("\\ No newline at end of file\n".utf8))
            }
        }
        func line(_ lines: [ArraySlice<UInt8>], _ number: Int?, as text: String) throws -> ArraySlice<UInt8> {
            guard let number, number >= 1, number <= lines.count, Self.reads(lines[number - 1], as: text) else {
                throw HunkDiscardError.mismatch
            }
            return lines[number - 1]
        }

        for diffLine in hunk.lines {
            switch diffLine.kind {
            case .context:
                let before = try line(oldLines, diffLine.oldNumber, as: diffLine.text)
                let after = try line(newLines, diffLine.newNumber, as: diffLine.text)
                guard before == after else { throw HunkDiscardError.mismatch }
                add(space, before)
                oldCount += 1
                newCount += 1
            case .deletion:
                add(minus, try line(oldLines, diffLine.oldNumber, as: diffLine.text))
                oldCount += 1
            case .addition:
                add(plus, try line(newLines, diffLine.newNumber, as: diffLine.text))
                newCount += 1
            case .noNewline:
                // Worked out from the blobs instead.
                continue
            }
        }
        // A hunk cut short for display, or one whose lines don't add up, is not the whole hunk.
        guard oldCount == hunk.oldCount, newCount == hunk.newCount, oldCount + newCount > 0 else {
            throw HunkDiscardError.mismatch
        }

        let header = Self.header(path: path)
        var discard = Data(header)
        discard.append(contentsOf: Self.range(oldStart: hunk.oldStart, oldCount: hunk.oldCount,
                                              newStart: hunk.newStart, newCount: hunk.newCount))
        discard.append(contentsOf: body)
        let restoreStarts = Self.restoreStarts(of: hunk)
        var restore = Data(header)
        restore.append(contentsOf: Self.range(oldStart: restoreStarts.old, oldCount: hunk.oldCount,
                                              newStart: restoreStarts.new, newCount: hunk.newCount))
        restore.append(contentsOf: body)
        return HunkPatch(discard: discard, restore: restore)
    }

    /// The file without `hunk`: the working tree's lines, with the hunk's replaced by the
    /// baseline's. `new` must be the file exactly as it is on disk; `build` checks the hunk
    /// against both blobs first.
    public static func discarding(_ hunk: DiffHunk, old: Data, new: Data) throws -> Data {
        let oldLines = lines(of: old)
        let newLines = lines(of: new)
        // With no lines on a side, its start names the line before.
        let oldFirst = hunk.oldCount > 0 ? hunk.oldStart - 1 : hunk.oldStart
        let newFirst = hunk.newCount > 0 ? hunk.newStart - 1 : hunk.newStart
        guard oldFirst >= 0, newFirst >= 0, oldFirst + hunk.oldCount <= oldLines.count,
              newFirst + hunk.newCount <= newLines.count else { throw HunkDiscardError.mismatch }
        let before = newLines[..<newFirst]
        let middle = oldLines[oldFirst..<(oldFirst + hunk.oldCount)]
        let after = newLines[(newFirst + hunk.newCount)...]
        // Only the file's last line may lack its newline.
        if !after.isEmpty, let last = middle.last ?? before.last, last.last != newline { throw HunkDiscardError.mismatch }
        if !middle.isEmpty, let last = before.last, last.last != newline { throw HunkDiscardError.mismatch }
        var result = Data()
        for line in before { result.append(contentsOf: line) }
        for line in middle { result.append(contentsOf: line) }
        for line in after { result.append(contentsOf: line) }
        return result
    }

    /// Where the hunk's lines are once it is discarded. The baseline's lines then stand where the
    /// working tree's began, so the patch that puts them back starts both sides there. With no
    /// lines on a side, its start names the line before, as in any unified diff.
    static func restoreStarts(of hunk: DiffHunk) -> (old: Int, new: Int) {
        let firstNewLine = hunk.newCount > 0 ? hunk.newStart : hunk.newStart + 1
        return (hunk.oldCount > 0 ? firstNewLine : firstNewLine - 1, hunk.newStart)
    }

    // MARK: Pieces

    private static let newline = UInt8(ascii: "\n")
    private static let space = UInt8(ascii: " ")
    private static let plus = UInt8(ascii: "+")
    private static let minus = UInt8(ascii: "-")

    /// The file's lines, each with its newline; the last may have none.
    static func lines(of data: Data) -> [ArraySlice<UInt8>] {
        let bytes = [UInt8](data)
        var result: [ArraySlice<UInt8>] = []
        var start = 0
        for index in bytes.indices where bytes[index] == newline {
            result.append(bytes[start...index])
            start = index + 1
        }
        if start < bytes.count { result.append(bytes[start...]) }
        return result
    }

    /// Whether a line of the blob is the line the diff showed: the parser drops the newline and
    /// a carriage return before it, and reads the rest as UTF-8.
    static func reads(_ line: ArraySlice<UInt8>, as text: String) -> Bool {
        var content = line
        if content.last == newline { content = content.dropLast() }
        if content.last == UInt8(ascii: "\r") { content = content.dropLast() }
        return String(decoding: content, as: UTF8.self) == text
    }

    private static func header(path: String) -> [UInt8] {
        let old = quoted("a/" + path)
        let new = quoted("b/" + path)
        // Appended a piece at a time: one long sum of arrays is more than some compilers will type-check.
        var header: [UInt8] = Array("diff --git ".utf8)
        header.append(contentsOf: old)
        header.append(space)
        header.append(contentsOf: new)
        header.append(newline)
        header.append(contentsOf: Array("--- ".utf8))
        header.append(contentsOf: old)
        header.append(newline)
        header.append(contentsOf: Array("+++ ".utf8))
        header.append(contentsOf: new)
        header.append(newline)
        return header
    }

    private static func range(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) -> [UInt8] {
        Array("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n".utf8)
    }

    /// A path as git writes it in a patch: in C-style quotes when it holds a quote, a backslash or
    /// a control character, as is otherwise, UTF-8 included.
    static func quoted(_ name: String) -> [UInt8] {
        let bytes = Array(name.utf8)
        guard bytes.contains(where: { $0 < 0x20 || $0 == 0x7F || $0 == UInt8(ascii: "\"") || $0 == UInt8(ascii: "\\") }) else {
            return bytes
        }
        var result: [UInt8] = [UInt8(ascii: "\"")]
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "\""): result += Array("\\\"".utf8)
            case UInt8(ascii: "\\"): result += Array("\\\\".utf8)
            case 0x07: result += Array("\\a".utf8)
            case 0x08: result += Array("\\b".utf8)
            case 0x09: result += Array("\\t".utf8)
            case 0x0A: result += Array("\\n".utf8)
            case 0x0B: result += Array("\\v".utf8)
            case 0x0C: result += Array("\\f".utf8)
            case 0x0D: result += Array("\\r".utf8)
            case ..<0x20, 0x7F: result += Array(("\\" + String(byte, radix: 8).leftPadded(to: 3)).utf8)
            default: result.append(byte)
            }
        }
        result.append(UInt8(ascii: "\""))
        return result
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}

/// A change Mimamori threw away from the working tree, a hunk or a whole file, with what it
/// takes to put it back.
public struct DiscardedChange: Sendable, Hashable, Identifiable {
    public enum Scope: Sendable, Hashable {
        /// One hunk, by its header and its patch.
        case hunk(header: String, patch: HunkPatch)
        /// The whole file put back as HEAD has it: rewritten when it was changed, moved to the
        /// Trash when it was new, written again when it was deleted.
        case file(ChangeKind)
    }

    public let id: UUID
    public let path: String
    public let date: Date
    public let scope: Scope
    /// The counts of what was thrown away: lines it had added, now gone, and removed, now back.
    public let additions: Int
    public let deletions: Int
    /// Recorded just before, with the file as it was.
    public let snapshot: SnapshotRecord
    /// The file's bytes before, as a blob in the object store; nil when there was no file.
    public let originalBlob: String?
    /// Its permissions before, to give it back with them.
    public let originalPermissions: Int?
    /// A digest of the file's bytes right after, to tell whether it changed since; nil when the
    /// discard left no file.
    public let resultDigest: String?

    public init(id: UUID = UUID(), path: String, date: Date, scope: Scope, additions: Int, deletions: Int,
                snapshot: SnapshotRecord, originalBlob: String?, originalPermissions: Int?, resultDigest: String?) {
        self.id = id
        self.path = path
        self.date = date
        self.scope = scope
        self.additions = additions
        self.deletions = deletions
        self.snapshot = snapshot
        self.originalBlob = originalBlob
        self.originalPermissions = originalPermissions
        self.resultDigest = resultDigest
    }

    /// "Discarded a hunk of src/cart.py", for the bar that offers Undo.
    public var summary: String {
        switch scope {
        case .hunk: "Discarded a hunk of \(path)"
        case .file(.added): "Discarded new file \(path)"
        case .file(.deleted): "Brought back deleted file \(path)"
        case .file: "Discarded the changes to \(path)"
        }
    }

    /// The command that brings the whole file back from the snapshot, for when Undo can't. It
    /// writes the working tree only, as `git restore` does by default.
    public var restoreCommand: String {
        let quotedPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        if originalBlob == nil { return "rm -- \(quotedPath)" }
        return "git restore --source=\(snapshot.commitOID.prefix(12)) -- \(quotedPath)"
    }
}

/// How putting a discarded change back went.
public struct DiscardRestore: Sendable, Hashable {
    /// The file was as the discard left it, so it is now exactly as it was before.
    public let exact: Bool
    /// Recorded just before putting the change back.
    public let snapshot: SnapshotRecord
}

public enum HunkDiscardError: Error, LocalizedError, Sendable, Equatable {
    /// This change can't be thrown away that way; the reason says why.
    case unsupported(String)
    /// The file on disk is no longer the one the diff was made from.
    case fileChanged
    /// git's line-ending or filter settings change this file on its way in or out, so its bytes
    /// on disk are not the ones the diff compared.
    case converted
    /// HEAD no longer has the version the diff compared with.
    case headMoved
    /// The hunk does not match the file's contents line for line.
    case mismatch
    /// git would not apply the hunk in reverse; its own words.
    case doesNotApply(String)
    /// The snapshot taken first does not hold the file, so it could not be put back.
    case notInSnapshot
    /// The discarded hunk no longer fits the file; git's own words.
    case restoreDoesNotApply(String)
    /// The file changed since a whole-file discard, so putting it back would lose that.
    case restoreBlocked
    /// The path is not a regular file inside the worktree (a link, a folder, or gone).
    case notAFile
    /// An agent is in the middle of a turn in the worktree; the `WriteGate`'s reason.
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let reason):
            reason
        case .fileChanged:
            "The file changed after this diff was shown, so nothing was discarded. Look at it again once the diff catches up."
        case .converted:
            "This file goes through git's line-ending or filter settings, so Mimamori can't discard from it exactly. It left the file alone."
        case .headMoved:
            "A commit landed after this diff was shown, so nothing was discarded. Look at it again once the diff catches up."
        case .mismatch:
            "Mimamori couldn't match this hunk to the file's contents line for line, so it left the file alone."
        case .doesNotApply(let detail):
            "git wouldn't take the hunk back out, so the file is untouched." + Self.quote(detail)
        case .notInSnapshot:
            "The snapshot taken first doesn't hold this file (it may be too large), so nothing was discarded."
        case .restoreDoesNotApply(let detail):
            "The lines around the hunk changed since it was discarded, so it can't be put back by itself. The snapshot taken before the discard still has the file as it was." + Self.quote(detail)
        case .restoreBlocked:
            "The file changed since it was discarded, so putting it back would lose that. The snapshot taken before the discard still has it as it was."
        case .notAFile:
            "The path is no longer a plain file inside the worktree, so nothing was written."
        case .refused(let reason):
            reason
        }
    }

    private static func quote(_ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : " (\(trimmed))"
    }
}

/// Which changes Mimamori can throw away.
public enum Discarding {
    /// Why this change's hunks can't be thrown away one by one; nil when they can. Only a file
    /// that has text on both sides qualifies: a new file is all one hunk, a deleted one has none
    /// left on disk, and a conflict is for resolving.
    public static func hunkUnsupportedReason(for change: FileChange) -> String? {
        if let reason = commonReason(for: change) { return reason }
        if change.isBinary { return "A binary file has no hunks to discard." }
        switch change.kind {
        case .modified, .renamed:
            break
        case .added:
            return "A new file is one hunk. Discard the whole file instead."
        case .deleted:
            return "The file is deleted, so there is nothing to discard from."
        default:
            return "This kind of change can't be discarded a hunk at a time."
        }
        guard change.oldOID != nil, change.newOID != nil else {
            return "This kind of change can't be discarded a hunk at a time."
        }
        return nil
    }

    /// Why this file can't be put back as HEAD has it in one go; nil when it can. A renamed file
    /// spans two paths, so it is left to you.
    public static func fileUnsupportedReason(for change: FileChange) -> String? {
        if let reason = commonReason(for: change) { return reason }
        switch change.kind {
        case .modified:
            guard change.oldOID != nil, change.newOID != nil else { break }
            return nil
        case .added:
            guard change.newOID != nil else { break }
            return nil
        case .deleted:
            guard change.oldOID != nil else { break }
            return nil
        case .renamed, .copied:
            return "A renamed file has two paths. Rename it back, or discard its hunks."
        default:
            break
        }
        return "This kind of change can't be discarded."
    }

    private static func commonReason(for change: FileChange) -> String? {
        if change.hasConflict || change.kind == .unmerged { return "Resolve the conflict in this file first." }
        if change.isSubmodule || change.oldMode == "160000" { return "A submodule pointer can't be discarded here." }
        if change.isSymlink || change.oldMode == "120000" { return "A symbolic link can't be discarded here." }
        return nil
    }
}
