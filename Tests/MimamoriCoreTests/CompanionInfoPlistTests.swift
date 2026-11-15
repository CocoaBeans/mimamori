import Foundation
import Testing

/// The iPhone companion has two Info.plists: one for builds of your own, and one for the App Store
/// configuration, which leaves out the `audio` background mode (App Review allows background audio
/// only for audio you can hear). Xcode can't add a background mode from a build setting, so the
/// two are files of their own; these keep them from drifting apart.
@Suite("The companion's Info.plists")
struct CompanionInfoPlistTests {
    private func plist(_ name: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/\(name)"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func differOnlyInTheBackgroundMode() throws {
        var full = try plist("MimamoriCompanion-Info.plist")
        let appStore = try plist("MimamoriCompanion-AppStore-Info.plist")
        #expect(full.removeValue(forKey: "UIBackgroundModes") as? [String] == ["audio"])
        #expect(NSDictionary(dictionary: full).isEqual(to: appStore))
    }

    @Test func theAppStoreOneHasNoBackgroundModes() throws {
        #expect(try plist("MimamoriCompanion-AppStore-Info.plist")["UIBackgroundModes"] == nil)
    }
}
