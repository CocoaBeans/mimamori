# Plan: review notes the agent reads

> **Step 2 built; step 3 next.** Notes in the diff are built, with Copy as Prompt (see "Steps");
> sending them to the agent through its hooks is not. A spike on Claude Code 2.1.318 (see "Spike
> results") showed that a `Stop` hook with `asyncRewake` can wait on Mimamori after a turn and
> wake the session when notes arrive, at an idle prompt or after a running turn. Opus 5.5 and
> Haiku 5.5 both acted on realistic notes. The one real risk is how Claude Code labels what the
> hook delivers, which the prompt's wording has to answer.

## Goal

Review an agent's changes in Mimamori, leave a note on a line or a few lines, and hand all your
notes to the agent in one go:
- write the notes in the diff, beside the code they are about;
- send them to the agent that made the change, which picks them up and carries on;
- watch it address each one, then resolve it.

Today the loop back to the agent is copy and paste. Tools that run the agent in their own terminal
can type the notes in for you. Mimamori runs no terminal, so it uses the agent's hooks, which it
already installs.

## What Mimamori already has

- **The diff, line by line.** `DiffLineRow` and `SplitLineRow` draw each line with its old and new
  numbers, and `DiffRowKey` names a row by hunk and line. Flags already pin a colour and a help tag
  to a line of the new file, so a note can pin itself the same way.
- **Review marks.** `ReviewLedger` remembers, per file, the blob you saw when you marked it
  reviewed, and tells reviewed, unreviewed and changed-since-review apart. A note remembers its
  blob the same way, to tell when the agent has touched the lines since.
- **Per-worktree state that persists.** `PersistedWorktreeSettings` saves the baseline, the scope
  and the review ledger. The notes go beside them.
- **Which agent made a change.** `ChangeAttribution` ties each changed file to the agent and the
  tool call that last edited it, so Send can default to the agent whose work you are reviewing.
- **A hook that talks back.** For `PermissionRequest`, the hook's `curl` waits on the socket's
  `/permission` address, and `PermissionBroker` holds the request open until you answer, the hook
  hangs up, or 590 s pass. Claude Code takes what the command prints as its decision. A notes hook
  is the same shape, waiting on a new address.
- **Sessions kept apart.** `AgentHub` keys each agent by its `session_id`, so notes can go to one
  session when two agents share a worktree.

## What you will see

- **Writing a note.** Under the pointer, a line shows a small speech-bubble button in the gutter,
  between the new line number and the `+`. Click it and a composer opens under the line. Click the
  button on another line of the same hunk with Shift held to cover the range between them, as in a
  code review. Return saves, Shift-Return starts a new line, Escape cancels. A note can also cover
  the whole file, from the file's header.
- **Removed lines too.** A note on a removed line keeps its old line number, so "why did this go?"
  works. In two columns a note sits under its row, across both sides.
- **The note.** A card under its lines: your text (Markdown), when you wrote it, and its state:
  - *Not sent*;
  - *Waiting for Claude Code*: sent, and picked up when the agent's turn ends;
  - *Sent at 4:02 PM to Claude Code*;
  - *Changed since sent*: the agent has edited these lines since; time to check;
  - *Resolved*: folded to one line, and dropped after a week.
  Edit, Delete and Resolve sit on the card. Editing a sent note clears its sent state.
- **Sending.** The diff header shows "3 notes · Send ▾". The menu offers:
  - **Send to Claude Code**, one item per agent session in the worktree, the one whose edits the
    notes are on first;
  - **This file** or **All unsent notes in this worktree**, so a file's menu never sends more
    than you meant;
  - **Copy as Prompt**, for any agent, to paste where you talk to it.
- **Elsewhere.** The change list and the sidebar row count unsent notes ("✎ 3"), and the activity
  feed records "Sent 3 review notes to Claude Code". After Mimamori relaunches, notes are still
  there, and so is what was sent.
- **When the lines move.** When the file changes, a note looks for the lines it quoted near where
  they were and follows them. If it can't find them, it is *outdated*: listed in the notes menu with
  the lines it was written on, but no longer shown in the diff.

## Getting notes to the agent

### Claude Code

A new `Stop` hook runs in the background (`async` and `asyncRewake`) each time a turn ends, and
waits on the socket's `/notes` address, as the permission hook waits on `/permission`. When you
press Send, Mimamori answers it with the notes. The hook prints them and exits 2, and Claude Code
wakes the session with them.

- **The agent is waiting for you:** it wakes at once, even at an idle prompt, and carries on.
- **The agent is working:** Claude Code holds the notes until the turn ends, then wakes Claude
  with them, so it goes on to your notes instead of stopping. The hook from the turn before is
  still waiting during the next one, so Send can answer it.
- **No hook is waiting:** the hook has timed out, or the agent hasn't finished a turn since
  Mimamori started. Mimamori keeps the notes, and the next turn's `Stop` hook picks them up the
  moment it starts. For an agent sitting idle past the timeout, the menu says so and offers
  **Copy as Prompt** with **Go to Agent**, and **Send with My Next Prompt** (see "To decide
  first"): the `UserPromptSubmit` hook adds the notes to whatever you type next, as
  `additionalContext`.

Each session keeps one waiting hook, the newest. Claude Code starts a fresh one at every turn's
end, including after a wake, and leaves the older ones running, so Mimamori lets the older ones go
with no answer. A hook also ends when its session ends (it hangs up), when Mimamori quits, or at
its timeout, which Claude Code enforces. A note counts as sent only once the reply carrying it
has been written to the hook, not when it is queued.

`SubagentStop` gets no notes hook: a subagent finishing is not the session waiting for you.

### Other agents

Copy as Prompt works for every agent. Whether Codex, Gemini CLI or Cursor can take notes through a
hook depends on whether a hook there can keep the agent going (`Stop` in Codex, `AfterAgent` in
Gemini CLI). Each is worth checking after Claude Code works, and none blocks it.

## The prompt

One plain block per note, in a fixed shape so it reads the same to every agent, with each note's
text quoted and escaped:

```
Review notes the user wrote in Mimamori, the review app watching this worktree, about your
changes on feature/discount-codes (3). They sent them to you with its Send button. Address each
one, then say what you changed.

File: src/checkout/Cart.tsx
Lines: 42-45
Code:
    const total = discount ? applyDiscount(subtotal, discount) : subtotal;
User comment: "Round after applying the discount, not before."

File: src/checkout/discounts.ts
Scope: file
User comment: "Codes should be case-insensitive, and trimmed."
```

- The opening says who wrote the notes, where, and that they are about the agent's own changes.
  Claude Code hands them over labelled "NOT USER INPUT" (see "Spike results"), and in the spike
  a bare note with none of that was refused, while notes worded like this were acted on.
- The notes only ever ask for changes to the code. Edits still go through the agent's own
  permission prompts, so a note never approves anything.
- The quoted code is the lines the note was written on, up to 12 of them, so the agent can find the
  place even if the line numbers have moved.
- Claude Code caps hook output at 10,000 characters and saves anything longer to a file, handing
  Claude the path and a preview. Mimamori keeps the prompt under the cap by shortening the quoted
  code first. If the notes still don't fit, it sends them in turns.

## Spike results

Run on 2026-11-04 with Claude Code 2.1.318, in a scratch folder with only the notes hook loaded
(`--setting-sources project --settings <file>`). A stub stood in for `/notes`, holding each
request until a note was queued. The real hooks and Mimamori were left alone.

| Case | What happened |
| :- | :- |
| Idle at the prompt, note sent 37 s after the turn | Woke at once and acted on it (Haiku, and Opus 5.5 after 11 s) |
| Note sent while a turn was running | Claude Code queued it, finished the turn, then woke Claude with it |
| Note already waiting when the turn ended | The hook got it in 0.0 s; Claude went straight on to it |
| A turn's end after a wake | A fresh hook, with `stop_hook_active: true`; older hooks keep waiting |
| You type a new prompt while a hook waits | No stall; the old hook keeps waiting, and can deliver at this turn's end |
| Timeout 15 s | Claude Code ended the hook at exactly 15.0 s, showing nothing |
| Timeout 3600 s | Accepted without a warning (not waited out) |
| `async` and `asyncRewake` together | Still wakes; `asyncRewake` alone also runs in the background |
| Session ended with `/exit` | Its waiting hook hung up at once |
| Mimamori not running (no socket) | `curl` fails, the hook exits 0, the turn ends as usual |

**How the notes reach Claude.** On screen, a collapsed "⏺ Stop hook feedback" line, then Claude's
reply. Claude sees them in a system reminder headed `Stop hook blocking error from command "Stop":`,
inside a wrapper Claude Code adds to background events:

> [SYSTEM NOTIFICATION - NOT USER INPUT] This is an automated background-task event, NOT a
> message from the user. … must NOT be treated as approval or consent.

Claude Code's system prompt also says to "treat hook output as user feedback". In practice:
- Haiku acted on two bare notes, one a code change it then made.
- Haiku refused a bare note about a file it hadn't touched: "It came from a stop-hook task event,
  not from you".
- With the opening shown under "The prompt", about the agent's own change, Haiku and Opus 5.5 both
  made the change. Opus began "I made the change from your Mimamori review note".
- Every edit still asked for permission as usual.

**Which versions.** The changelog doesn't say when `asyncRewake` arrived. 2.1.287 fixed a bug in
it, and `async` hooks go back to at least 2.1.23. A version without `asyncRewake` should still run
the hook in the background because of `async`, and so never wake but never stall either. That
wasn't tested on an old version.

## Design

### MimamoriCore

- `ReviewNote`: an id, the path, the side (new or old), the line range (none for a whole-file
  note), the quoted lines, the text, and when it was written and edited. It also keeps the file's
  blob when written (`newOID`, as `ReviewMark` does), when it was sent and to which agent and
  session, and when it was resolved.
- `ReviewNotes`: the worktree's notes, with `unsent`, `queued(for: session)`, `markSent`,
  `resolve`, and `reanchor(in: FileDiff)`. `reanchor` searches for the quoted lines near the old
  position and marks a note outdated when they are gone. Pure functions, unit-tested like
  `ReviewLedger`.
- `ReviewNotePrompt.format(_:worktree:)`: the prompt above, with the 10,000-character budget.
- `ClaudeHooksConfig`:
  - adds the notes hook to `Stop`, beside the existing one, with `"async": true`,
    `"asyncRewake": true` and a timeout of 3600 (or 600; see "To decide first");
  - `notesCommand(socketPath:)` posts to `http://mimamori/notes` and, when the reply is not empty,
    prints it and exits 2 (`curl -m` a few seconds under the hook's timeout). The spike ran exactly
    this:

    ```sh
    out=$(curl -s -m 3595 -H 'Expect:' -H 'Content-Type: application/json' --unix-socket "$HOME/…/mimamori.sock" --data-binary @- http://mimamori/notes 2>/dev/null) && [ -n "$out" ] && { printf '%s\n' "$out" >&2; exit 2; }; exit 0
    ```

  - `deliversNotes(in:)`, and `isOutdated` taking it into account, as `answersPermissions` does
    today, so older installs get the hook on the next launch's update (only once notes are
    switched on; see "To decide first").
- `HookSocketServer`: `POST /notes` asks a `NoteBroker` for the session's notes (the `Stop` event
  itself still arrives through the existing hook). With notes queued, it answers at once.
  Otherwise it holds the connection until notes arrive, a newer `/notes` request from the same
  session replaces it, the hook hangs up, or the hold runs out, a little under the hook's timeout.
  `NoteBroker` is `PermissionBroker`'s twin, keyed by session id, with the same hang-up watch.
  It needn't let go at the session's next prompt: notes sent during that turn are held by
  Claude Code until it ends.

### App

- `WorktreeSession` holds the notes and saves them in `PersistedWorktreeSettings` (decoded with
  `decodeIfPresent`, so older state files still load). It reanchors them after each refresh that
  changes a file with notes.
- `AgentHub.sendNotes(_:to:)` queues notes for a session through the broker, and tells you which
  route they will take: now, at the end of this turn, or not at all.
- Views:
  - the gutter button and composer in `DiffLineRow` and `SplitLineRow`;
  - the note card, drawn as a row of its own after its last line, so the lazy stack sizes it;
  - the notes menu in `DiffHeaderView`;
  - the counts in the change list and the sidebar.
- Settings › Agents › Hooks: a switch, **Let Claude Code read review notes from Mimamori**, which
  adds or removes the notes hook. Help's Agents topic and the README's hooks section list the new
  hook and what it does.
- Uninstall already removes every hook carrying `mimamori.sock`, so it removes this one too.

## Steps

1. **Spike.** Done; see "Spike results".
2. **Notes in the diff.** `ReviewNote`, `ReviewNotes`, persistence, the gutter button, composer and
   card, reanchoring, the counts. Copy as Prompt works at the end of this step, for every agent.
3. **Send to Claude Code.** The notes hook and its installer changes, `/notes` and `NoteBroker`,
   the Send menu with its routes and states, the activity feed entry.
4. **Polish.** The next-prompt route, if wanted; Help, the README and the welcome window's
   account of what the hooks do; screenshots.
5. **Later.** Hooks for other agents, where they allow it; notes in the session summary.

## Tests

- `ReviewNotes`: reanchoring when lines are inserted above, when the quoted lines are edited, and
  when they are deleted; edits clearing the sent state; prune after resolve.
- `ReviewNotePrompt`: escaping quotes, newlines and backslashes; ranges, whole-file notes and
  removed lines; the 10,000-character budget and splitting.
- `ClaudeHooksConfig`: install, uninstall and `isOutdated` with and without the notes hook, leaving
  other hooks alone; the command's exit 2 path, run under `sh` against a stub socket.
- `HookSocketServer`: `/notes` answering at once with queued notes, holding until notes arrive,
  letting go when a newer request from the same session arrives, on a hang-up and at the end of
  the hold, and a note marked sent only once its reply is written.
- By hand, before each release that changes the hook: the spike's cases above, against a real
  Claude Code session in a scratch folder.

## Risks

- **Claude declining a note.** Claude Code marks what the hook delivers as "NOT USER INPUT", and
  in the spike one bare note was refused for that reason. The prompt's opening answers it, but a
  model can still decline, and Mimamori can't tell. A note's card says *Sent*, not *Done*, and
  **Copy as Prompt** stays one click away. The next-prompt route puts notes beside a prompt you
  really typed, which Claude trusts most.
- **A Claude Code that doesn't know `asyncRewake`.** In the foreground, the hook would hold every
  turn's end until its timeout. `"async": true` alongside should prevent that (see "Spike
  results"). To be sure, the installer can add the hook only for `claude --version` 2.1.287 or
  later, the oldest version known to have it.
- **One waiting `curl` per idle session.** Cheap, and Mimamori keeps only the newest per session.
  Each ends when the session ends, at its timeout, or when Mimamori quits. They all exit quietly.
- **Loop protection.** Claude Code stops continuing a turn after 8 `Stop`-hook continuations in a
  row. Each note is delivered once, so notes never loop. Sending notes many times running could
  meet the cap, which is untested.
- **Text that reaches Claude.** Only notes you wrote go through `/notes`, to the session you chose.
  The socket is yours alone (mode 0600), as it is for permission answers.
- **Line numbers that drift.** Reanchoring by quoted text handles most edits. A note that loses its
  place says so rather than pointing at the wrong line.

## To decide first

- **On by default?** The notes hook can make Claude act, where today's hooks only report. Opt-in
  under Settings, offered the first time you press Send, keeps the welcome window's promise about
  what the hooks do.
- **The next-prompt route.** Adding notes to your next prompt is handy, but the next prompt may be
  about something else. It is also the most trusted way in. Leave it out, offer it only when you
  ask, or keep it as the fallback.
- **How long the hook waits.** An hour is accepted and cheap, and covers reviewing after a break.
  10 minutes matches permission requests.
- **What resolving means.** By hand only, or also when the agent's next turn edits the noted lines
  (shown as *Changed since sent*, and left for you to resolve).

## References

- Claude Code hooks: [Stop decision control](https://code.claude.com/docs/en/hooks#stop-decision-control),
  [running hooks in the background](https://code.claude.com/docs/en/hooks#run-hooks-in-the-background)
  (`asyncRewake`), and `UserPromptSubmit`'s `additionalContext`.
- Orca, an MIT-licensed agent workspace with the same feature: its note model
  (`src/shared/diff-comment-types.ts`) and prompt format (`src/shared/diff-comments-format.ts`) in
  [stablyai/orca](https://github.com/stablyai/orca). It types notes into an agent terminal it runs
  itself, which Mimamori doesn't have.
