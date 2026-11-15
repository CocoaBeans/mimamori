import Foundation
import Testing

/// The iPhone companion has two Info.plists: one for builds of your own, and one for the App Store
/// configuration, which leaves out the `audio` background mode (App Review allows background audio
/// only for audio you can hear), and with it the Live Activity, which only an app kept running can
/// keep current. Xcode can't add a background mode from a build setting, so the two are files of
/// their own; these keep them from drifting apart.
@Suite("The companion's Info.plists")
struct CompanionInfoPlistTests {
    private func plist(_ name: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/\(name)"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func differOnlyInTheBackgroundModeAndLiveActivities() throws {
        var full = try plist("MimamoriCompanion-Info.plist")
        let appStore = try plist("MimamoriCompanion-AppStore-Info.plist")
        #expect(full.removeValue(forKey: "UIBackgroundModes") as? [String] == ["audio"])
        #expect(full.removeValue(forKey: "NSSupportsLiveActivities") as? Bool == true)
        #expect(NSDictionary(dictionary: full).isEqual(to: appStore))
    }

    @Test func theAppStoreOneHasNoBackgroundModesOrLiveActivities() throws {
        let appStore = try plist("MimamoriCompanion-AppStore-Info.plist")
        #expect(appStore["UIBackgroundModes"] == nil)
        #expect(appStore["NSSupportsLiveActivities"] == nil)
    }
}
