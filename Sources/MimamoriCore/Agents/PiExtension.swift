import Foundation

/// The extension that connects pi and OMP (oh-my-pi, a fork of pi) to Mimamori. Their hooks are
/// TypeScript modules, not shell commands, so instead of a curl command this is a small extension
/// that posts the same events to the socket, by Mimamori's plain names, from inside the agent.
/// Both share the extension API; what only OMP has (subagents, approvals, session switches) is
/// simply never heard from pi.
public enum PiExtension {
    public enum Host: Sendable, CaseIterable {
        case pi, omp

        public var agent: AgentKind { self == .pi ? .pi : .omp }

        /// Where the agent looks for extensions of your own, with `~` for your home folder.
        public var file: String { self == .pi ? "~/.pi/agent/extensions/mimamori.ts" : "~/.omp/agent/extensions/mimamori.ts" }
    }

    /// The agents' own names for the events the extension listens to.
    public static let events = [
        "session_start", "session_switch", "before_agent_start", "agent_start", "tool_call",
        "tool_approval_requested", "tool_result", "agent_end", "session_shutdown",
    ]

    /// The events it posts: Mimamori's plain names, and Claude Code's SubagentStop for a subagent's end.
    public static let postedEvents = [
        "session_start", "turn_start", "tool_start", "tool_end", "tool_failed", "needs_permission", "turn_end",
        "turn_failed", "session_end", "SubagentStop",
    ]

    /// The extension's source for `host`, posting to `socketPath`: as a path under the home folder
    /// when it is in `home`, so the file moves between Macs and users.
    public static func source(for host: Host, socketPath: String, home: String = HookCommand.defaultHome) -> String {
        let socket: String
        if !home.isEmpty, socketPath.hasPrefix(home + "/") {
            socket = "join(homedir(), \(literal(String(socketPath.dropFirst(home.count + 1)))))"
        } else {
            socket = literal(socketPath)
        }
        return template.replacingOccurrences(of: "__SOCKET__", with: socket)
            .replacingOccurrences(of: "__NAME__", with: host.agent.displayName)
            .replacingOccurrences(of: "__AGENT__", with: host.agent.id)
    }

    /// A string as a JavaScript literal: JSON's quoting is valid there.
    static func literal(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static let template = #"""
    // Reports this __NAME__ session to Mimamori, which shows what your agents are doing in each worktree.
    // Set up from Mimamori's Settings › Agents › Other Agents. Delete this file to stop.
    import { request } from "node:http";
    import { homedir } from "node:os";
    import { join } from "node:path";

    const SOCKET = __SOCKET__;
    const ADDRESS = "/event?agent=__AGENT__";
    // Inputs Mimamori reads to say what a step does. File contents and edits stay here.
    const INPUTS = ["path", "file_path", "command", "pattern", "url", "description", "prompt", "query", "question", "title"];

    let queue: Promise<unknown> = Promise.resolve();
    let pending = 0;
    // By folder, the session working there: a subagent works in its parent's folder, and one
    // process can run several sessions (Orca's chats run in one OMP).
    const mainSessions = new Map<string, string>();
    // By session, the prompt that starts its next turn.
    const prompts = new Map<string, string>();

    // Posts over the socket with node:http, which both Node (pi) and Bun (OMP) have. Settles
    // whatever happens, within a second.
    function send(body: string): Promise<void> {
      return new Promise(resolve => {
        const req = request({
          socketPath: SOCKET,
          path: ADDRESS,
          method: "POST",
          headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) },
          timeout: 1000,
        }, res => {
          res.resume();
          res.on("end", () => resolve());
          res.on("error", () => resolve());
        });
        req.on("timeout", () => req.destroy());
        req.on("error", () => resolve());
        req.on("close", () => resolve());
        req.end(body);
      });
    }

    // One event at a time, so they arrive in order. Never awaited and never throws, so the agent
    // carries on the same whether Mimamori runs or not.
    function post(body: Record<string, unknown>): void {
      if (pending >= 50) return;
      pending++;
      queue = queue
        .then(() => send(JSON.stringify(body)))
        .catch(() => {})
        .finally(() => { pending--; });
    }

    // Waits for the events sent so far, a second at most. At the end of a turn or session the
    // agent may exit straight after (pi's print mode does), and it waits for a handler's promise.
    function flush(): Promise<void> {
      return Promise.race([queue.then(() => {}, () => {}), new Promise<void>(resolve => setTimeout(resolve, 1000))]);
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
      const main = typeof ctx?.cwd === "string" ? mainSessions.get(ctx.cwd) : undefined;
      return { event, session_id: main ?? sessionId(ctx), cwd: ctx?.cwd, agent_id: ctx.agent.id, agent_type: ctx.agent.name };
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

    // Notes the session working in the folder, for its subagents' steps.
    function remember(ctx: any): string | undefined {
      const id = sessionId(ctx);
      if (id && typeof ctx?.cwd === "string") mainSessions.set(ctx.cwd, id);
      return id;
    }

    export default function mimamori(pi: any) {
      pi.on("session_start", (_event: any, ctx: any) => {
        if (isSub(ctx)) return;
        remember(ctx);
        post(base("session_start", ctx));
      });

      // OMP's /new, /resume and /fork: the session before it closes, another opens. pi ends the
      // session and starts another instead.
      pi.on("session_switch", (_event: any, ctx: any) => {
        if (isSub(ctx)) return;
        const before = typeof ctx?.cwd === "string" ? mainSessions.get(ctx.cwd) : undefined;
        if (before && before !== sessionId(ctx)) post({ event: "session_end", session_id: before, cwd: ctx?.cwd });
        remember(ctx);
        post(base("session_start", ctx));
      });

      // OMP says "revive" when it wakes a parked subagent; pi gives no reason.
      pi.on("before_agent_start", (event: any, ctx: any) => {
        const id = sessionId(ctx);
        if (!isSub(ctx) && id && event?.reason !== "revive" && typeof event?.prompt === "string") prompts.set(id, event.prompt);
      });

      pi.on("agent_start", (_event: any, ctx: any) => {
        if (isSub(ctx)) return;
        const id = remember(ctx);
        post({ ...base("turn_start", ctx), prompt: id ? prompts.get(id) : undefined });
        if (id) prompts.delete(id);
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
        return flush();
      });

      pi.on("session_shutdown", (_event: any, ctx: any) => {
        if (isSub(ctx)) return;
        const id = sessionId(ctx);
        if (id) prompts.delete(id);
        if (typeof ctx?.cwd === "string" && mainSessions.get(ctx.cwd) === id) mainSessions.delete(ctx.cwd);
        post(base("session_end", ctx));
        return flush();
      });
    }

    """#
}
