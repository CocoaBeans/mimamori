import Foundation

/// A prompt to paste into an agent, which then sets up its own hooks to report to Mimamori. For an
/// agent with a known setup it carries that setup and says where it goes; for any other agent it
/// describes what Mimamori takes, so the agent can find its own hooks and connect them.
public enum AgentSetupPrompt {
    public static func text(for recipe: AgentHookRecipe, socketPath: String, agent: String? = nil,
                            home: String = HookCommand.defaultHome) -> String {
        let name = agent ?? recipe.agentName
        let address = "http://mimamori" + AgentHookRecipe.address(agent: name)
        let who = recipe == .other ? "yourself (the coding agent reading this)" : recipe.title
        let health = "curl -s -m 2 --unix-socket \(HookCommand.quotedSocket(socketPath, home: home)) http://mimamori/health"

        var parts: [String] = []
        parts.append("""
        Please connect \(who) to Mimamori on this Mac, so Mimamori can show what it is doing.

        Mimamori is a macOS app that watches coding agents at work in git worktrees. Agents report to it by \
        posting each event's JSON, as an HTTP POST to \(address), over its Unix socket at \
        \(socketPath).
        """)
        parts.append(steps(for: recipe, setup: recipe.setup(socketPath: socketPath, agent: name, home: home), address: address))
        parts.append("""
        Then check that Mimamori is listening: `\(health)` prints "ok". If it prints nothing, Mimamori isn't \
        running; the setup is still safe to keep.

        Rules:
        - Keep everything already in the settings you change. Back a file up before editing it, and add to it rather \
        than replacing it.
        - Use the user-level settings, not one project's, so every session reports.
        - Reporting must never hold up or block the agent: give up after a second or two, ignore errors, and always \
        succeed.
        - Send what a step does (a file path, a command), never file contents or secrets.
        - Don't change any other agent's settings, or Mimamori's own files.

        When you're done, tell me what you changed and anything you couldn't connect. Sessions started after this \
        show up in Mimamori under Settings › Agents › Other Agents › Heard from.
        """)
        return parts.joined(separator: "\n\n") + "\n"
    }

    private static func steps(for recipe: AgentHookRecipe, setup: String, address: String) -> String {
        switch recipe {
        case .codex, .gemini, .cursor:
            let file = recipe.file ?? "the agent's settings"
            return """
            Add these hooks to \(file). If it exists, add each entry under its "hooks" key, beside any hooks already \
            there for the same event; if it doesn't, create it with this content.

            ```json
            \(setup.trimmingCharacters(in: .newlines))
            ```

            Mimamori's note on this, to pass on to me: \(recipe.note)
            """
        case .pi, .omp:
            return """
            Save this extension as \(recipe.file ?? "mimamori.ts in the agent's extensions folder"). If a file by that \
            name is there already, replace it only when its first line is the same as this one's; otherwise stop and \
            ask me. \(recipe.title) loads extensions when a session starts.

            ```ts
            \(setup.trimmingCharacters(in: .newlines))
            ```
            """
        case .other:
            return otherSteps(command: setup, address: address)
        }
    }

    private static func otherSteps(command: String, address: String) -> String {
        let events = AgentEventTranslator.plainEvents.map { "- `\($0.name)`: \($0.meaning)" }.joined(separator: "\n")
        return """
        Mimamori takes these events, by these names:

        \(events)

        Each is a JSON object such as \
        `{"event": "tool_start", "session_id": "…", "cwd": "/path/to/worktree", "tool_name": "Edit", "tool_use_id": "…", "tool_input": {"file_path": "src/a.py"}}`:
        - `event` names the event, and `session_id` stays the same for every event of one session.
        - `cwd` is the folder the session works in.
        - Tool events carry `tool_name`, `tool_use_id`, and `tool_input` with `file_path` for a file the tool \
        reads or changes, or `command` for a shell command.
        - `turn_start` carries the user's `prompt`; `question` and `needs_permission` a `message`; `tool_failed` and \
        `turn_failed` an `error`.

        1. Find how you run things at moments like these: hooks, plugins or extensions, in your own documentation \
        or settings.
        2. If your hooks run a shell command with the event's JSON on standard input, have each run:

           ```sh
           \(command)
           ```

           Mimamori understands Claude Code's, Codex's, Gemini CLI's and Cursor's event names and fields as they are. With other names, add `&event=<one of the names above>` to the address in each hook. With other fields, translate them in a small script that the hook runs instead.
        3. If your hooks are code, post the JSON from there: an HTTP POST to \(address) over the Unix socket, with \
        `Content-Type: application/json`, a one-second timeout, without waiting for it.
        4. Connect as many of the events as you can. `turn_start` and `turn_end` matter most; tool events add each \
        step and the files it changed.
        """
    }
}
