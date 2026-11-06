import Foundation

/// What the Mac and the iPhone companion say to each other: one JSON message per line.
///
/// Mac to phone: a challenge, first thing; the agents, the same snapshot the desktop widgets draw;
/// and what became of an answer. Phone to Mac: who it is, once connected, its proof of that, "send
/// me a fresh snapshot", and Allow or Deny for a permission request. Each message carries the
/// version of the format it was written in, so the two apps can be updated at different times: an
/// older Mac ignores an answer or a proof it doesn't know, and an older phone a challenge or a
/// request it can't answer.
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
    /// Allow or Deny for a permission request the snapshot showed; phone to Mac.
    public var answer: Answer?
    /// What the Mac did with an answer; Mac to phone.
    public var answerResult: AnswerResult?
    /// A fresh nonce for the phone to prove its pairing with, first thing on a connection; Mac to phone.
    public var challenge: Challenge?
    /// The phone's proof of which pairing it is (`CompanionProof`); phone to Mac.
    public var proof: Proof?

    /// Base64 in the JSON, as `Data` is by default.
    public struct Challenge: Codable, Sendable, Equatable {
        public var nonce: Data

        public init(nonce: Data) {
            self.nonce = nonce
        }
    }

    public struct Proof: Codable, Sendable, Equatable {
        public var pairingID: String
        /// HMAC-SHA256 of the challenge's nonce and `pairingID`, under the pairing's secret.
        public var mac: Data

        public init(pairingID: String, mac: Data) {
            self.pairingID = pairingID
            self.mac = mac
        }
    }

    /// Allow or Deny for one request, by its id. The Mac acts on it only while that request still
    /// waits, so an answer that arrives late, or names something else, does nothing.
    public struct Answer: Codable, Sendable, Equatable {
        public var requestID: String
        public var allow: Bool

        public init(requestID: String, allow: Bool) {
            self.requestID = requestID
            self.allow = allow
        }
    }

    /// Whether an answer settled its request, and if not, why, in a sentence for the phone.
    public struct AnswerResult: Codable, Sendable, Equatable {
        public var requestID: String
        public var accepted: Bool
        public var reason: String?

        public init(requestID: String, accepted: Bool, reason: String? = nil) {
            self.requestID = requestID
            self.accepted = accepted
            self.reason = reason
        }
    }

    /// The worktree whose agent's actions the phone shows, to be sent now and as they change;
    /// empty to stop. Phone to Mac.
    public var watchActions: String?
    /// The actions of the agent the phone watches; Mac to phone.
    public var actions: AgentActions?

    /// What the Mac lists a paired phone by.
    public struct Hello: Codable, Sendable, Equatable {
        /// The pairing it connected with. TLS has already checked that the phone holds a paired
        /// key; this says which, and the Mac believes it only once the phone proves it.
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

    public init(snapshot: AgentWidgetSnapshot? = nil, wantsSnapshot: Bool? = nil, hello: Hello? = nil,
                answer: Answer? = nil, answerResult: AnswerResult? = nil, challenge: Challenge? = nil, proof: Proof? = nil,
                watchActions: String? = nil, actions: AgentActions? = nil) {
        self.version = Self.currentVersion
        self.snapshot = snapshot
        self.wantsSnapshot = wantsSnapshot
        self.hello = hello
        self.answer = answer
        self.answerResult = answerResult
        self.challenge = challenge
        self.proof = proof
        self.watchActions = watchActions
        self.actions = actions
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
