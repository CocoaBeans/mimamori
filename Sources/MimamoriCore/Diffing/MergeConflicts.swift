import Foundation

/// The merge conflicts in a diff's new file, found by their markers, so the diff can show each
/// one as two labelled sides (and, in diff3 style, the common ancestor between them) rather
/// than as lines someone added. Lines are told apart by their number in the new file, so a
/// conflict that spans two hunks, with lines between them left out, still reads as one.
public struct MergeConflicts: Sendable, Hashable {
    public struct Conflict: Sendable, Hashable {
        /// 1 for the first in the file.
        public var number: Int
        /// The labels git wrote on the markers: usually "HEAD", and the branch or commit merged.
        public var current: String
        public var incoming: String
        /// The common ancestor's label, in diff3 style.
        public var base: String?
        /// New-file line numbers of the markers; nil for one not reached.
        public var opening: Int
        public var baseMarker: Int?
        public var divider: Int?
        public var closing: Int?
    }

    /// Which part of a conflict a line is.
    public enum Part: Sendable, Hashable {
        case opening, current, baseMarker, base, divider, incoming, closing

        public var isMarker: Bool {
            switch self {
            case .opening, .baseMarker, .divider, .closing: true
            case .current, .base, .incoming: false
            }
        }
    }

    public struct Placement: Sendable, Hashable {
        public var conflict: Conflict
        public var part: Part
        /// How many conflicts the file has.
        public var total: Int
    }

    public let conflicts: [Conflict]

    public static let none = MergeConflicts(conflicts: [])

    public init(conflicts: [Conflict]) {
        self.conflicts = conflicts
    }

    public var isEmpty: Bool { conflicts.isEmpty }

    /// The conflicts in `diff`'s new file. Removed lines belong to the old file and are skipped.
    public init(diff: FileDiff) {
        var found: [Conflict] = []
        var open: Conflict?
        let lines = diff.hunks.flatMap(\.lines).filter { $0.kind != .deletion }
        for line in lines {
            guard let number = line.newNumber else { continue }
            let text = line.text
            if let label = Self.label(of: text, marker: "<<<<<<<") {
                // A second opening before the first closed: the first was left unfinished.
                if let unfinished = open { found.append(unfinished) }
                open = Conflict(number: found.count + 1, current: label, incoming: "", opening: number)
            } else if var conflict = open {
                if conflict.divider == nil, conflict.baseMarker == nil, let label = Self.label(of: text, marker: "|||||||") {
                    conflict.base = label
                    conflict.baseMarker = number
                    open = conflict
                } else if conflict.divider == nil, text == "=======" {
                    conflict.divider = number
                    open = conflict
                } else if conflict.divider != nil, let label = Self.label(of: text, marker: ">>>>>>>") {
                    conflict.incoming = label
                    conflict.closing = number
                    found.append(conflict)
                    open = nil
                }
            }
        }
        if let unfinished = open { found.append(unfinished) }
        conflicts = found
    }

    /// Where a line of the new file falls, if inside a conflict.
    public func placement(ofLine number: Int) -> Placement? {
        guard let conflict = conflicts.last(where: { $0.opening <= number }),
              number <= (conflict.closing ?? .max) else { return nil }
        let part: Part
        if number == conflict.opening {
            part = .opening
        } else if number == conflict.closing {
            part = .closing
        } else if number == conflict.divider {
            part = .divider
        } else if number == conflict.baseMarker {
            part = .baseMarker
        } else if let divider = conflict.divider, number > divider {
            part = .incoming
        } else if let base = conflict.baseMarker, number > base {
            part = .base
        } else {
            part = .current
        }
        return Placement(conflict: conflict, part: part, total: conflicts.count)
    }

    /// The text after a marker, when `text` is one: "<<<<<<< HEAD" → "HEAD". Markers sit at the
    /// start of the line, seven characters long, then a space and a label, or nothing.
    static func label(of text: String, marker: String) -> String? {
        guard text.hasPrefix(marker) else { return nil }
        let rest = text.dropFirst(marker.count)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }
}
