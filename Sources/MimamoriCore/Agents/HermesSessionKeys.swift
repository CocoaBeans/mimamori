import Foundation

/// Which Hermes session each session key belongs to.
///
/// Hermes's approval hooks name the session by its key (`extra.session_key`), and name its id
/// only when the command was the turn's own call. A command run from `execute_code` asks with
/// no session id, and filed under no session the request was dropped, so Hermes could wait on
/// you with nothing showing. Hermes records each session's key in `state.db`.
public struct HermesSessionKeys: Sendable {
    /// Keys remembered; a session has one, so this covers many sessions.
    public static let capacity = 64

    private struct Entry: Sendable {
        var session: String?
        var at: Date
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// Remembers the session of a Hermes event that names both, and gives one that names only
    /// a key the session that key belongs to.
    /// - Parameter lookup: Hermes's record of a key's session, asked when this has none for it,
    ///   and again a few seconds after a miss: a session's row is written as its first turn starts.
    public mutating func resolve(_ event: inout HookEvent, now: Date = Date(), lookup: (String) -> String?) {
        guard event.agent == .hermes, let key = event.hermesSessionKey else { return }
        if let session = event.sessionID {
            remember(key: key, session: session, at: now)
            return
        }
        // A gateway chat's key moves to a new session when you reset it, so a hit is asked again too.
        if let known = entries[key], now.timeIntervalSince(known.at) < (known.session == nil ? 5 : 60) {
            event.sessionID = known.session
            return
        }
        let session = lookup(key)
        remember(key: key, session: session, at: now)
        event.sessionID = session
    }

    private mutating func remember(key: String, session: String?, at now: Date) {
        entries[key] = Entry(session: session, at: now)
        if entries.count > Self.capacity, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key {
            entries.removeValue(forKey: oldest)
        }
    }
}
