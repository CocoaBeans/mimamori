import Foundation
import Testing
@testable import MimamoriCore

@Suite("Moving over from Vigil")
struct MigrationTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func movesTheSettingsFolderAcross() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent(FormerName.supportFolder)
        let destination = base.appendingPathComponent("Mimamori")
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("index"), withIntermediateDirectories: true)
        try Data("{\"repositories\":[]}".utf8).write(to: legacy.appendingPathComponent("state.json"))
        try Data("log".utf8).write(to: legacy.appendingPathComponent("activity.jsonl"))
        try Data().write(to: legacy.appendingPathComponent(FormerName.socketFile))

        #expect(try SupportFolderMigration.migrate(from: legacy, to: destination))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        for name in ["state.json", "state.json.before-rename", "activity.jsonl", "index"] {
            #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path), "\(name)")
        }
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(FormerName.socketFile).path))
        // A second launch finds nothing left to move.
        #expect(try !SupportFolderMigration.migrate(from: legacy, to: destination))
    }

    @Test func leavesAnExistingFolderAlone() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent(FormerName.supportFolder)
        let destination = base.appendingPathComponent("Mimamori")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        #expect(try !SupportFolderMigration.migrate(from: legacy, to: destination))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        // Nothing to move at all.
        #expect(try !SupportFolderMigration.migrate(from: base.appendingPathComponent("Missing"), to: base.appendingPathComponent("Other")))
    }

    @Test func replacesClaudeCodeHooksFromBeforeTheRename() throws {
        let oldCommand = "curl -s -m 1 -H 'Expect:' -H 'Content-Type: application/json' --unix-socket \"$HOME/Library/Application Support/"
            + "\(FormerName.supportFolder)/\(FormerName.socketFile)\" --data-binary @- http://old/event >/dev/null 2>&1 || true"
        var hooks: [String: Any] = [:]
        for event in ClaudeHooksConfig.events {
            var entry: [String: Any] = ["hooks": [["type": "command", "command": oldCommand, "timeout": 5]]]
            if let matcher = event.matcher { entry["matcher"] = matcher }
            hooks[event.name] = [entry]
        }
        // A hook of the user's own, which stays.
        var stop = hooks["Stop"] as! [[String: Any]]
        stop.append(["hooks": [["type": "command", "command": "say done"]]])
        hooks["Stop"] = stop
        let settings: [String: Any] = ["hooks": hooks, "model": "opus"]

        #expect(ClaudeHooksConfig.hasFormerHooks(in: settings))
        #expect(!ClaudeHooksConfig.isInstalled(in: settings))
        let newCommand = ClaudeHooksConfig.command(socketPath: "/tmp/mimamori.sock")
        let migrated = ClaudeHooksConfig.install(into: settings, command: newCommand)
        #expect(!ClaudeHooksConfig.hasFormerHooks(in: migrated))
        #expect(ClaudeHooksConfig.isInstalled(in: migrated))
        #expect(migrated["model"] as? String == "opus")
        let commands = (migrated["hooks"] as! [String: Any]).values.flatMap { ($0 as! [[String: Any]]).flatMap { $0["hooks"] as! [[String: Any]] } }
            .compactMap { $0["command"] as? String }
        #expect(commands.filter { $0 == newCommand }.count == ClaudeHooksConfig.events.count)
        #expect(commands.contains("say done"))
        #expect(commands.count == ClaudeHooksConfig.events.count + 1)
    }

    @Test func replacesHermesHooksFromBeforeTheRename() {
        let oldScript = "~/.hermes/" + FormerName.hermesScriptRelativePath
        let yaml = """
        # My Hermes config
        model: local
        toolsets:
          - terminal   # keep this comment

        \(FormerName.hermesBeginMarker)
        hooks:
          pre_tool_call:
            - command: "\(oldScript)"
              timeout: 5
        \(FormerName.hermesEndMarker)

        """
        #expect(HermesHooksConfig.hasFormerHooks(in: yaml))
        let newScript = "~/.hermes/" + HermesHooksConfig.scriptRelativePath
        let migrated = HermesHooksConfig.install(into: yaml, scriptPath: newScript)
        #expect(migrated != nil)
        guard let migrated else { return }
        #expect(!HermesHooksConfig.hasFormerHooks(in: migrated))
        #expect(HermesHooksConfig.isInstalled(in: migrated))
        #expect(migrated.contains("# keep this comment"))
        #expect(migrated.components(separatedBy: "hooks:").count == 2)
        // Merged by hand under a hooks: key of the user's own: recognised, but not edited.
        let manual = "hooks:\n  pre_tool_call:\n    - command: \"\(oldScript)\"\n"
        #expect(HermesHooksConfig.hasFormerHooks(in: manual))
        #expect(HermesHooksConfig.install(into: manual, scriptPath: newScript) == nil)
    }

    /// The old name appears in the code only where the migration needs it.
    @Test func noOtherCodeUsesTheFormerName() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let places = ["Sources", "Resources", "Scripts", ".github", "Mimamori.xcodeproj", "Package.swift"]
        let allowed = ["Sources/MimamoriCore/Migration/FormerName.swift"]
        var found: [String] = []
        for place in places {
            let url = root.appendingPathComponent(place)
            let files: [URL]
            if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
                files = enumerator.compactMap { $0 as? URL }
            } else {
                files = [url]
            }
            for file in files {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                guard !allowed.contains(relative), let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                if text.range(of: "vigil", options: .caseInsensitive) != nil { found.append(relative) }
            }
        }
        #expect(found.isEmpty, "Still named Vigil: \(found.joined(separator: ", "))")
    }
}
