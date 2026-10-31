# Plan: noticing two agents in one worktree

## The problem

Start two agents in the same folder and they trip over each other: one edits a file, the other
reads it back changed and gets confused, or undoes the edit. Vigil sees both agents, but today it
keeps **one status per worktree**. When two sessions report from the same worktree, the banner
flips between them on every event. Since #25 the status also starts from scratch on each flip.
Nothing warns you that two agents share the folder.

Git already stops two worktrees from checking out the same branch, so "same branch" in practice
means "same worktree". Two separate clones on the same branch are outside what Vigil watches and
out of scope.

## What you will see

Two levels:

1. **Heads-up: "2 agents are working here".**
   - The sidebar row shows a two-person badge.
   - The agent banner shows the most urgent agent as it does now (needs you, then working, then
     ready). Below it, an "Also here" line for each other agent: its name, its status, and a
     **Go to agent** button, so you can stop one.
   - One activity-feed entry when it starts.
   - It doesn't count as needing you: a reviewer reading alongside a writer is fine.
2. **Collision: "Claude Code and Codex both edited `App.swift`".**
   - A warning strip at the top of the banner names the files both have edited. It explains the
     risk and how to fix it: "Agents in one folder can undo each other's work. Stop one, or give
     it its own worktree."
   - It counts as needing you, like a permission prompt, so the sidebar and menu-bar counts and
     the attention button include it.
   - A warning entry in the feed for each newly shared file.
   - A notification, once per pair of agents, while the collision lasts. A Settings › Agents ›
     Notifications toggle turns it off; it's on by default.
   - A **Dismiss** button quiets it until the agents share another file.

The Agents window and menu bar list show the same "2 agents" badge, and a colliding row sorts
with the rows that need you.

## What counts as an agent here

A **session** is one agent conversation, identified by the `session_id` its hooks send.
- Subagents share their parent's session, so they never count as extra agents.
- Events without a session id are grouped by agent: one unnamed agent per kind per worktree.

A session is **live** in a worktree when all of these hold:
- Its latest event placed it there (sessions still move between worktrees, as they do today).
- It hasn't ended: no `SessionEnd`, and its status isn't `idle`.
- It sent an event in the last 10 minutes, **or** its agent process is still running.
- For a status taken from Claude Code's session file, its process must be alive.

**Processes without hooks** count too, carefully. Each live session claims one agent process of
its kind in the worktree; Claude Code sessions claim the exact process through
`~/.claude/sessions/<pid>.json`. A process left unclaimed counts as another agent only if all of
these hold:
- No other agent process in the worktree started it. Helpers, and an agent running
  `claude -p` as a tool, are part of the parent's work.
- It has been seen in two scans in a row, so a short-lived process doesn't flash an alert.
- Its banner line says "seen from its process" because Vigil can't see what it's doing.

So **several agents** means at least two of: live sessions, plus unclaimed agent processes.

A **collision** means two live sessions each made an edit (a mutating tool call that names a
file) to the same absolute path within the last 30 minutes, with at least one of the two edits in
the last 10 minutes. Shell commands that name no file can't be matched and don't count.

## Design

### VigilCore

**New: `WorktreeAgents` (pure, in `Sources/VigilCore/Agents/WorktreeAgents.swift`)**
- Input: the statuses of the sessions placed in one worktree, that worktree's agent processes, and
  a parent lookup for the "started by another agent" check, injected so tests can fake it.
- Output:
  - `live`: live sessions, most urgent first.
  - `unclaimed`: agent processes no live session claims, after the filters above.
  - `isShared`: true when more than one agent is present.
  - `collisions`: each shared path, the sessions that edited it, and when.
- Session keys and the time windows (10 minutes live, 30 and 10 minutes for edits) are constants
  on the type.

**`AgentStatusMachine`**
- Unchanged as a per-session machine.
- The "another session took over" reset added in #25 stays only for events without a session id
  (several agents sharing one key). Keyed sessions never share a machine any more.
- No new storage: the edits the overlap check needs are already in `recentToolCalls` (path,
  mutating, start time; at most 200 calls).

### `AgentHub`

| Today | After |
|---|---|
| `machines: [worktree: AgentStatusMachine]` | `machines: [worktree: [sessionKey: AgentStatusMachine]]` |
| `statuses: [worktree: AgentStatus]` | `statuses: [worktree: [AgentStatus]]`, most urgent first |
| `presence(for:)` gives one agent | the most urgent agent, plus `others: [AgentPresence]` and `collision: AgentCollision?` |

Changes, in the order `handle(_:)` meets them:
- **Placement and moving.** Unchanged. The "session moved on" sweep removes just that session's
  machine from its old worktree, not the whole worktree's.
- **Held events.** Unchanged: they replay into the session's own machine.
- **Claude Code session files.** `adoptSessionRecords()` gives each record its own machine (key =
  session id) instead of choosing one per worktree, so the ranking code goes away. Hook statuses
  still win over the file.
- **Expiry.** Per session, with the same rules as today. An ended session leaves after a
  two-minute grace period, so "session ended" still shows briefly but doesn't count as a second
  agent.
- **Approvals.** `commandsAwaitingPermission` and `noteApproved` work per session.
- **Attribution.** `attribution(for:path:at:)` looks at every session in the worktree:
  1. A call that names the changed file wins.
  2. Failing that, a mutating call running at the time.
  3. If two sessions both have one running, the change is credited to "Claude Code or Codex"
     rather than guessing.
- **Results.** Each publish computes `WorktreeAgents` per worktree and caches the result (no new
  timer). It still uses the existing throttle. A **new collision** (a new pair of sessions, or a
  newly shared file) is urgent: it publishes at once and calls `onNotes` with new note kinds
  `sharedWorktree` and `collision`.
- `worktreesNeedingAttention` adds worktrees with an undismissed collision.
- `activeWorktreeCount` is unchanged.
- **Dismissing** stores the worktree, the pair of session keys and the set of shared files. It
  re-alerts when a file not in that set becomes shared, and is forgotten when the pair stops
  being live.

### App

- **`AgentPresence`** gains `others` and `collision`. `needsAttention` is true for a collision, so
  sorting and counts pick it up. The badge text reads "2 agents" or "3 agents".
- **`AgentPresenceBadge`** (sidebar, menu bar): uses `person.2.fill` when shared, tinted orange on
  a collision. Its tooltip lists each agent and its status.
- **`AgentStatusBanner`**:
  - The collision strip goes on top, with Dismiss.
  - The primary agent's block is unchanged.
  - An "Also here" line per other agent, each with Go to agent. `AgentApps.canGo(to:)` takes that
    agent's process ids.
- **Agents window**: one row per worktree as now, with the badge and collision strip. The files
  chips merge both sessions' edits, and shared files are tinted.
- **`AppModel.record(agentNotes:)`**:
  - `sharedWorktree` becomes an `agentSession` entry.
  - `collision` becomes an `agentAttention` entry with severity `.warning`, naming the agents and
    files.
  - A notification goes out under the key `"collision:" + worktree` when
    `settings.notifyOnAgentCollision` is on.
- **Settings › Agents › Notifications**: a new toggle, "When two agents edit the same files",
  stored as `notifyOnAgentCollision`. It defaults to on, with a tooltip.
- **Session summary**: already lists every agent named in the feed. No change.
- **`DebugHooks` dump**: an `agents …` line per worktree listing its live sessions, unclaimed
  processes and collisions, for headless checks.
- **README**: a short "Several agents in one worktree" paragraph under Agents and hooks.

## Build order

Each step builds and passes tests on its own; they land as one PR.

1. **`WorktreeAgents` and its tests.** Pure logic, no UI.
2. **Per-session machines in `AgentHub`.** The UI keeps showing the most urgent agent, so nothing
   looks different yet. Port the hub's adoption, expiry, approval and attribution paths.
3. **Presence and views.** `others` and `collision`, the badge, the banner's "Also here" line and
   collision strip, the Agents window and the menu bar.
4. **Alerts.** Note kinds, feed entries, attention counts, the notification and its setting,
   Dismiss.
5. **Docs, debug dump, headless check, PR.**

## Tests

**`WorktreeAgents`**
- One session: not shared.
- Two sessions: shared.
- A subagent of one session doesn't count as another agent.
- An ended session and a stale session (11 minutes silent, no process) don't count.
- A reader beside a writer: shared, no collision.
- Two writers on different files: shared, no collision.
- Two writers on the same file: a collision.
- Edits 40 minutes apart: no collision.
- An unclaimed process counts only after two scans and only if no other agent process started it.
- Claude Code processes are claimed by session id.

**`AgentStatusMachine`**
- Two sessions in one worktree each keep their own task and steps; the #25 reset tests move to the
  sessionless case.

**Hub, through its pure helpers**
- Attribution credits the session whose call names the file, and says "A or B" when it can't tell.
- Dismissing silences the alert until a new file is shared.

**Headless app run** (scratch support folder, as in the earlier checks)
1. Two Claude-shaped sessions edit different files in `harbor`.
2. Then Codex and Cursor edit the same file in `harbor-plan`.
3. Check the dump for live sessions and collisions, and screenshot the sidebar, banner and Agents
   window.
4. Confirm the attention count and one notification key per collision.

**By hand**
- Two real Claude Code sessions in one worktree.
- One Claude Code and one Hermes session.

## Risks

- **False alarms from processes.** Mitigated by the "started by another agent" filter and the
  two-scan rule. A process-only agent is worded as "seen from its process", so a mistaken one
  reads as a soft hint.
- **Sessionless agents.** Two sessions of one agent that sends no session id can't be told apart.
  The README says so, and the plain hook format already has a `session_id` field.
- **A bigger hub change.** Every path that reads `machines` changes. Doing step 2 with no visible
  change keeps that reviewable, and the existing hub-level tests and headless scripts cover it.

## Defaults to confirm

These are easy to change later:
- **Notifications:** only for collisions, not for two agents merely sharing a folder.
- **Time windows:** 10 minutes for a live session; 30 minutes for edits, with at least one edit in
  the last 10.
- **Dismiss** lasts until a newly shared file, not for the rest of the session.
