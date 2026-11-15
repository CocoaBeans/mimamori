import Foundation

/// How the phone tries to reach a paired Mac next: by Bonjour on this network when it's found
/// there, otherwise, once Bonjour has had its moment, at the Mac's tailnet address.
public enum CompanionRoute: Equatable, Sendable {
    /// The Bonjour service by this name, on this network.
    case service(String)
    /// The Mac's tailnet address, away from its network.
    case away(host: String, port: UInt16)
    /// Bonjour hasn't had long enough to find it: ask again after this many seconds.
    case wait(TimeInterval)
    /// Nowhere to try: not found here, and no tailnet address known.
    case none

    /// How long Bonjour gets before the phone goes the long way: on the same network it answers
    /// within a second.
    public static let bonjourGrace: TimeInterval = 2.5

    /// The route for this try. `own` is the Mac's Bonjour service when it's found by its id;
    /// `others` are the other Mimamori services found, tried when it isn't, in case one is the Mac
    /// under an id it no longer has; `attempts` counts the tries since it last connected, to move
    /// on each time; `browsing` is how long Bonjour has been looking.
    public static func next(own: String?, others: [String], reach: CompanionReach?, attempts: Int,
                            browsing: TimeInterval) -> CompanionRoute {
        if let own { return .service(own) }
        let away = reach.flatMap { $0.hosts.isEmpty || $0.port == 0 ? nil : $0 }
        // Each other Mac once, then the tailnet: on someone else's network, theirs never lets this
        // phone in.
        if !others.isEmpty, away == nil || attempts < others.count {
            return .service(others[attempts % others.count])
        }
        guard let away else { return .none }
        guard browsing >= bonjourGrace else { return .wait(bonjourGrace - browsing) }
        return .away(host: away.hosts[attempts % away.hosts.count], port: away.port)
    }
}
