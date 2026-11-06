import Foundation

/// The iPhones paired with this Mac, and the id the Mac advertises itself by. Kept in
/// `companion.json` beside the state file; the pairings' secrets are in the Keychain.
public struct CompanionPairings: Codable, Hashable, Sendable {
    public struct Phone: Codable, Hashable, Sendable, Identifiable {
        /// The pairing's id: the name its key is kept under, which the phone connects with.
        public var id: String
        public var name: String
        public var model: String?
        public var pairedAt: Date
        public var lastSeen: Date?

        public init(id: String, name: String, model: String? = nil, pairedAt: Date, lastSeen: Date? = nil) {
            self.id = id
            self.name = name
            self.model = model
            self.pairedAt = pairedAt
            self.lastSeen = lastSeen
        }
    }

    /// Random, made once: what a phone recognizes this Mac by in its Bonjour record, whatever the
    /// Mac is called.
    public var macID: String
    public var phones: [Phone]

    public init(macID: String = UUID().uuidString, phones: [Phone] = []) {
        self.macID = macID
        self.phones = phones
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        macID = c.decode(.macID, or: UUID().uuidString)
        phones = c.decode(.phones, or: [])
    }

    /// The file's pairings, or none with a new Mac id when there is no file yet or it can't be read.
    public static func load(from url: URL) -> CompanionPairings {
        guard let data = try? Data(contentsOf: url) else { return CompanionPairings() }
        return (try? decoder.decode(CompanionPairings.self, from: data)) ?? CompanionPairings()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
