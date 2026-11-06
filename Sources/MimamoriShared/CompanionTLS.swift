import Foundation
import Network
import Security

/// A paired phone's key: a random secret both ends keep in their Keychain, and the pairing's id,
/// which the phone names when it connects so the Mac knows which secret to use.
public struct CompanionKey: Sendable, Hashable {
    public var identity: String
    public var secret: Data

    public init(identity: String, secret: Data) {
        self.identity = identity
        self.secret = secret
    }

    /// 32 random bytes, for a new pairing.
    public static func newSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "No random bytes for a companion key")
        return Data(bytes)
    }
}

/// How the Mac and the phone talk: TCP with TLS keyed by the pairing's secret, so only a paired
/// phone can connect, and nobody else on the network can read or answer for you. TLS 1.2 with a
/// pre-shared key, as Network.framework offers it, needs no certificates.
public enum CompanionTLS {
    /// Parameters for the Mac's listener, which accepts any of `keys`, or for a phone's connection,
    /// which offers its one.
    public static func parameters(keys: [CompanionKey]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for key in keys {
            let secret = key.secret.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = Data(key.identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, secret as __DispatchData, identity as __DispatchData)
        }
        // The pre-shared-key suites are TLS 1.2's.
        if let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)) {
            sec_protocol_options_append_tls_ciphersuite(options, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)

        // Keepalives notice a phone that went away without closing, such as one put to sleep.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        return NWParameters(tls: tls, tcp: tcp)
    }
}
