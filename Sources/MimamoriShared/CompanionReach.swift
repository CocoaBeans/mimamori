import Foundation

/// Where a paired phone can reach the Mac when Bonjour can't find it, such as away from home over
/// Tailscale: the Mac's addresses on the tailnet, and the port it listens on. The Mac tells a phone
/// in its pairing code and on every connection the phone proves, so the phone learns it at home and
/// uses it away. The connection is the same TLS with the pairing's key, whichever way it goes.
public struct CompanionReach: Codable, Sendable, Hashable {
    /// Addresses to try, most likely first.
    public var hosts: [String]
    public var port: UInt16

    public init(hosts: [String], port: UInt16) {
        self.hosts = hosts
        self.port = port
    }

    /// Of the Mac's interface addresses, those on a tailnet, IPv4 first: Tailscale gives each
    /// device an address in 100.64.0.0/10 (the range set aside for carrier-grade NAT, which Macs
    /// don't otherwise get) and one in fd7a:115c:a1e0::/48, on a `utun` interface. Another VPN
    /// using the same range counts too, which is as good: the phone can reach it the same way.
    public static func tailnetAddresses(_ interfaces: [(name: String, address: String)]) -> [String] {
        let tunnels = interfaces.filter { $0.name.hasPrefix("utun") }
        let v4 = tunnels.map(\.address).filter(isTailnetIPv4)
        let v6 = tunnels.map(\.address).filter { $0.lowercased().hasPrefix("fd7a:115c:a1e0:") }
        var seen = Set<String>()
        return (v4 + v6).filter { seen.insert($0).inserted }
    }

    static func isTailnetIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        // 100.64.0.0/10: 100, then a second byte from 64 to 127.
        return parts[0] == 100 && parts[1] & 0xC0 == 0x40
    }

    /// The tailnet addresses this device has now.
    public static func currentTailnetAddresses() -> [String] {
        tailnetAddresses(interfaceAddresses())
    }

    /// Every IPv4 and IPv6 address on the device's interfaces, with the interface's name.
    static func interfaceAddresses() -> [(name: String, address: String)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let socket = entry.ifa_addr else { continue }
            let family = Int32(socket.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(socket, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            // A link-local IPv6 address carries its interface ("fe80::1%utun3"), which tailnet ones don't.
            found.append((String(cString: entry.ifa_name), address.split(separator: "%").first.map(String.init) ?? address))
        }
        return found
    }
}
