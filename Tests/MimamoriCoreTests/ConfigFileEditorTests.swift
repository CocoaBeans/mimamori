import Foundation
import Testing
@testable import MimamoriCore

@Suite("Editing other tools' config files")
struct ConfigFileEditorTests {
    /// A throwaway folder standing in for `~/.claude`.
    private struct Folder {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("config-\(UUID().uuidString)")
        init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        func remove() { try? FileManager.default.removeItem(at: url) }
        func file(_ name: String) -> URL { url.appendingPathComponent(name) }
        var names: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }
    }

    /// The editor's error from `body`, or nil when it threw none.
    private func failure(_ body: () throws -> Any?) -> ConfigFileEditor.EditError? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? ConfigFileEditor.EditError
        }
    }

    /// A clock that moves only when told.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = Date(timeIntervalSince1970: 1_793_000_000)
        var now: Date { lock.withLock { time } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    }

    private let socket = "/tmp/mimamori-test/mimamori.sock"

    private func install(_ settings: [String: Any]) -> [String: Any] {
        ClaudeHooksConfig.install(into: settings, command: ClaudeHooksConfig.command(socketPath: socket),
                                  permissionCommand: ClaudeHooksConfig.permissionCommand(socketPath: socket))
    }

    private func editor(_ file: URL, clock: Clock = Clock()) -> ConfigFileEditor {
        ConfigFileEditor(file: file, now: { clock.now })
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    // MARK: Symlinks

    @Test func aSymlinkedSettingsFileStaysASymlink() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let dotfiles = folder.file("dotfiles")
        let claude = folder.file("claude")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let real = dotfiles.appendingPathComponent("claude-settings.json")
        let original = "{\n  \"model\": \"opus\"\n}\n"
        try Data(original.utf8).write(to: real)
        let link = claude.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../dotfiles/claude-settings.json")

        let editor = editor(link)
        #expect(try editor.resolvedFile().path == real.standardizedFileURL.path)
        let backup = try #require(try editor.editJSONObject(keyOrder: ClaudeHooksConfig.keyOrder, install))

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "../dotfiles/claude-settings.json")
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: real)) as? [String: Any])
        #expect(ClaudeHooksConfig.isInstalled(in: written))
        #expect(written["model"] as? String == "opus")
        // The backup is a copy of the file, beside the link, not another link to the live file.
        #expect(backup.deletingLastPathComponent().standardizedFileURL == claude.standardizedFileURL)
        let backupType = try FileManager.default.attributesOfItem(atPath: backup.path)[.type] as? FileAttributeType
        #expect(backupType == .typeRegular)
        #expect(try text(backup) == original)
        // Nothing left over from the write.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dotfiles.path) == ["claude-settings.json"])
    }

    @Test func aLoopOfSymlinksIsLeftAlone() throws {
        let folder = try Folder()
        defer { folder.remove() }
        try FileManager.default.createSymbolicLink(atPath: folder.file("a.json").path, withDestinationPath: "b.json")
        try FileManager.default.createSymbolicLink(atPath: folder.file("b.json").path, withDestinationPath: "a.json")
        #expect(throws: ConfigFileEditor.EditError.tooManySymlinks(path: folder.file("a.json").path)) {
            try editor(folder.file("a.json")).editJSONObject(install)
        }
    }

    // MARK: Files Mimamori must not replace

    @Test func anEmptyFileCountsAsNoSettings() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let settings = folder.file("settings.json")
        try Data().write(to: settings)
        let backup = try #require(try editor(settings).editJSONObject(keyOrder: ClaudeHooksConfig.keyOrder, install))
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        #expect(ClaudeHooksConfig.isInstalled(in: written))
        #expect(try Data(contentsOf: backup).isEmpty)
    }

    @Test(arguments: ["[1, 2, 3]", "\"opus\"", "null"])
    func aFileWithoutAnObjectIsLeftAlone(contents: String) throws {
        let folder = try Folder()
        defer { folder.remove() }
        let settings = folder.file("settings.json")
        try Data(contents.utf8).write(to: settings)
        #expect(throws: ConfigFileEditor.EditError.notAnObject(path: settings.path)) {
            try editor(settings).editJSONObject(install)
        }
        #expect(try text(settings) == contents)
        #expect(folder.names == ["settings.json"])
    }

    @Test func brokenJSONIsLeftAlone() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let settings = folder.file("settings.json")
        let contents = "{\n  \"model\": \"opus\",\n"
        try Data(contents.utf8).write(to: settings)
        let error = failure { try editor(settings).editJSONObject(install) }
        if case .notJSON = error {} else { Issue.record("Expected invalid JSON, got \(String(describing: error))") }
        #expect(try text(settings) == contents)
        #expect(folder.names == ["settings.json"])
    }

    @Test func aFileThatIsNotUTF8IsLeftAlone() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let settings = folder.file("settings.json")
        // "café" in Latin-1, which is not UTF-8.
        let contents = Data([0x7B, 0x22, 0x6E, 0x22, 0x3A, 0x22, 0x63, 0x61, 0x66, 0xE9, 0x22, 0x7D])
        try contents.write(to: settings)
        #expect(throws: ConfigFileEditor.EditError.notUTF8(path: settings.path)) {
            try editor(settings).editJSONObject(install)
        }
        #expect(throws: ConfigFileEditor.EditError.notUTF8(path: settings.path)) {
            try editor(settings).editText { $0 + "more" }
        }
        #expect(try Data(contentsOf: settings) == contents)
        #expect(folder.names == ["settings.json"])
    }

    @Test func anUnreadableConfigIsNotReplaced() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let config = folder.file("config.yaml")
        let contents = "model: local\n"
        try Data(contents.utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: config.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path) }
        // Root can read anything; there is nothing to test then.
        guard getuid() != 0 else { return }

        let error = failure {
            try editor(config).editText { HermesHooksConfig.install(into: $0, scriptPath: "~/.hermes/agent-hooks/mimamori.sh") ?? $0 }
        }
        if case .unreadable = error {} else { Issue.record("Expected unreadable, got \(String(describing: error))") }
        #expect(throws: (any Error).self) { try editor(config).readText() }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path)
        #expect(try text(config) == contents)
        #expect(folder.names == ["config.yaml"])
    }

    @Test func aFileChangedWhileEditingIsLeftAlone() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let settings = folder.file("settings.json")
        try Data("{}".utf8).write(to: settings)
        let editor = editor(settings)
        let read = try editor.read()
        try Data("{\"model\":\"opus\"}".utf8).write(to: settings)
        #expect(throws: ConfigFileEditor.EditError.changedWhileEditing(path: settings.path)) {
            try editor.write(Data("{\"hooks\":{}}".utf8), replacing: read)
        }
        #expect(try text(settings) == "{\"model\":\"opus\"}")
    }

    // MARK: Backups

    @Test func twoEditsInOneSecondKeepBothBackups() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let settings = folder.file("settings.json")
        try Data("{\"model\":\"opus\"}".utf8).write(to: settings)
        let editor = editor(settings)
        let first = try #require(try editor.editJSONObject(install))
        let second = try #require(try editor.editJSONObject(ClaudeHooksConfig.uninstall))
        #expect(first != second)
        #expect(try text(first) == "{\"model\":\"opus\"}")
        #expect(try text(second).contains("mimamori.sock"))
        #expect(HookBackups.list(of: settings) == [second, first])
        #expect(second.lastPathComponent.hasSuffix("Z-2.mimamori-backup"))
    }

    @Test func theOriginalSurvivesManyEdits() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let settings = folder.file("settings.json")
        let original = "{\n  \"model\": \"opus\"\n}\n"
        try Data(original.utf8).write(to: settings)
        let clock = Clock()
        let editor = editor(settings, clock: clock)
        for index in 0..<12 {
            clock.advance(1)
            try editor.editJSONObject { index.isMultiple(of: 2) ? install($0) : ClaudeHooksConfig.uninstall(from: $0) }
        }
        #expect(HookBackups.list(of: settings).count == HookBackups.kept)
        #expect(try text(HookBackups.originalURL(of: settings)) == original)
        #expect(folder.names.filter { $0.hasSuffix(".mimamori-original") } == ["settings.json.mimamori-original"])
    }

    @Test func anOlderVersionsOldestBackupStandsInForTheOriginal() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let settings = folder.file("settings.json")
        try Data("{\"now\":true}".utf8).write(to: settings)
        // Backups as Mimamori 1.1 named them, before it kept an original.
        for (day, contents) in [(3, "{\"oldest\":true}"), (4, "{\"middle\":true}"), (5, "{\"newest\":true}")] {
            try Data(contents.utf8).write(to: folder.file("settings.json.2026-11-0\(day)T04-02-00Z.mimamori-backup"))
        }
        try editor(settings).editJSONObject(install)
        #expect(try text(HookBackups.originalURL(of: settings)) == "{\"oldest\":true}")
        // Once there is an original, it stays as it is.
        try Data("{\"later\":true}".utf8).write(to: settings)
        try editor(settings).editJSONObject(install)
        #expect(try text(HookBackups.originalURL(of: settings)) == "{\"oldest\":true}")
    }

    @Test func noFileMeansNoBackup() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let settings = folder.file("claude/settings.json")
        #expect(try editor(settings).editJSONObject(install) == nil)
        #expect(try ClaudeHooksConfig.isInstalled(in: editor(settings).readJSONObject()))
        #expect(!FileManager.default.fileExists(atPath: HookBackups.originalURL(of: settings).path))
    }

    @Test func keepsTheFilesPermissions() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let settings = folder.file("settings.json")
        try Data("{}".utf8).write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        let backup = try #require(try editor(settings).editJSONObject(install))
        for file in [settings, backup, HookBackups.originalURL(of: settings)] {
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600, "\(file.lastPathComponent)")
        }
    }

    // MARK: Layout

    @Test func installingThenUninstallingGivesBackTheSameBytes() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let settings = folder.file("settings.json")
        let original = """
        {
          "permissions": {
            "allow": ["Bash(npm test)", "Read"],
            "deny": []
          },
          "model": "opus",
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  { "type": "command", "command": "say done" }
                ]
              }
            ]
          },
          "env": {
            "SAMPLE_FLAG": "1",
            "BUDGET": 1.50
          }
        }

        """
        try Data(original.utf8).write(to: settings)
        let editor = editor(settings)
        try editor.editJSONObject(keyOrder: ClaudeHooksConfig.keyOrder, install)
        let installed = try text(settings)
        // Keys stay in the user's order, and what Mimamori did not touch is copied as it was.
        let order = ["\"permissions\"", "\"model\"", "\"hooks\"", "\"env\""].compactMap { installed.range(of: $0)?.lowerBound }
        #expect(order.count == 4 && order == order.sorted())
        #expect(installed.contains("\"allow\": [\"Bash(npm test)\", \"Read\"],"))
        #expect(installed.contains("{ \"type\": \"command\", \"command\": \"say done\" }"))
        #expect(installed.contains("\"BUDGET\": 1.50"))
        // Mimamori's own entries are indented like the rest, in Claude Code's key order.
        #expect(installed.contains("\n    \"PreToolUse\": [\n      {\n        \"matcher\": \"*\",\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n"))

        try editor.editJSONObject(keyOrder: ClaudeHooksConfig.keyOrder, ClaudeHooksConfig.uninstall)
        #expect(try text(settings) == original)
    }

    @Test(arguments: [
        // As Mimamori 1.x wrote it, with JSONSerialization: " : " and no final newline.
        "{\n  \"model\" : \"opus\"\n}",
        // Four spaces and Windows line endings.
        "{\r\n    \"model\": \"opus\"\r\n}\r\n",
        // All on one line.
        "{\"model\":\"opus\", \"theme\":\"dark\"}",
    ])
    func newEntriesFollowTheFilesLayout(original: String) throws {
        let folder = try Folder()
        defer { folder.remove() }
        let settings = folder.file("settings.json")
        try Data(original.utf8).write(to: settings)
        let editor = editor(settings)
        try editor.editJSONObject(keyOrder: ClaudeHooksConfig.keyOrder, install)
        let installed = try text(settings)
        #expect(try ClaudeHooksConfig.isInstalled(in: editor.readJSONObject()))
        if original.contains(" : ") {
            #expect(installed.contains("\"hooks\" : {\n    \"SessionStart\" : [\n"))
            #expect(!installed.hasSuffix("\n"))
        } else if original.contains("\r\n") {
            #expect(installed.contains("\r\n    \"hooks\": {\r\n        \"SessionStart\": [\r\n"))
            #expect(!installed.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        } else {
            #expect(!installed.contains("\n"))
            #expect(installed.hasPrefix("{\"model\":\"opus\", \"theme\":\"dark\", \"hooks\":{\"SessionStart\":[{"))
        }
        try editor.editJSONObject(keyOrder: ClaudeHooksConfig.keyOrder, ClaudeHooksConfig.uninstall)
        #expect(try text(settings) == original)
    }

    @Test func aNewFileIsIndentedWithTwoSpaces() throws {
        let data = JSONLayout.data(for: ["hooks": ["Stop": [["hooks": [["type": "command", "command": "say done", "timeout": 5]]]]]],
                                   keepingLayoutOf: nil, keyOrder: ClaudeHooksConfig.keyOrder)
        let expected = """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "say done",
                    "timeout": 5
                  }
                ]
              }
            ]
          }
        }

        """
        #expect(String(decoding: data, as: UTF8.self) == expected)
    }

    // MARK: Text

    @Test func editsTextAndKeepsTheRestOfIt() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let config = folder.file("config.yaml")
        let original = "# My Hermes config\nmodel: local   # keep this comment\n"
        try Data(original.utf8).write(to: config)
        let script = "~/.hermes/agent-hooks/mimamori.sh"
        let backup = try #require(try editor(config).editText { HermesHooksConfig.install(into: $0, scriptPath: script) ?? $0 })
        #expect(try text(backup) == original)
        let installed = try text(config)
        #expect(installed.hasPrefix(original))
        #expect(HermesHooksConfig.isInstalled(in: installed))
        try editor(config).editText(HermesHooksConfig.uninstall)
        #expect(try text(config) == original)
    }
}
