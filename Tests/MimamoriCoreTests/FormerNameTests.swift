import Foundation
import Testing
@testable import MimamoriCore

/// The app was called Vigil until November 2026. Nothing carries over from that name any more:
/// what an app by that name leaves behind is that app's, not Mimamori's.
@Suite("The former name")
struct FormerNameTests {
    private func commands(in settings: [String: Any]) -> [String] {
        (settings["hooks"] as? [String: Any] ?? [:]).values.flatMap { value in
            (value as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
        }.compactMap { $0["command"] as? String }
    }

    @Test func leavesClaudeCodeHooksForTheOldSocketAlone() {
        let other = "curl -s --unix-socket \"$HOME/Library/Application Support/Vigil/vigil.sock\" --data-binary @- http://vigil/event || true"
        let settings: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": other]]]]]]
        let command = ClaudeHooksConfig.command(socketPath: "/tmp/mimamori.sock")

        #expect(!ClaudeHooksConfig.isOutdated(in: settings, command: command))
        let installed = ClaudeHooksConfig.install(into: settings, command: command)
        #expect(ClaudeHooksConfig.isInstalled(in: installed))
        #expect(commands(in: installed).contains(other))
        #expect(commands(in: ClaudeHooksConfig.uninstall(from: installed)) == [other])
    }

    @Test func leavesAHermesBlockUnderTheOldNameAlone() {
        let yaml = """
        model: local

        # --- Vigil hooks (added by Vigil; remove this block to uninstall) ---
        hooks:
          pre_tool_call:
            - command: "~/.hermes/agent-hooks/vigil.sh"
              timeout: 5
        # --- end Vigil hooks ---

        """
        #expect(HermesHooksConfig.uninstall(from: yaml) == yaml)
        #expect(!HermesHooksConfig.isInstalled(in: yaml))
        // Its hooks: key isn't Mimamori's, so Mimamori's entries have to be merged by hand.
        #expect(HermesHooksConfig.install(into: yaml, scriptPath: "~/.hermes/" + HermesHooksConfig.scriptRelativePath) == nil)
    }

    /// The old name appears nowhere in the code, so nothing starts claiming its files again.
    @Test func noOtherCodeUsesTheFormerName() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let places = ["Sources", "Resources", "Scripts", ".github", "Mimamori.xcodeproj", "Package.swift"]
        let allowed: [String] = []
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
