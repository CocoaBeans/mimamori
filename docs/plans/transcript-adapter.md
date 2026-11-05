# Plan: reading an agent's transcript while its hooks are silent

> **Proposed.** Nothing is built yet. Reading transcripts is **opt-in and off by default**,
> because they hold your prompts, the model's replies, command output and file contents. One part
> needs no transcript and is on for everyone: a turn already under way when Mimamori starts gets
> its real start time, from Hermes's record of which turns are running and from Claude Code's
> record of when a session went busy. The survey of what each agent records was made on
> 2026-11-04, on one Mac (see "What the agents record").

## Goal

See what an agent is doing even when its hooks say nothing:
- an agent whose hooks are not installed, or (for Hermes) not yet approved;
- a session started before the hooks were installed, which never runs them;
- a turn already under way when Mimamori starts, whose prompt and first steps went by unheard;
- a hook socket Mimamori can't use: another copy of Mimamori has it (see PR #18) or the path is
  too long.

Today such a session shows as **running, idle**, from its process alone. With transcripts on, it
shows its task, its steps and the files it changed, as if its hooks had reported.

The trigger is per session, not the socket's state: a session the scanner sees running, with no
hook heard from it, gets read from its transcript. That covers a blocked socket too. Hooks take
over the moment they report.

## What Mimamori already has

- **One currency for events.** `HookEvent` carries everything the rest of Mimamori uses: the
  event, agent, session, working directory, tool name, input summary, call id, file and time. A
  transcript reader only has to make `HookEvent`s; `AgentHub.handle(_:)` places them
  (`SessionPlacement`), folds them into a status (`AgentStatusMachine`), credits changes
  (`ChangeAttribution`) and writes the feed, as it does for hooks.
- **A status that hooks replace.** `AgentStatusMachine.adopt(_:)` takes Claude Code's status from
  `~/.claude/sessions/<pid>.json` while its hooks are silent, marked `fromSessionFile`, and the
  session's first hook event takes over. Transcripts follow the same rule.
- **Session lookups.** `ClaudeSessionFiles` ties a Claude Code process to its session id, and its
  record holds the session's `cwd`, which names the transcript. `HermesSessions` already opens
  Hermes's `state.db` read-only, with a busy timeout, for each session's directory.
- **Processes per worktree.** `AgentScanner` finds agents running in watched worktrees every few
  seconds. That is the list of sessions a reader may look at.
- **The hint on a process-only row.** `processNote` says "No hooks installed" or "No hook events
  from this session yet". It can point to the new setting.
- **Diagnostics.** Copy Diagnostics reports the socket, the hooks and the recent events, never
  their content. Transcript reading adds a line there.

## What you will see

- **Off (the default).** Nothing changes, except the process-only hint: "No hook events from this
  session. Mimamori can read its transcript instead." Its link opens Settings › Agents › Hooks at
  the switch. This is where you meet the feature: on a row it would help, at the moment it would
  help (see "Decided"). The line also has **Don't suggest this**: once you click it, the offer is
  gone for good and the line goes back to today's "No hook events from this session yet". Settings
  › Agents › Hooks can bring the offer back.
- **The setting.** Settings › Agents › Hooks gains a section, **When hooks are silent**, with one
  switch: **Read an agent's transcript while its hooks are silent**. Under it: which agents
  Mimamori can read, what it reads (the prompt, each tool's name and input, whether it failed, when
  the turn ended), and that nothing read is written to disk or sent anywhere.
- **On.** A silent session's row shows the task, steps and changed files, like a hooked one, with
  a small "from its transcript" note. For Hermes and OpenCode, the note also says a permission
  request may not show, since those agents don't record approvals they are waiting on.
- **Launch, switch on.** A session already mid-turn shows its whole turn so far, even when its
  hooks work: its prompt, its real start time and its earlier steps, with the edits it made before
  launch credited to it. Then it carries on from its hooks. Hooks alone can't give that turn back:
  Claude Code's prompt is gone until its next turn, and the steps and edits before launch are
  gone for good.
- **Launch, for everyone.** With the switch off, a turn already under way still starts at its
  real time rather than at Mimamori's launch, so "working for" and the turn's summary are right.
  A Hermes session mid-turn also shows as working from launch, before its first hook. Neither
  shows earlier steps.

## What the agents record

Surveyed read-only on 2026-11-04: key names, record types, sizes and timestamps, never content.

| Agent | Where, and how to find a session | Live? | Hard parts |
|---|---|---|---|
| Claude Code 2.1.317 | `~/.claude/projects/<cwd, every non-alphanumeric character as "-">/<sessionId>.jsonl`; the pid file gives `sessionId`, `cwd`, and `status` with `statusUpdatedAt` (when the session last went busy, idle or waiting) | Yes: each assistant message as it completes, each tool result as it returns | Files up to 661 MB; about 30 record types; the format changes weekly; `relocated` records when the session moves |
| Hermes 0.22.6 | `~/.hermes/state.db`, table `messages` by `session_id`; `session_turn_leases` for a running turn (`conversation_id` = session id, `acquired_at`, `expires_at`, holder `pid=<pid>:…`) | Yes: a tool call's row is written before the tool runs | Rows are rewritten (`active=0` and re-inserted with the same `message_uid`); no failure flag on results; compression ends a session and continues it in a child (`parent_session_id`); approvals waiting on you are not recorded; WAL |
| OpenCode 1.17.7 | `~/.local/share/opencode/opencode.db`; `session.directory`; the append-only `event` table | Yes: `message.part.updated.1` records pending, running, completed and error | `part` rows are updated in place, so read `event`; approvals waiting on you are not recorded |
| Aider 0.86.2 | `.aider.chat.history.md` at the repository's root | Prompts only | No tool calls, ids or turn ends: coarse at best |

Codex, Gemini CLI, Cursor's CLI agent, Goose and Amp were not installed, so their records are not
surveyed. Cursor IDE's old `agent-transcripts` have no call ids, results or times, and are of no
use here.

The mapping to `HookEvent`:

- **Claude Code.** `type:"user"` with string content, no `toolUseResult` and not `isMeta` →
  `UserPromptSubmit`. An assistant `tool_use` block (`id`, `name`, `input`) → `PreToolUse`. A user
  `tool_result` block (`tool_use_id`, `is_error`) → `PostToolUse` or `PostToolUseFailure`.
  `type:"system"`, `subtype:"turn_duration"` → `Stop`. A pending `AskUserQuestion` → a question.
  The top-level `timestamp` is the event's time. Waiting on a permission comes from the pid file,
  as today.
- **Hermes.** Rows with `active=1`, deduplicated by `message_uid`, by `timestamp`. `role='user'`
  → `UserPromptSubmit`. `role='assistant'` with `tool_calls` → one `PreToolUse` per call.
  `role='tool'` (`tool_call_id`, `tool_name`) → `PostToolUse`, or `PostToolUseFailure` when its
  JSON says `error`, a non-zero `exit_code` or `success: false`. `finish_reason='stop'` → `Stop`.
  A `clarify` call without a result → a question.
- **OpenCode.** `event` rows by rowid: a tool part's `state.status` going `running` →
  `PreToolUse`, `completed` → `PostToolUse`, `error` → `PostToolUseFailure`; a user message →
  `UserPromptSubmit`; an assistant message finishing with `stop` → `Stop`.

Finding a session's record through the files its process has open does not work in general:
Claude Code closes its transcript after each write, and Hermes and OpenCode keep every session in
one database. Each reader uses its agent's own key instead: the pid file, the lease's holder, the
session's directory.

## Design

### MimamoriCore

- `TranscriptReader`, a protocol: the agent it reads; `locate` (a session's record, from what the
  scan knows: pid, working directory, session id); and `read(since: TranscriptCursor) ->
  ([HookEvent], TranscriptCursor)`. The events it makes go through `HookEventParser`, so their
  summaries, files and categories match what the hooks give.
- `ClaudeTranscript`: finds the file from the pid file's `cwd` and `sessionId`, falling back to
  `projects/*/<sessionId>.jsonl` after a `relocated` record. It never reads a whole file. For the
  turn so far, it reads back from the end in 64 KB pieces, at most 8 MB, to the last prompt. It
  then follows appended lines from a byte offset, leaving a partial last line until its newline
  arrives. Record types it doesn't know are skipped.
- `HermesTranscript`: queries `messages` for one session, `active=1`, after the last timestamp
  seen, and deduplicates by `message_uid`. It follows a compressed session to its child. It reads
  `session_turn_leases` for whether a turn is running and since when.
- Turn starts from records, on for everyone, no content:
  - `HermesTurns`: the running turns from `session_turn_leases`, with each session's directory
    from `sessions`. `AgentStatusMachine.adopt` grows a case for it beside Claude Code's record:
    working since `acquired_at`, until the session's first hook event.
  - `AgentStatusMachine.backdateTurn(to:)`: when a turn starts from a tool call because its prompt
    was never heard (Mimamori started mid-turn), the hub moves its start back to Hermes's
    `acquired_at`, or to Claude Code's `statusUpdatedAt` while the pid file says `busy`. Only
    ever earlier, never past the previous turn's end.
- `OpenCodeTranscript`: reads `event` after the last rowid seen, for sessions whose `directory` is
  in a watched worktree.
- `TranscriptPolicy`, pure functions:
  - `shouldRead(...)`: whether to read a session, given the setting, whether a reader exists for
    its agent, whether its hooks are installed, and when a hook event from it last arrived;
  - `offersTranscripts(...)`: whether a process-only row offers the switch. It does only while the
    switch is off, a reader exists for the agent, and you haven't dismissed the offer.
- `AgentStatus.fromSessionFile` becomes `source: .hooks | .sessionRecord | .transcript`, so the UI
  can label where a status comes from.
- `AgentStatusMachine` ignores a `PreToolUse` whose call id it already holds, so a turn read back
  from the transcript and then reported by hooks keeps each step once.

### App

- `AppSettings.readTranscripts`, default `false`, and `transcriptOfferDismissed`, default
  `false`, both decoded with `decodeIfPresent`.
- `AgentHub`:
  - after each scan, asks `TranscriptPolicy` about each session the scan found, and starts or
    stops a reader for it;
  - a JSONL transcript is watched with a `DispatchSource` on the file (write and extend events); a
    database is polled every 2 s while its session runs;
  - feeds the events through `handle(_:)` marked as read from a transcript, and stops reading a
    session once a hook event arrives from it;
  - on launch, with the switch on, reads each busy session's turn so far once, even where hooks
    work;
  - with the switch off or on, backdates a turn joined midway from the records above.
- Views:
  - the switch and its text in Settings › Agents › Hooks, and, once you've dismissed the offer, a
    **Suggest it again** button beside it;
  - the process-only hint, with its link to the switch and its **Don't suggest this**;
  - the "from its transcript" note and, for Hermes and OpenCode, the line about permissions.

  The welcome window is unchanged.
- `Diagnostics`: whether the switch is on, and which sessions are read from transcripts (agent,
  worktree, time of the last record read, records skipped). No content.
- README: the privacy section says Mimamori reads agents' transcripts on your Mac only while the
  switch is on, only for sessions whose hooks are silent, and only the fields it shows. Its
  agents section and Troubleshooting hooks mention the switch. Help's Agents, Troubleshooting and
  Privacy topics say the same.

## Steps

1. **Turn starts at launch, for everyone** (about 250–350 lines with tests). `HermesTurns`, the
   adopt case and `backdateTurn(to:)`. No setting, and no transcript content. It starts with a
   short spike: whether Claude Code moves `statusUpdatedAt` on each tool call or only when the
   status changes, and so whether a busy session's value is its turn's start or a later moment
   (after a permission prompt, at worst).
2. **The frame and Claude Code** (about 900–1,300 lines with tests, the setting included).
   `TranscriptReader`, `TranscriptPolicy`, the status source, deduplication by call id,
   `ClaudeTranscript`, the `AgentHub` wiring, the switch, the hint, the labels, Diagnostics, README
   and Help. It starts with a short spike: a hook's `tool_use_id` equals the transcript's
   `tool_use` id, and a session's transcript is found from its pid file for each kind of start
   (terminal, IDE, desktop).
3. **Hermes's transcript** (about 400–600 lines). `HermesTranscript`, with rewrites and compression
   handled. Spike first: a hook's `tool_call_id` matches the `id` (or `call_id`) in `tool_calls`.
4. **OpenCode** (about 300–500 lines, optional). Mimamori sees OpenCode only as a process today,
   with no ready-made hook setup, so this would be its first full status, with no setup.
5. **Later.** Codex, Gemini CLI, Cursor's CLI agent, Goose and Amp, each surveyed on a Mac that has
   it first. Aider's prompts, if a coarse status is worth it.

## Tests

- Fixtures written for the tests, never taken from a real transcript.
- `ClaudeTranscript`: each mapped record type; unknown types skipped; reading back to the last
  prompt within the cap, including a prompt beyond it; following appended lines, with a partial
  last line held until its newline; a `compact_boundary` and a `relocated` record.
- `HermesTranscript`: rewritten rows (`active=0`, the same `message_uid` re-inserted); failure
  inferred from JSON and from text that isn't JSON; a compressed session continued in its child;
  a WAL database opened read-only.
- `HermesTurns`: a lease present, expired and gone; a session with no directory recorded.
- `backdateTurn(to:)`: moves only a turn that began without a prompt, only earlier, and never
  before the previous turn ended.
- `OpenCodeTranscript`: a tool part going pending, running, completed and error.
- `TranscriptPolicy`: the switch off means no reader for anyone; a session with hooks reporting
  isn't read; a session falls back to its transcript after its hooks go quiet. A process-only row
  offers the switch only while it is off, for an agent with a reader, and never once dismissed.
- `AgentStatusMachine`: a step read from the transcript and then reported by its hook shows once;
  hooks take over a status read from a transcript.
- By hand, in a scratch setup: a Claude Code session started before the hooks were installed, and
  Mimamori launched mid-turn, with the switch off and on.

## Risks

- **Formats change.** Claude Code ships weekly and Hermes migrates its schema. Each reader reads
  only the keys it needs, skips what it doesn't know, and gives up quietly: the row goes back to
  showing the process, and Diagnostics counts the records skipped. Never a wrong status.
- **Large files.** Transcripts reach hundreds of megabytes. Reading back is capped, and following
  reads only appended bytes.
- **Waits that don't show.** Hermes and OpenCode don't record an approval they wait on, so a
  session read from its transcript can look like it is working while it waits on you. The row
  says so; hooks remain the way to see and answer permission requests.
- **Steps twice.** If hook and transcript ids don't match for an agent, steps would show twice.
  The spikes in steps 2 and 3 check this before anything ships.
- **The wrong session.** A transcript has to be tied to a process the scan saw in a watched
  worktree, never guessed from recency alone.
- **Privacy.** Off by default. While on, Mimamori reads only sessions whose hooks are silent and
  only in watched worktrees, keeps what it read in memory as it does hook events, and writes none
  of it to disk.

## Decided

- **One switch for every agent.** Split it later only if people ask.
- **Reading back the turn at launch.** With the switch on, always, even when hooks work: it is the
  only way to get back the prompt, steps and edits of a turn Mimamori started in the middle of.
  The reader needs the same read-back anyway when it first picks up a silent session, so this is
  a policy, not more code. With the switch off, never.
- **A turn's real start from records, for everyone.** Hermes's lease and Claude Code's pid file
  say when a turn began without exposing any content, so that part needs no switch.
- **Not in the welcome window.** Its second step already explains hooks, connects Claude Code and
  Hermes with a line on what each changes, points to Other Agents and says how to remove them,
  in a 580-point-wide window. The switch needs as much again: what it reads, what it never does,
  and why you might want it. It is also a fallback for when hooks are missing, and the welcome
  window is where you install them. The moment the switch helps is when a row shows only a
  process, so the offer goes there, with its link to Settings, where there is room to explain.
- **A setup wizard, only later.** A paged setup would give each decision room, and could branch.
  When you skip connecting an agent, or one you use has no ready-made hooks (Codex, OpenCode), a
  page could offer to read its transcript instead, which is exactly when the switch makes sense.
  Today the welcome window holds two decisions, which fit on one page, and a wizard would cost
  everyone extra clicks for a step most people won't need. Revisit once transcripts ship (step 2)
  if setup gains another real decision, such as notifications or answering permissions in
  Mimamori. Its shape then: watch a repository, connect agents, and offer transcripts only when
  something stayed unconnected.
- **The offer on silent rows, dismissed once, stays out of the way.** Someone who keeps the switch
  off on purpose shouldn't see the suggestion every time an agent runs without hooks. One click
  dismisses it for good, and Settings brings it back.
