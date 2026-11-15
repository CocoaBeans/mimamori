#if os(iOS)
import ActivityKit

/// The iPhone companion's Live Activity: the agents on one Mac, which it names. The app updates it
/// as snapshots arrive, which it can only while it keeps running in the background.
public struct AgentsActivityAttributes: ActivityAttributes {
    public typealias ContentState = AgentsActivityState

    public var macName: String

    public init(macName: String) {
        self.macName = macName
    }
}
#endif
