# Plan: seeing an agent's subagents

> **Proposed.** Claude Code tells Mimamori enough to follow each subagent: when it starts and
> finishes, what kind it is, what it was asked, and every step it takes. Step 1 confirms that with
> a real run before anything is built.

## The problem

Claude Code hands work to subagents (an Explore agent searching the code, a reviewer, a fetcher),
often several at once and often in the background. Mimamori sees their steps but not them:

- **The card says Ready too soon.** When the main agent stops, its card goes to Ready, though
  background subagents may still be working. Their next step flips it back to working, so it
  flickers, and "finished a turn" is announced before the work is done.
- **Nothing says who's doing what.** A subagent's steps land in the turn as if the main agent
  took them, so the timeline and the list of actions mix them up.
- **A subagent in a worktree of its own** (`.claude/worktrees/agent-…`) shows up as a separate
  agent in a separate worktree, with nothing tying it to the agent that started it.

## Goal

- An agent's card stays **active while any of its subagents runs**: in Working, saying so, and
  "finished a turn" only once the last of them is done.
- The card shows **its subagents**: what kind, what they were asked, how long they've run, how
  many steps they've taken, and the latest one. On the Mac (the Agents window, the banner above
  the diff) and on the iPhone.
- In the iPhone's **list of actions**, each step says which subagent took it.

## What Claude Code tells us

From Claude Code's hooks reference, and on this Mac's Claude Code 2.1.318:

- **`agent_id` and `agent_type`** come with every hook that fires inside a subagent, including
  PreToolUse and PostToolUse: `agent_type` is its kind, such as `Explore` or `security-reviewer`.
  Mimamori reads `agent_id` today, to route permission requests, but not `agent_type`.
- **`SubagentStart`** (`agent_id`, `agent_type`) when a subagent is spawned or resumed.
  Mimamori doesn't install this hook yet.
- **`SubagentStop`** (`agent_id`, `agent_type`, `agent_transcript_path`, `last_assistant_message`)
  when it finishes. Mimamori installs it, but only notes it in the feed.
- **The `Agent` tool** launches one: its input has `description`, `prompt` and `subagent_type`.
  A foreground launch's PostToolUse comes when the subagent finishes; a background one's comes at
  once, with `status: "async_launched"` and the subagent's `agentId`.
- **`Stop` carries `background_tasks`**: what's still in flight when the main agent stops,
  subagents among them (`type: "subagent"`, with their `agent_type`). That's exactly "the turn
  ended, but work goes on".
- Claude Code also keeps its own record of each subagent beside the session's transcript
  (`<session>/subagents/agent-<id>.meta.json`): its type, description, the tool call that started
  it, foreground or background, and whether it finished. Mimamori already reads Claude Code's
  session records, so this is a fallback for subagents whose hooks were missed.

Not yet seen with our own eyes: a `SubagentStop` for a foreground built-in subagent (a run on
2026-11-05 left none in the feed), and the exact entries in `background_tasks`. Step 1 settles both.

## What Mimamori does now

- `HookEvent` parses `agent_id`; `PendingPermission.agentID` uses it, so a subagent waiting on you
  doesn't settle the main agent's request.
- The status machine sets **Ready on Stop** whatever is still running, and treats a later tool
  call as the agent working again.
- `SubagentStop` adds "Claude Code subagent finished" to the feed, and nothing else.
- `AgentToolCategory` already calls `Agent`, `Task` and `delegate_task` a subagent step.

## Design

**Subagents in the session's status.** `AgentStatus` gains `subagents`, by `agent_id`:

- `type` (`agent_type`), `description` (from the `Agent` call that launched it), `startedAt`,
  `lastEventAt`, `steps` and the latest step, `background`, `finishedAt`, and its last message
  (`last_assistant_message`), shortened.
- **Started** by `SubagentStart`, or by the first event carrying a new `agent_id`. The `Agent`
  call that launched it gives the description: matched by the `agentId` in a background launch's
  response, else by order (the oldest unmatched launch of that type).
- **Steps**: a tool event with `agent_id` is the subagent's, and `AgentToolCall` gains `agentID`,
  so the timeline, the list of actions and the card can tell them apart.
- **Finished** by `SubagentStop`. If that never comes: when `Stop`'s `background_tasks` no longer
  lists it, when the session ends or its process goes, or after 10 minutes without an event.

**The card stays active.** On `Stop` with subagents still running (by `background_tasks`, or by
the ones we know started and haven't stopped), the activity becomes *working on subagents*:

- the card stays in Working, reading "waiting on 2 subagents";
- the turn's timer and timeline keep running;
- "finished a turn" (feed and notifications) waits for the last `SubagentStop`.

A subagent's step while the main agent is Ready no longer flips the whole card; it's the
subagent's.

**Subagents in their own worktree.** A worktree under `.claude/worktrees/agent-<id>` whose `<id>`
matches a running subagent is shown as that subagent, inside its parent's card, not as an agent of
its own. Its files stay reviewable in that worktree as now.

**Showing them.**

- **Mac:** a *Subagents* section on the agent's card in the Agents window and in the banner above
  the diff: one line each, the type's name and the description, how long, step count, and the
  latest step; a finished one fades out after a minute. Compact cards say "+2 subagents".
- **iPhone:** the snapshot's card gains the same list (optional, so older phones keep decoding);
  the card and its list of actions show it; each step in the list of actions names its subagent.
- **Privacy:** with "Show tasks and steps in widgets" off, descriptions and steps stay on the Mac,
  as tasks and steps do; the type and counts remain.

**Hooks.** Add `SubagentStart` to the events Mimamori installs for Claude Code. A Mimamori that
finds its hooks installed without it already offers to update them.

## Steps

1. **Look at real events.** A debug flag that writes every hook event's raw JSON to a file, in a
   scratch copy. Run a foreground subagent, a background one, two at once, and one in a worktree of
   its own, and note which events and fields arrive, and what `background_tasks` holds at `Stop`.
   Adjust the design to what's there.
2. **The model.** `subagents` in the status, `agentID` on tool calls, the matching of launches,
   finishing and expiry, and *working on subagents* after `Stop`, with status-machine tests for
   each case from step 1.
3. **The Mac.** The *Subagents* section on cards and the banner; the deferred "finished a turn";
   `SubagentStart` in the installed hooks.
4. **The iPhone.** The snapshot's subagents, the card's list, and steps labelled by subagent.
5. **Worktree-isolated subagents** shown inside their parent.

## To decide

- **"Finished a turn" with subagents.** Wait for the last subagent (proposed), or announce the
  main agent's stop and then "all subagents finished" separately?
- **A subagent's last message.** Worth showing (a line under it once it finishes), or noise?
- **Other agents.** Codex, Gemini and Hermes have subagents of their own kinds, but no
  `agent_id` in their hooks today. Claude Code first; others as their hooks allow.

## References

- [Claude Code hooks reference](https://code.claude.com/docs/en/hooks): common input fields
  (`agent_id`, `agent_type`), `SubagentStart`, `SubagentStop`, `Stop`'s `background_tasks`, and the
  `Agent` tool's input and response.
