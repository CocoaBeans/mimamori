import Foundation
import Testing
@testable import MimamoriCore

@Suite("Hook backups")
struct HookBackupsTests {
    @Test func keepsTheNewestFewAndNothingElse() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("backups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = folder.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: settings)
        let stamps = (1...8).map { String(format: "2026-11-0%dT04-02-00Z", $0) }
        for stamp in stamps {
            try Data("{}".utf8).write(to: folder.appendingPathComponent("settings.json.\(stamp).mimamori-backup"))
        }
        // Someone else's backup, and another file's, are left alone.
        try Data("{}".utf8).write(to: folder.appendingPathComponent("settings.json.bak"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.yaml.2026-11-01T00-00-00Z.mimamori-backup"))

        #expect(HookBackups.list(of: settings).first?.lastPathComponent == "settings.json.2026-11-08T04-02-00Z.mimamori-backup")
        HookBackups.prune(settings)
        let kept = HookBackups.list(of: settings).map(\.lastPathComponent)
        #expect(kept == stamps.suffix(5).reversed().map { "settings.json.\($0).mimamori-backup" })
        let all = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(all.contains("settings.json.bak") && all.contains("config.yaml.2026-11-01T00-00-00Z.mimamori-backup"))
    }
}
