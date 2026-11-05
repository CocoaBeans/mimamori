# Plan: a history of agent sessions

> **Proposed.** Nothing is built yet. The survey under "What the agents keep" was made on
> 2026-11-05 on one Mac, with Claude Code 2.1.317 and Hermes 0.22.7. Orca's session history (MIT,
> `src/main/ai-vault` in `stablyai/orca`) was read the same day. Its first step is a spike, and
> two choices under "To decide first" come before any code.

## Goal

Answer **who worked in this worktree, and on what?** after the agents have gone:
- list the sessions that ran in a worktree, the live ones and the ended ones, newest first;
- for each one, show what it was asked, when it ran, what it changed, its notes and its pull
  request;
- pick one up again (copy the command that resumes it), or hand it to another agent (copy it as a
  prompt).

Today an ended session leaves the Agents window soon after it ends. Its turns and file changes stay
in the activity feed, but nothing says which session they belonged to.

Orca has a session browser across every project, built from the agents' transcripts. Mimamori's
history stays inside the worktrees it watches. It joins each session to what Mimamori already knows
about that worktree: the files the session changed, their flags, your review notes, its pull
request. From a changed file you can get to the session that wrote it.

## What Mimamori already has

- **The activity feed, saved to disk.** `ActivityLog` writes `activity.jsonl` and keeps it for the
  days you choose. Each `ActivityEntry` carries the worktree, its kind (session started or ended,
  turn started or finished, tool call, file change), the agent's name, and for a turn's start the
  first line of its prompt (`HookEvent.message`). What it lacks is the session: two sessions of
  one agent in one worktree can't be told apart.
- **Sessions keyed by id.** `AgentHub` keys each agent by its `session_id`, and `TurnTimeline`
  keeps a turn's tool calls. `ChangeAttribution` ties each changed file to the agent and the tool
  call that last edited it.
- **Session records it already reads.** `ClaudeSessionFiles` ties a Claude Code process to its
  session id and `cwd`. `HermesSessions` opens Hermes's `state.db` read-only, with a busy timeout.
  `AgentConfigLocations` honours `CLAUDE_CONFIG_DIR` and `HERMES_HOME`.
- **A plan for reading transcripts.** [transcript-adapter.md](transcript-adapter.md) reads a
  session's transcript while its hooks are silent. Its decisions carry over: reading transcripts
  is opt-in and off by default, readers read only the keys they need and skip what they don't know,
  and `ClaudeTranscript` reads back from the end of a file in 64 KB pieces, never the whole file.
- **Prompts it can already make.** `ReviewNotePrompt` formats review notes for an agent, and the
  session summary (⇧⌘E) writes up a worktree's session as Markdown.
- **Go to agent.** `AgentApps` brings the app a live agent runs in to the front.

## What Orca does

Orca's "AI Vault" lists sessions from about a dozen agents. Worth copying, and worth avoiding:
- **It reads every transcript in full**, line by line, in a separate scanner process. It keeps
  each file's parse state in a cache database, so a file that has grown is read on from where it
  stopped. That buys exact message and token counts at the cost of reading every byte once.
- **A title comes first from a title record**: `custom-title`, then `ai-title`, then
  `agent-name`, then the first real prompt. Lines Claude Code injects itself (`isMeta`, command
  output) are skipped as prompts.
- **The model it shows is the last assistant message's.** After an error such as "Not logged in",
  that message is Claude Code's own, with the model `<synthetic>`, and Orca shows that.
- **A compaction summary counts as a turn.** "This session is being continued from a previous
  conversation…" shows among the latest turns as if you had typed it. Claude Code marks those
  lines `isCompactSummary`.
- **Actions**: Resume in Worktree, Resume in New Chat, Hand Off to Another Agent, View Log. Orca
  hosts terminals, so it can resume a session itself. Mimamori doesn't, so it copies the command or
  hands it to a terminal app.

## What you will see

- **A Sessions list.** The switch at the top of the file list becomes **Changes | Commits |
  Sessions**. It lists the worktree's sessions, newest activity first, under day headings like the
  feed's. Each row shows:
  - the agent's badge, and a dot while it runs;
  - its title on one line;
  - "2h ago · 1h 12m · 14 turns · 9 files · PR #87", and its unsent note count.

  A filter field (⌘F, as in the file list) matches titles, prompts, branches and file paths.
- **A session.** Selecting a row shows it where the diff goes:
  - its title, agent, branch, and when it started and ended;
  - its first prompt (folded after six lines) and its latest prompt;
  - its turns, each with its prompt's first line, when and how long, and the files it changed;
  - the files it changed, each opening its diff under Changes;
  - its subagents (kind and description), its pull request as a link, and its model.

  A session known only from its transcript says "from its transcript", and shows only what the
  transcript gives.
- **Actions** on the session, each with a tooltip and an accessibility label:
  - **Copy Resume Command**: `cd '<folder>' && claude --resume <id>`, or the agent's own
    equivalent. Greyed out, with the reason, when the folder is gone or the agent has no resume.
  - **Copy as a Prompt**: a hand-off for another agent. The title, the worktree and branch, the
    first and latest prompts, the files changed with their counts, the open review notes in
    `ReviewNotePrompt`'s shape, the pull request, and the transcript's path.
  - **Show Transcript in Finder**.
  - **Go to Agent**, while it runs.
- **Elsewhere.**
  - A changed file credited to an agent offers **Show Session** in its context menu.
  - An ended card in the Agents window opens its session in the list.
  - The activity feed's entries for a turn open its session.

Mimamori never edits, moves or deletes a transcript, and never starts an agent itself.

## Where the history comes from

Two layers, merged by session id. A hook's `session_id` is the Claude Code transcript's file name
and Hermes's `sessions.id`, so the two layers meet without guessing.

### Mimamori's own record, for everyone

The activity feed gains the session id on each agent entry and on each file change traced to an
agent (`ActivityEntry.session`, decoded with `decodeIfPresent`). The history of a worktree is then
a fold over its feed entries: a session's start and end, its turns and their prompts, its tool
calls and its files.

- **No new kind of data on disk.** The feed already saves the first line of each turn's prompt,
  for as long as you keep the feed. The session id is the only addition, so a session known only
  from the feed shows its prompts' first lines.
- **No new file.** It's kept and pruned with `activity.jsonl`.
- **Limits:** it covers only sessions Mimamori heard from its hooks, from the release that adds the
  id. Earlier entries have no id and stay in the feed only.

### Transcripts, opt-in

With transcripts on, the list also reads the agents' own records for the watched worktrees:
- sessions from before Mimamori ran, or without hooks;
- titles, pull request links, subagents and the model, which hooks never send.

What it reads stays in memory, as the transcript adapter's reader does, and is never written to
disk.

## What the agents keep

Surveyed read-only on 2026-11-05, on one Mac.

**Claude Code** keeps 349 session files in 101 project folders, with 261 subagent files beside them:
4.4 GB, 27 files over 10 MB, the oldest from 2026-08-25. `cleanupPeriodDays` deletes old ones; how
far back they reach depends on that setting.
- **Where.** `projects/<cwd, each non-alphanumeric character as "-">/<sessionId>.jsonl`. Subagents
  are in `<sessionId>/subagents/agent-<id>.jsonl`, each with a `.meta.json` giving `agentType` and
  `description`. The encoding is lossy, so a folder's name narrows the search and the `cwd` inside
  the file confirms it.
- **Every line** carries `sessionId`, `timestamp`, `cwd` and `gitBranch`, and a prompt line also
  carries `version` and `entrypoint`. 66,289 lines came from the desktop app (`claude-desktop`),
  1,832 from the CLI, and 4 from the SDK.
- **Records written again and again**, so the newest is near the end of the file:

  | Record | Keys | Files that have it |
  | :- | :- | :- |
  | `last-prompt` | `lastPrompt` | 349 of 349 |
  | `custom-title` | `customTitle` | 330 |
  | `agent-name` | `agentName` | 202 |
  | `pr-link` | `prNumber`, `prRepository`, `prUrl`, `timestamp` | 132 |
  | `ai-title` | `aiTitle` | 11 |

- **Lines that aren't prompts.** A user line with `isMeta`, with a tool result, or with
  `isCompactSummary` (25 files) isn't a prompt.
- **Model.** An assistant line's `message.model`. It is `<synthetic>` for Claude Code's own
  messages, so those are skipped.
- **Size.** Our own session's file is 19 MB with 4,415 lines. The transcript adapter's survey saw
  one of 661 MB.

**Hermes** keeps a row per session in `state.db`'s `sessions` table:
- `title` and `title_source`;
- `started_at`, `ended_at` and `end_reason`;
- `message_count` and `tool_call_count`;
- `cwd`, `git_branch` and `git_repo_root`;
- `last_activity_at` and `last_activity_description`;
- `parent_session_id` (compression continues a session in a child), and `archived` and `hidden`.

The list needs only this table, never `messages`.

**Codex** isn't installed here, so it isn't surveyed. Orca reads `~/.codex/sessions/<y>/<m>/<d>/
rollout-*.jsonl`, whose first record names the session's folder.

## Reading cheaply

The list must not cost energy while you aren't looking at it, and must not read gigabytes when you
are.

- **Only watched worktrees.** List `projects/`, and keep the folders whose names are a watched
  worktree's encoded path, or start with it followed by "-", for sessions started in a subfolder.
  Then confirm each file's `cwd`.
- **The start and end of each file, never the middle.**
  - From the start: up to 64 KB, read on to 1 MB at most, for the `cwd`, the branch, the start time
    and the first real prompt.
  - From the end: 256 KB, read back to 8 MB at most, for the newest title records, the last prompt,
    the pull request, the last time and the model.
  - Turn counts come from Mimamori's own record. A session known only from its transcript shows
    none, unless the spike finds a count cheap enough.
- **Only when asked.** The index is built when the Sessions list opens. While it is open, a
  session's entry is read again when a hook reports that session's turn ending or the session
  ending. No file system watch on `projects/`, and no timer.
- **Remembered, not reread.** Results stay in memory, keyed by path, size and modification time,
  so reopening the list reads only files that changed.
- **Off the main thread**, one file at a time, at utility priority.

## Design

### MimamoriCore

- `ActivityEntry.session: String?` and `ChangeAttribution.session: String?`, decoded with
  `decodeIfPresent`.
- `SessionRecord`: the agent, the session id, the worktree, when it started and ended, its turns
  (prompt, start, end, files) and its files, and where each part came from (`.feed`,
  `.transcript`).
- `SessionHistory`, pure functions, tested like `ReviewLedger`:
  - `fold(_ entries: [ActivityEntry]) -> [SessionRecord]`;
  - `merge(_ records:, _ summaries: [TranscriptSummary])`, joining by session id;
  - `matching(_ query:)`, sorted by last activity.
- `ClaudeSessionIndex`:
  - `projectFolders(for worktrees:, in projects:)`, with the lossy encoding;
  - `summary(of file:) -> TranscriptSummary?`, from the start and the end as above;
  - the title in Orca's order (`custom-title`, `ai-title`, `agent-name`, the first prompt), with
    `isMeta`, tool results, `isCompactSummary` and `<synthetic>` skipped;
  - subagents from their `.meta.json` files, never their transcripts.

  The reading back from the end is shared with the transcript adapter's `ClaudeTranscript`.
- `HermesSessionIndex`: one query on `sessions` for the watched worktrees' folders, read-only,
  with `HermesSessions`' busy timeout. Archived and hidden sessions are left out, and a compressed
  session's children fold into it.
- `ResumeCommand.make(agent:sessionID:folder:configDirectory:) -> String?`, shell-quoted with
  `AgentConfigLocations.shellQuoted`, and setting `CLAUDE_CONFIG_DIR` when Mimamori found
  transcripts through it. `nil` for an agent with no resume.
- `SessionHandoffPrompt.format(_:notes:)`.

### App

- `AgentHub` stamps the session id on the notes it hands to `AppModel.record(agentNotes:…)`, and
  `ChangeAttribution` carries it to file changes.
- `SessionHistoryModel` per worktree: folds the feed, runs the indexes when the list opens, and
  merges in the live sessions from `AgentHub`.
- Views:
  - the third segment and its shortcut;
  - `SessionRow`, `SessionDetailView`, and the actions;
  - **Show Session** on changed files, and the links from the Agents window and the feed.
- `Diagnostics`: how many sessions came from the feed and from transcripts, and how long the last
  index took. No content.
- README: the feature, and in "Privacy and footprint", that the feed now saves a session id, and
  what the list reads with transcripts on. Help: the Agents and Privacy topics. CHANGELOG.

## Steps

1. **Spike** (read-only, on this Mac):
   - time and bytes read to index the watched worktrees' sessions, and all 349 files, cold and
     warm;
   - how often the last 256 KB holds the title and the last prompt, and the first 64 KB the first
     prompt;
   - whether counting a file's prompts is cheap enough to show turns for transcript-only sessions;
   - whether `claude --resume <id>` finds a session started in the desktop app, and one started in
     another folder;
   - Hermes's and Codex's resume commands.
2. **Mimamori's own record and the list** (about 800–1,100 lines with tests). The session id in the
   feed, `SessionHistory`, the Sessions segment, the row, the detail, Copy Resume Command, Copy as
   a Prompt, Show Transcript in Finder, Show Session, README and Help. No transcripts yet.
3. **Claude Code's transcripts** (about 500–700 lines). `ClaudeSessionIndex`, the merge, the
   "from its transcript" label, and the switch if the transcript adapter hasn't shipped it yet.
4. **Hermes** (about 200–300 lines). `HermesSessionIndex`.
5. **Later.**
   - A repository's whole history, including worktrees since removed, whose transcripts stay
     behind when an agent's worktree is cleaned up.
   - **Open in Terminal**, through a `.command` file, so no Automation permission is needed.
   - A commit tied to the session that made it, from its `git commit` tool call.
   - Codex, once surveyed on a Mac that has it.

## To decide first

- **One transcript switch or two.** The transcript adapter decided on one switch, **Read an
  agent's transcript while its hooks are silent**, and the history reads the same files for another
  reason. *Recommended:* one switch, reworded to cover both uses, with both listed under it. Both
  keep the same promise: read on your Mac, shown, never written down or sent. Split it only if
  people ask.
- **Where the list lives.** *Recommended:* a third segment beside Changes and Commits, since a
  session belongs to a worktree as its commits do. The alternatives:
  - a tab in the Agents window, which is about now, not the past;
  - a window of its own, which would need its own way to pick a worktree.

## Decided

- **Watched worktrees only.** Mimamori reads nothing about repositories you haven't added. A
  history of every project is Orca's job, not Mimamori's.
- **Never the middle of a file** for the list. Exact message and token counts aren't worth reading
  4 GB once and caching what it held.
- **Nothing read from a transcript is written to disk**, the index included. Only the session id
  joins what the feed already saves.
- **No account, no costs, no delete.** Mimamori shows what you need to pick work back up, and
  leaves the agents' files alone.

## Tests

- Fixtures written for the tests, never taken from a real transcript.
- `SessionHistory`:
  - folding feed entries into sessions, two sessions of one agent in one worktree kept apart;
  - entries without a session id left out;
  - the merge by id, and a transcript-only session;
  - search over titles, prompts, branches and paths.
- `ClaudeSessionIndex`:
  - the folder encoding, a subfolder, and two worktrees whose encoded names collide;
  - the title order;
  - `isMeta`, tool results, `isCompactSummary` and `<synthetic>` skipped;
  - a title found only by reading further back, and one beyond the cap;
  - a partial last line;
  - unknown record types;
  - subagents from `.meta.json`.
- `HermesSessionIndex`: archived and hidden rows; a compressed session's child; a database
  opened read-only in WAL mode.
- `ResumeCommand`: quoting a folder with spaces and quotes; `CLAUDE_CONFIG_DIR`; an agent with no
  resume.
- `ActivityEntry`: a saved feed without session ids still decodes.
- By hand, in a scratch setup with scratch transcripts: the list with the switch off and on,
  resuming from a copied command, and the energy cost of opening the list (Activity Monitor's
  Energy Impact, with the list closed and open).

## Risks

- **Formats change.** None of the title records is documented, and Claude Code ships weekly.
  Each reader reads only the keys it needs and gives up quietly: a session it can't read shows
  what the feed knows, or isn't listed.
- **Large files.** The reads at the start and end are capped, so a 661 MB transcript costs no more
  than a small one.
- **The wrong folder.** The encoded folder name is lossy, so two worktrees can share one. The `cwd`
  inside the file decides.
- **History that disappears.** Claude Code deletes old transcripts after `cleanupPeriodDays`, and
  Mimamori prunes its feed after the days you choose. The list shows what is left, and the README
  says so.
- **Resuming in the wrong place.** `claude --resume` looks for the session under the folder it runs
  in, so the command changes to the session's folder first. A removed folder greys the action out.
  The spike checks sessions from the desktop app.
- **Privacy.** With transcripts off, nothing new is read and only the session id is saved. With
  them on, the list reads the start and end of the watched worktrees' transcripts while it's open,
  and keeps what it read in memory.
- **Energy.** No watching and no timer, and work only while the list is open. The by-hand check
  measures it.
