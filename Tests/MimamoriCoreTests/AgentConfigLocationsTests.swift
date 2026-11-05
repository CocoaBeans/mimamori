import Foundation
import Testing
@testable import MimamoriCore

@Suite("Where agents keep their config")
struct AgentConfigLocationsTests {
    private let home = URL(fileURLWithPath: "/Users/sample", isDirectory: true)

    @Test func defaultsToTheHomeFolder() {
        for environment in [[:], ["CLAUDE_CONFIG_DIR": "", "HERMES_HOME": ""]] {
            let locations = AgentConfigLocations(environment: environment, home: home)
            #expect(locations.claudeSettings.path == "/Users/sample/.claude/settings.json")
            #expect(locations.claudeSessions.path == "/Users/sample/.claude/sessions")
            #expect(!locations.claudeConfigFromEnvironment)
            #expect(locations.hermesConfig.path == "/Users/sample/.hermes/config.yaml")
            #expect(locations.hermesScript.path == "/Users/sample/.hermes/agent-hooks/mimamori.sh")
            #expect(locations.hermesAllowlist.path == "/Users/sample/.hermes/shell-hooks-allowlist.json")
            #expect(locations.hermesStateDatabase.path == "/Users/sample/.hermes/state.db")
            #expect(!locations.hermesHomeFromEnvironment)
            // Unchanged from 1.x, so Hermes's approvals of it still count.
            #expect(locations.hermesScriptPathForConfig == "~/.hermes/agent-hooks/mimamori.sh")
        }
    }

    @Test func bothVariablesExpandATilde() {
        let locations = AgentConfigLocations(environment: ["CLAUDE_CONFIG_DIR": "~/work/claude", "HERMES_HOME": "~/work/hermes/"], home: home)
        #expect(locations.claudeSettings.path == "/Users/sample/work/claude/settings.json")
        #expect(locations.claudeConfigFromEnvironment)
        #expect(locations.hermesConfig.path == "/Users/sample/work/hermes/config.yaml")
        #expect(locations.hermesHomeFromEnvironment)
        #expect(AgentConfigLocations(environment: ["CLAUDE_CONFIG_DIR": "~"], home: home).claudeSettings.path == "/Users/sample/settings.json")
    }

    @Test func theHermesScriptPathFollowsHermesHome() {
        let inside = AgentConfigLocations(environment: ["HERMES_HOME": "/Users/sample/scratch/hermes"], home: home)
        #expect(inside.hermesScriptPathForConfig == "~/scratch/hermes/agent-hooks/mimamori.sh")
        let outside = AgentConfigLocations(environment: ["HERMES_HOME": "/private/tmp/hermes-test"], home: home)
        #expect(outside.hermesScriptPathForConfig == "/private/tmp/hermes-test/agent-hooks/mimamori.sh")
        let spaced = AgentConfigLocations(environment: ["HERMES_HOME": "~/Hermes Files"], home: home)
        #expect(spaced.hermesScriptPathForConfig == "~/'Hermes Files/agent-hooks/mimamori.sh'")
        // The YAML stays valid, and Hermes installs the script where the config points.
        #expect(HermesHooksConfig.yamlEntries(scriptPath: spaced.hermesScriptPathForConfig)
            .contains("    - command: \"~/'Hermes Files/agent-hooks/mimamori.sh'\"\n"))
    }

    /// Hermes expands a leading `~` and splits the command into words as the shell does; the
    /// shell here stands in for it.
    @Test func aQuotedScriptPathIsOneWord() async throws {
        let spaced = AgentConfigLocations(environment: ["HERMES_HOME": "~/Hermes Files"], home: home)
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' " + spaced.hermesScriptPathForConfig],
            environment: ["HOME": home.path])
        #expect(result.stdoutText == spaced.hermesScript.path + "\n")
    }

    @Test func claudeSessionFilesUseTheSameFolder() {
        #expect(ClaudeSessionFiles.configDirectory == AgentConfigLocations.current.claudeConfigDirectory)
        #expect(ClaudeSessionFiles.directory == AgentConfigLocations.current.claudeSessions)
    }
}
