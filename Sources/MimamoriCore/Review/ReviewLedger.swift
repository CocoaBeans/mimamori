import Foundation

/// What one file looked like when you marked it reviewed.
public struct ReviewMark: Codable, Hashable, Sendable {
    /// Identifies the working-tree content you saw; see `ReviewLedger.fingerprint(of:)`.
    public var fingerprint: String
    /// The working-tree blob you saw, kept so a later edit can be diffed against it.
    public var blob: String?
    public var reviewedAt: Date

    public init(fingerprint: String, blob: String?, reviewedAt: Date) {
        self.fingerprint = fingerprint
        self.blob = blob
        self.reviewedAt = reviewedAt
    }

    // A mark is its fingerprint and time: without them it is dropped, and the rest of the ledger kept.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        reviewedAt = try c.decode(Date.self, forKey: .reviewedAt)
        blob = c.decode(.blob, or: nil)
    }
}

public enum ReviewStatus: Hashable, Sendable {
    case unreviewed
    case reviewed(at: Date)
    /// Reviewed once, but the file has changed since.
    case changedSinceReview(ReviewMark)

    public var isReviewed: Bool {
        if case .reviewed = self { return true }
        return false
    }
}

/// Per-worktree record of which changes you have looked at.
///
/// A mark covers the content you saw, not the path: when an agent edits a reviewed
/// file again its fingerprint moves on and the file reads as changed since review.
/// Marks are keyed by the working-tree side only, so switching baselines keeps them.
public struct ReviewLedger: Codable, Hashable, Sendable {
    public private(set) var marks: [String: ReviewMark] = [:]

    public init() {}

    // Marks are read one at a time, so one that can't be read loses only itself.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReviewLedger()
        marks = c.decode(.marks, or: defaults.marks)
    }

    public var isEmpty: Bool { marks.isEmpty }

    public static func fingerprint(of change: FileChange) -> String {
        if let new = change.newOID { return "\(change.newMode):\(new)" }
        return "deleted:\(change.oldOID ?? "")"
    }

    public func status(of change: FileChange) -> ReviewStatus {
        guard let mark = marks[change.path] else { return .unreviewed }
        if mark.fingerprint == Self.fingerprint(of: change) { return .reviewed(at: mark.reviewedAt) }
        return .changedSinceReview(mark)
    }

    public func isReviewed(_ change: FileChange) -> Bool { status(of: change).isReviewed }

    public mutating func markReviewed(_ change: FileChange, at date: Date = Date()) {
        marks[change.path] = ReviewMark(fingerprint: Self.fingerprint(of: change), blob: change.newOID, reviewedAt: date)
    }

    public mutating func clear(_ path: String) {
        marks.removeValue(forKey: path)
    }

    public mutating func clearAll() {
        marks.removeAll()
    }

    /// Drops marks for paths that no longer differ from the baseline and were made before
    /// `cutoff`. Recent marks stay, so a file that is reverted and redone within the window
    /// still remembers what you saw. Returns true when anything was removed.
    @discardableResult
    public mutating func prune(keepingPaths current: Set<String>, olderThan cutoff: Date) -> Bool {
        let before = marks.count
        marks = marks.filter { current.contains($0.key) || $0.value.reviewedAt >= cutoff }
        return marks.count != before
    }
}

public extension Sequence where Element == FileChange {
    func reviewedCount(in ledger: ReviewLedger) -> Int {
        guard !ledger.isEmpty else { return 0 }
        return filter { ledger.isReviewed($0) }.count
    }
}
