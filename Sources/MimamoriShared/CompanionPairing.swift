import Foundation
import Security

/// What the Mac's pairing QR code holds, as a link the iPhone's camera opens in the companion:
/// `mimamori-companion://pair?v=1&mac=…&name=…&id=…&key=…`. The key is the pairing's secret, so
/// the code is shown only while you pair, and works for one phone.
public struct CompanionPairingCode: Sendable, Hashable {
    public static let scheme = "mimamori-companion"
    public static let version = 1

    /// Which Mac: it advertises this id in its Bonjour record, so a phone finds its own Mac by it.
    public var macID: String
    /// The Mac's name, to show on the phone.
    public var macName: String
    public var key: CompanionKey

    public init(macID: String, macName: String, key: CompanionKey) {
        self.macID = macID
        self.macName = macName
        self.key = key
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(Self.version)),
            URLQueryItem(name: "mac", value: macID),
            URLQueryItem(name: "name", value: macName),
            URLQueryItem(name: "id", value: key.identity),
            URLQueryItem(name: "key", value: Self.base64URL(key.secret)),
        ]
        return components.url!
    }

    /// The code in a pairing link, or nil for anything else, including a link from a newer
    /// Mimamori whose format this one doesn't know.
    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard value("v") == String(Self.version), let macID = value("mac"), let identity = value("id"),
              let secret = value("key").flatMap(Self.data(base64URL:)), secret.count == 32 else { return nil }
        self.init(macID: macID, macName: value("name") ?? "Mac", key: CompanionKey(identity: identity, secret: secret))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func data(base64URL text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// The Bonjour record's keys.
public enum CompanionBonjour {
    /// The Mac's id, as in its pairing codes.
    public static let macIDKey = "id"
}

/// Pairing secrets in the Keychain, on the Mac and on the phone alike: one generic password per
/// pairing, under its id.
public struct CompanionKeychain: Sendable {
    public static let standard = CompanionKeychain(service: "com.kevinross.Mimamori.companion")

    public let service: String

    public init(service: String) {
        self.service = service
    }

    private func query(_ identity: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let identity { query[kSecAttrAccount as String] = identity }
        return query
    }

    /// Keeps `key`, replacing any secret kept under its id.
    public func save(_ key: CompanionKey) throws {
        SecItemDelete(query(key.identity) as CFDictionary)
        var item = query(key.identity)
        item[kSecValueData as String] = key.secret
        item[kSecAttrLabel as String] = "Mimamori companion pairing"
        // Readable after the first unlock, so a phone staying connected in the background can
        // reconnect while it's locked.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw CompanionKeychainError(status: status) }
    }

    public func key(for identity: String) -> CompanionKey? {
        var item = query(identity)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let secret = result as? Data else { return nil }
        return CompanionKey(identity: identity, secret: secret)
    }

    public func delete(_ identity: String) {
        SecItemDelete(query(identity) as CFDictionary)
    }

    /// Every pairing's secret, as Uninstall removes them.
    public func deleteAll() {
        SecItemDelete(query() as CFDictionary)
    }
}

public struct CompanionKeychainError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}
