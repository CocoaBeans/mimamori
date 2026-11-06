import CryptoKit
import Foundation
import Security

/// How a phone proves which pairing it is. TLS only shows that it holds one of the paired keys,
/// any of them, and the pairing id in its hello is just a claim. So the Mac sends each connection
/// a fresh nonce, and the phone answers with an HMAC of it under its pairing's secret: only the
/// phone holding that secret can make it, and only for this connection.
public enum CompanionProof {
    /// Names what the MAC is for, so it can't be mistaken for any other use of the secret.
    static let label = Data("mimamori-companion-proof-v1".utf8)
    public static let nonceLength = 32

    /// 32 random bytes, a new one for each connection.
    public static func newNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "No random bytes for a companion challenge")
        return Data(bytes)
    }

    /// The label, then the nonce, then the pairing id. The first two have fixed lengths, so the id
    /// can't be shifted into them.
    static func message(nonce: Data, pairingID: String) -> Data {
        var data = label
        data.append(nonce)
        data.append(Data(pairingID.utf8))
        return data
    }

    /// What the phone sends for `nonce`, as the pairing `pairingID` with its `secret`.
    public static func mac(secret: Data, nonce: Data, pairingID: String) -> Data {
        let code = HMAC<SHA256>.authenticationCode(for: message(nonce: nonce, pairingID: pairingID),
                                                   using: SymmetricKey(data: secret))
        return Data(code)
    }

    /// Whether `mac` proves the pairing `pairingID` for `nonce`. Compared in constant time.
    public static func isValid(_ mac: Data, secret: Data, nonce: Data, pairingID: String) -> Bool {
        guard nonce.count == nonceLength else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message(nonce: nonce, pairingID: pairingID),
                                                      using: SymmetricKey(data: secret))
    }
}
