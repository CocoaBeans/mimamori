import Foundation

/// What the Mac and the iPhone companion say to each other: one JSON message per line.
///
/// Mac to phone: the agents, the same snapshot the desktop widgets draw. Phone to Mac: who it is,
/// once connected, and "send me a fresh snapshot". Each message carries the version of the format it was written in, so the two
/// apps can be updated at different times.
public struct CompanionMessage: Codable, Sendable, Equatable {
    /// The Bonjour service the Mac advertises and the phone browses for.
    public static let serviceType = "_mimamori._tcp"
    /// This format's version. Readers ignore fields they don't know, so it only goes up when a
    /// field's meaning changes.
    public static let currentVersion = 1

    public var version: Int
    /// The agents as they are now; Mac to phone.
    public var snapshot: AgentWidgetSnapshot?
    /// Asks for a snapshot now rather than at the next change; phone to Mac.
    public var wantsSnapshot: Bool?
    /// The phone introducing itself, first thing after connecting; phone to Mac.
    public var hello: Hello?

    /// What the Mac lists a paired phone by.
    public struct Hello: Codable, Sendable, Equatable {
        /// The pairing it connected with. TLS has already checked that the phone holds a paired
        /// key; this says which, for the Mac's list.
        public var pairingID: String
        /// "iPhone", or the phone's own name where iOS shares it.
        public var deviceName: String
        public var model: String?

        public init(pairingID: String, deviceName: String, model: String? = nil) {
            self.pairingID = pairingID
            self.deviceName = deviceName
            self.model = model
        }
    }

    public init(snapshot: AgentWidgetSnapshot? = nil, wantsSnapshot: Bool? = nil, hello: Hello? = nil) {
        self.version = Self.currentVersion
        self.snapshot = snapshot
        self.wantsSnapshot = wantsSnapshot
        self.hello = hello
    }

    /// The message as one line, ending in a newline. JSON escapes newlines inside strings, so
    /// the only one is the last.
    public func line() throws -> Data {
        var data = try Self.encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public init(line: Data) throws {
        self = try Self.decoder.decode(CompanionMessage.self, from: line)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// Splits what arrives on a connection into lines. Data comes in pieces of any size, so a line can
/// span pieces and a piece can hold several lines.
public struct CompanionLineReader: Sendable {
    /// Longer than any snapshot (a few kilobytes per agent). A peer that sends more without a
    /// newline is misbehaving, and its line is dropped rather than held.
    public static let defaultLimit = 4 * 1024 * 1024

    private var buffer = Data()
    private var discarding = false
    private let limit: Int

    public init(limit: Int = defaultLimit) {
        self.limit = limit
    }

    /// The complete lines in `data` and what came before it, without their newlines. Empty lines
    /// are skipped.
    public mutating func lines(adding data: Data) -> [Data] {
        var lines: [Data] = []
        var rest = data[...]
        while let newline = rest.firstIndex(of: 0x0A) {
            let piece = rest[..<newline]
            rest = rest[rest.index(after: newline)...]
            if discarding {
                discarding = false
                buffer.removeAll()
                continue
            }
            buffer.append(contentsOf: piece)
            if !buffer.isEmpty, buffer.count <= limit { lines.append(buffer) }
            buffer = Data()
        }
        if !discarding {
            buffer.append(contentsOf: rest)
            if buffer.count > limit {
                discarding = true
                buffer.removeAll()
            }
        }
        return lines
    }
}
