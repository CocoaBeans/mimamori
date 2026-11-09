import Foundation

/// The extension that connects OMP (oh-my-pi) to Mimamori. OMP's hooks are TypeScript modules, not
/// shell commands, so instead of a curl command this is a small extension that posts the same
/// events to the socket, by Mimamori's plain names, from inside OMP.
public enum OMPExtension {
    /// Where OMP looks for extensions of your own, with `~` for your home folder.
    public static let file = "~/.omp/agent/extensions/mimamori.ts"

    /// OMP's own names for the events the extension listens to.
    public static let ompEvents = [
        "session_start", "session_switch", "before_agent_start", "agent_start", "tool_call",
        "tool_approval_requested", "tool_result", "agent_end", "session_shutdown",
    ]

    /// The events it posts: Mimamori's plain names, and Claude Code's SubagentStop for a subagent's end.
    public static let postedEvents = [
        "session_start", "turn_start", "tool_start", "tool_end", "tool_failed", "needs_permission", "turn_end",
        "turn_failed", "session_end", "SubagentStop",
    ]

    /// The extension's source, posting to `socketPath`: as a path under the home folder when it is
    /// in `home`, so the file moves between Macs and users.
    public static func source(socketPath: String, home: String = HookCommand.defaultHome) -> String {
        let socket: String
        if !home.isEmpty, socketPath.hasPrefix(home + "/") {
            socket = "join(homedir(), \(literal(String(socketPath.dropFirst(home.count + 1)))))"
        } else {
            socket = literal(socketPath)
        }
        return template.replacingOccurrences(of: "__SOCKET__", with: socket)
    }

    /// A string as a JavaScript literal: JSON's quoting is valid there.
    static func literal(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static let template = #"""
    // Reports this OMP session to Mimamori, which shows what your agents are doing in each worktree.
    // Set up from Mimamori's Settings › Agents › Other Agents. Delete this file to stop.
    import { homedir } from "node:os";
    import { join } from "node:path";

    const SOCKET = __SOCKET__;
    const ADDRESS = "http://mimamori/event?agent=omp";
    // Inputs Mimamori reads to say what a step does. File contents and edits stay here.
    const INPUTS = ["path", "file_path", "command", "pattern", "url", "description", "prompt", "query", "question", "title"];

    let queue: Promise<unknown> = Promise.resolve();
    let pending = 0;
    let mainSession: string | undefined;
    let prompt: string | undefined;

    // One event at a time, so they arrive in order. Never awaited and never throws, and gives up
    // after a second, so OMP carries on the same whether Mimamori runs or not.
    function post(body: Record<string, unknown>): void {
      if (pending >= 50) return;
      pending++;
      queue = queue
        .then(() => fetch(ADDRESS, {
          method: "POST",
          unix: SOCKET,
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(1000),
        } as RequestInit))
        .catch(() => {})
        .finally(() => { pending--; });
    }

    function isSub(ctx: any): boolean {
      return ctx?.agent?.kind === "sub";
    }

    function sessionId(ctx: any): string | undefined {
      try { return ctx?.sessionManager?.getSessionId?.() || undefined; } catch { return undefined; }
    }

    // A subagent's steps belong to the session that started it, marked with the subagent's id.
    function base(event: string, ctx: any): Record<string, unknown> {
      if (!isSub(ctx)) return { event, session_id: sessionId(ctx), cwd: ctx?.cwd };
      return { event, session_id: mainSession ?? sessionId(ctx), cwd: ctx?.cwd, agent_id: ctx.agent.id, agent_type: ctx.agent.name };
    }

    function inputs(input: unknown): Record<string, unknown> {
      const out: Record<string, unknown> = {};
      if (!input || typeof input !== "object") return out;
      for (const key of INPUTS) {
        const value = (input as Record<string, unknown>)[key];
        if (typeof value === "string") out[key] = value.slice(0, 8000);
      }
      return out;
    }

    function text(content: unknown): string | undefined {
      if (!Array.isArray(content)) return undefined;
      const block = content.find((item: any) => item?.type === "text" && typeof item.text === "string");
      return block ? String(block.text).slice(0, 2000) : undefined;
    }

    export default function mimamori(pi: any) {
      pi.on("session_start", (_event: any, ctx: any) => {
        if (isSub(ctx)) return;
        mainSession = sessionId(ctx);
        post(base("session_start", ctx));
      });

      // /new, /resume and /fork: the session before it closes, another opens.
      pi.on("session_switch", (_event: any, ctx: any) => {
        if (isSub(ctx)) return;
        if (mainSession) post({ event: "session_end", session_id: mainSession, cwd: ctx?.cwd });
        mainSession = sessionId(ctx);
        post(base("session_start", ctx));
      });

      pi.on("before_agent_start", (event: any, ctx: any) => {
        if (!isSub(ctx) && event?.reason === "prompt") prompt = event.prompt;
      });

      pi.on("agent_start", (_event: any, ctx: any) => {
        if (isSub(ctx)) return;
        mainSession = sessionId(ctx);
        post({ ...base("turn_start", ctx), prompt });
        prompt = undefined;
      });

      pi.on("tool_call", (event: any, ctx: any) => {
        post({ ...base("tool_start", ctx), tool_name: event.toolName, tool_use_id: event.toolCallId, tool_input: inputs(event.input) });
      });

      pi.on("tool_approval_requested", (event: any, ctx: any) => {
        post({ ...base("needs_permission", ctx), tool_name: event.toolName, tool_use_id: event.toolCallId, message: event.reason });
      });

      pi.on("tool_result", (event: any, ctx: any) => {
        post({
          ...base(event.isError ? "tool_failed" : "tool_end", ctx),
          tool_name: event.toolName,
          tool_use_id: event.toolCallId,
          tool_input: inputs(event.input),
          error: event.isError ? text(event.content) : undefined,
        });
      });

      pi.on("agent_end", (event: any, ctx: any) => {
        const last = Array.isArray(event?.messages) ? event.messages[event.messages.length - 1] : undefined;
        if (isSub(ctx)) {
          post({ ...base("SubagentStop", ctx), last_assistant_message: text(last?.content) });
          return;
        }
        // More work is on its way without you: the turn goes on.
        if (event?.willContinue && !event?.awaitingAsyncWork) return;
        if (last?.stopReason === "error") {
          post({ ...base("turn_failed", ctx), error: last.errorMessage ?? "The turn ended on an error" });
        } else {
          post({ ...base("turn_end", ctx), last_assistant_message: text(last?.content) });
        }
      });

      pi.on("session_shutdown", (_event: any, ctx: any) => {
        if (isSub(ctx)) return;
        post(base("session_end", ctx));
      });
    }

    """#
}
