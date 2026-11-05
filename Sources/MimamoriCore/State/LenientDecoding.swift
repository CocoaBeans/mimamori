import Foundation

// Saved state is read with these, so a file from an older or newer Mimamori still opens: a key
// that is missing or can't be read takes its default, and a list keeps the entries it can read.
// Defaults live in the property initializers; a type's `init(from:)` passes them in as fallbacks.
extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` when it is missing, null or can't be read.
    func decode<T: Decodable>(_ key: Key, or fallback: @autoclosure () -> T) -> T {
        guard has(key) else { return fallback() }
        return (try? decode(T.self, forKey: key)) ?? fallback()
    }

    /// The entries of the list at `key` that can be read, one at a time; `fallback` when it is
    /// missing, null or not a list.
    func decode<Element: Decodable>(_ key: Key, or fallback: @autoclosure () -> [Element]) -> [Element] {
        guard has(key), var list = try? nestedUnkeyedContainer(forKey: key) else { return fallback() }
        var kept: [Element] = []
        while !list.isAtEnd {
            if let element = try? list.decode(Element.self) {
                kept.append(element)
            } else if (try? list.decode(Skipped.self)) == nil {
                break
            }
        }
        return kept
    }

    /// Like the list above: an element it doesn't know, such as a newer version's enum case, is dropped.
    func decode<Element: Decodable & Hashable>(_ key: Key, or fallback: @autoclosure () -> Set<Element>) -> Set<Element> {
        guard has(key) else { return fallback() }
        return Set(decode(key, or: Array(fallback())))
    }

    /// The entries of the dictionary at `key` that can be read, one at a time.
    func decode<Value: Decodable>(_ key: Key, or fallback: @autoclosure () -> [String: Value]) -> [String: Value] {
        guard has(key), let entries = try? nestedContainer(keyedBy: AnyCodingKey.self, forKey: key) else { return fallback() }
        var kept: [String: Value] = [:]
        for entry in entries.allKeys {
            if let value = try? entries.decode(Value.self, forKey: entry) { kept[entry.stringValue] = value }
        }
        return kept
    }

    /// Whether `key` is there with a value other than null.
    private func has(_ key: Key) -> Bool {
        (try? decodeNil(forKey: key)) == false
    }
}

/// Reads any value and keeps nothing, to step past a list entry that can't be read.
private struct Skipped: Decodable {
    init(from decoder: Decoder) {}
}

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
