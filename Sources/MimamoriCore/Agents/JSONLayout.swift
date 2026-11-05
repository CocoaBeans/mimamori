import Foundation

/// Writes a JSON object back in the layout it was read in, so an edit changes only what it
/// changes. Every value left as it was is copied byte for byte from the original; keys keep their
/// order, and new ones follow, in `keyOrder` and then by name. New text copies the original's
/// indentation, line endings and `:` spacing. Without an original it writes two-space indented
/// JSON.
enum JSONLayout {
    static func data(for object: [String: Any], keepingLayoutOf original: Data?, keyOrder: [String] = []) -> Data {
        let bytes = original.map { [UInt8]($0) } ?? []
        var parser = Parser(bytes: bytes)
        let root = original == nil ? nil : parser.document()
        let writer = Writer(bytes: bytes, style: Style(root: root, bytes: bytes), keyOrder: keyOrder)
        var text = ""
        if let root {
            text += String(decoding: bytes[..<root.range.lowerBound], as: UTF8.self)
            writer.write(object, template: root, depth: 0, into: &text)
            text += String(decoding: bytes[root.range.upperBound...], as: UTF8.self)
        } else {
            writer.write(object, template: nil, depth: 0, into: &text)
            text += writer.style.newline ?? "\n"
        }
        let data = Data(text.utf8)
        // Should the layout ever come out wrong, fall back to plain JSON with the same content.
        guard let check = try? JSONSerialization.jsonObject(with: data), (check as AnyObject).isEqual(object) else {
            let plain = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return plain + Data("\n".utf8)
        }
        return data
    }

    /// A value in the original text.
    struct Node {
        enum Kind {
            case scalar
            case array([Node])
            case object([Member])
        }
        struct Member {
            var key: String
            var keyRange: Range<Int>
            var value: Node
        }
        var kind: Kind
        var range: Range<Int>
    }

    /// How the original is laid out, read from its top-level object.
    struct Style {
        /// nil for JSON on one line.
        var newline: String? = "\n"
        var indent = "  "
        var colon = ": "
        /// What follows a comma on one line.
        var afterComma = ""

        init(root: Node?, bytes: [UInt8]) {
            guard let root, case .object(let members) = root.kind, let first = members.first else { return }
            // Bytes, not characters: Swift reads "\r\n" as one character.
            let lead = (root.range.lowerBound + 1)..<first.keyRange.lowerBound
            if let lastBreak = lead.last(where: { bytes[$0] == 0x0A }) {
                newline = lastBreak > lead.lowerBound && bytes[lastBreak - 1] == 0x0D ? "\r\n" : "\n"
                indent = String(decoding: bytes[(lastBreak + 1)..<lead.upperBound], as: UTF8.self)
            } else {
                newline = nil
                if members.count > 1 {
                    var comma = first.value.range.upperBound
                    while comma < bytes.count, bytes[comma] != UInt8(ascii: ",") { comma += 1 }
                    if comma < members[1].keyRange.lowerBound {
                        afterComma = String(decoding: bytes[(comma + 1)..<members[1].keyRange.lowerBound], as: UTF8.self)
                    }
                }
            }
            colon = String(decoding: bytes[first.keyRange.upperBound..<first.value.range.lowerBound], as: UTF8.self)
        }
    }

    struct Writer {
        let bytes: [UInt8]
        let style: Style
        let keyOrder: [String]

        func write(_ value: Any, template: Node?, depth: Int, into text: inout String) {
            if let template, same(value, template) {
                text += String(decoding: bytes[template.range], as: UTF8.self)
                return
            }
            if let object = value as? [String: Any] {
                var members: [Node.Member] = []
                if let template, case .object(let found) = template.kind { members = found }
                var keys: [String] = []
                for member in members where object[member.key] != nil && !keys.contains(member.key) {
                    keys.append(member.key)
                }
                keys += object.keys.filter { !keys.contains($0) }.sorted(by: comesFirst)
                let items: [(inout String) -> Void] = keys.map { key in
                    let model = members.first { $0.key == key }?.value
                    return { text in
                        text += scalar(key) + style.colon
                        write(object[key]!, template: model, depth: depth + 1, into: &text)
                    }
                }
                enclose(items, open: "{", close: "}", depth: depth, into: &text)
            } else if let array = value as? [Any] {
                var elements: [Node] = []
                if let template, case .array(let found) = template.kind { elements = found }
                var used = Set<Int>()
                let items: [(inout String) -> Void] = array.enumerated().map { index, element in
                    // The original element it equals, else the one in its place.
                    var match = elements.indices.first { !used.contains($0) && same(element, elements[$0]) }
                    if match == nil, index < elements.count, !used.contains(index) { match = index }
                    if let match { used.insert(match) }
                    let model = match.map { elements[$0] }
                    return { text in write(element, template: model, depth: depth + 1, into: &text) }
                }
                enclose(items, open: "[", close: "]", depth: depth, into: &text)
            } else {
                text += scalar(value)
            }
        }

        private func enclose(_ items: [(inout String) -> Void], open: String, close: String, depth: Int, into text: inout String) {
            guard !items.isEmpty else {
                text += open + close
                return
            }
            text += open
            for (index, item) in items.enumerated() {
                if index > 0 { text += "," }
                if let newline = style.newline {
                    text += newline + String(repeating: style.indent, count: depth + 1)
                } else if index > 0 {
                    text += style.afterComma
                }
                item(&text)
            }
            if let newline = style.newline { text += newline + String(repeating: style.indent, count: depth) }
            text += close
        }

        private func comesFirst(_ left: String, _ right: String) -> Bool {
            let leftRank = keyOrder.firstIndex(of: left) ?? Int.max
            let rightRank = keyOrder.firstIndex(of: right) ?? Int.max
            return leftRank != rightRank ? leftRank < rightRank : left < right
        }

        /// Whether `value` equals what `node` holds in the original.
        private func same(_ value: Any, _ node: Node) -> Bool {
            guard let original = try? JSONSerialization.jsonObject(with: Data(bytes[node.range]), options: .fragmentsAllowed) else {
                return false
            }
            return (original as AnyObject).isEqual(value)
        }

        private func scalar(_ value: Any) -> String {
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return data.map { String(decoding: $0, as: UTF8.self) } ?? "null"
        }
    }

    /// Finds where each value lies in valid JSON text. Returns nil for anything else.
    struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func document() -> Node? {
            skipSpace()
            guard let root = value() else { return nil }
            skipSpace()
            return index == bytes.count ? root : nil
        }

        private mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        private mutating func value() -> Node? {
            guard index < bytes.count else { return nil }
            let start = index
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var members: [Node.Member] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return Node(kind: .object(members), range: start..<index)
                }
                while true {
                    skipSpace()
                    let keyStart = index
                    guard let keyRange = string(),
                          let key = try? JSONSerialization.jsonObject(with: Data(bytes[keyRange]), options: .fragmentsAllowed) as? String
                    else { return nil }
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                    index += 1
                    skipSpace()
                    guard let member = value() else { return nil }
                    members.append(Node.Member(key: key, keyRange: keyStart..<keyRange.upperBound, value: member))
                    skipSpace()
                    guard index < bytes.count else { return nil }
                    index += 1
                    if bytes[index - 1] == UInt8(ascii: "}") { return Node(kind: .object(members), range: start..<index) }
                    guard bytes[index - 1] == UInt8(ascii: ",") else { return nil }
                }
            case UInt8(ascii: "["):
                index += 1
                var elements: [Node] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return Node(kind: .array(elements), range: start..<index)
                }
                while true {
                    skipSpace()
                    guard let element = value() else { return nil }
                    elements.append(element)
                    skipSpace()
                    guard index < bytes.count else { return nil }
                    index += 1
                    if bytes[index - 1] == UInt8(ascii: "]") { return Node(kind: .array(elements), range: start..<index) }
                    guard bytes[index - 1] == UInt8(ascii: ",") else { return nil }
                }
            case UInt8(ascii: "\""):
                guard let range = string() else { return nil }
                return Node(kind: .scalar, range: range)
            default:
                // A number, true, false or null: up to the next delimiter.
                while index < bytes.count, ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(bytes[index]) { index += 1 }
                return index > start ? Node(kind: .scalar, range: start..<index) : nil
            }
        }

        /// The string at `index`, quotes included.
        private mutating func string() -> Range<Int>? {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
            let start = index
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""):
                    index += 1
                    return start..<index
                default: index += 1
                }
            }
            return nil
        }
    }
}
