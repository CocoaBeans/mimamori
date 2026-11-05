# Plan: review notes the agent reads

> **Proposed.** Nothing is built yet. Step 1 is a spike that settles the one unknown: whether
> Claude Code's `asyncRewake` hook, set on `Stop`, can hold a connection to Mimamori after a turn
> ends and wake the session when notes arrive. Everything else builds on what Mimamori already has.

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

Claude Code's hooks give three ways in. Mimamori uses whichever applies when you press Send.

1. **The agent has just finished a turn and is waiting for you.** A new `Stop` hook runs in the
   background (`asyncRewake`) and waits on the socket's `/notes` address, as the permission hook
   waits on `/permission`. Send answers it with the notes. The hook prints them and exits 2, which
   wakes the session at once, even at an idle prompt. Claude reads them as a system reminder and
   carries on.
2. **The agent is working.** Send queues the notes. When the turn ends, the same `Stop` hook finds
   them waiting and wakes the session straight away, so the agent goes on to your notes instead of
   stopping.
3. **The agent has been idle longer than the hook waits.** No hook is listening. The menu says so
   and offers **Copy as Prompt** with **Go to Agent**. Optionally (see "To decide first"), it also
   offers **Send with My Next Prompt**: the `UserPromptSubmit` hook adds the notes to whatever you
   type next, as `additionalContext`.

The waiting hook lets go with no answer when that session's next prompt arrives (you typed into it
yourself), when the session ends, when the hook hangs up, or after 590 s, under the hook's own
600 s timeout. A note counts as sent only once the reply carrying it has been written to the hook,
not when it is queued.

`SubagentStop` gets no notes hook: a subagent finishing is not the session waiting for you.

### Other agents

Copy as Prompt works for every agent. Whether Codex, Gemini CLI or Cursor can take notes through a
hook depends on whether a hook there can keep the agent going (`Stop` in Codex, `AfterAgent` in
Gemini CLI). Each is worth checking after Claude Code works, and none blocks it.

## The prompt

One plain block per note, in a fixed shape so it reads the same to every agent, with each note's
text quoted and escaped:

```
Review notes from Mimamori on your changes in feature/discount-codes (3). Address each one, then
say what you changed.

File: src/checkout/Cart.tsx
Lines: 42-45
Code:
    const total = discount ? applyDiscount(subtotal, discount) : subtotal;
User comment: "Round after applying the discount, not before."

File: src/checkout/discounts.ts
Scope: file
User comment: "Codes should be case-insensitive, and trimmed."
```

- The quoted code is the lines the note was written on, up to 12 of them, so the agent can find the
  place even if the line numbers have moved.
- Claude Code caps hook output at 10,000 characters and saves anything longer to a file, handing
  Claude the path and a preview. Mimamori keeps the prompt under the cap by shortening the quoted
  code first. If the notes still don't fit, it sends them in turns.

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
    `"asyncRewake": true` and a timeout of 600;
  - `notesCommand(socketPath:)` posts to `http://mimamori/notes` and, when the reply is not empty,
    prints it and exits 2:

    ```sh
    out=$(curl -s -m 595 -H 'Expect:' -H 'Content-Type: application/json' --unix-socket "$HOME/…/mimamori.sock" --data-binary @- http://mimamori/notes 2>/dev/null) && [ -n "$out" ] && { printf '%s\n' "$out" >&2; exit 2; }; exit 0
    ```

  - `deliversNotes(in:)`, and `isOutdated` taking it into account, as `answersPermissions` does
    today, so older installs get the hook on the next launch's update (only once notes are
    switched on; see "To decide first").
- `HookSocketServer`: `POST /notes` reports the `Stop` event as usual, then asks a `NoteBroker` for
  the session's notes. With notes queued, it answers at once. Otherwise it holds the connection
  until notes arrive, the session's next `UserPromptSubmit` or `SessionEnd`, a hang-up, or 590 s.
  `NoteBroker` is `PermissionBroker`'s twin, keyed by session id, with the same hang-up watch.

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

1. **Spike, about an afternoon.** Install the notes hook by hand in a scratch `CLAUDE_CONFIG_DIR`,
   with a stub `/notes` that answers after 30 s, and check:
   - the session wakes at an idle prompt, and Claude acts on the text;
   - notes waiting at the end of a turn keep the agent going, with no error banner;
   - typing a prompt while the hook waits doesn't stall, and Mimamori's release arrives;
   - what a Claude Code too old for `asyncRewake` does with it, and which version added it;
   - whether a longer timeout than 600 s is allowed, and what it costs.
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
  letting go on the next prompt, on a hang-up and on timeout, and a note marked sent only once its
  reply is written.

## Risks

- **A Claude Code that doesn't know `asyncRewake`.** If it ran the hook in the foreground, every
  turn would wait up to 10 minutes to end. `"async": true` alongside should keep an older version
  from waiting (it would then never wake, but never stall either). The spike confirms this. If it
  doesn't hold, the installer checks `claude --version` before adding the hook.
- **One waiting `curl` per idle session.** Cheap, and each one ends when you next prompt, the
  session ends or 10 minutes pass. Mimamori quitting closes them all, and they exit quietly.
- **Text that reaches Claude.** Only notes you wrote go through `/notes`, to the session you chose.
  The socket is yours alone (mode 0600), as it is for permission answers.
- **Line numbers that drift.** Reanchoring by quoted text handles most edits. A note that loses its
  place says so rather than pointing at the wrong line.

## To decide first

- **On by default?** The notes hook can make Claude act, where today's hooks only report. Opt-in
  under Settings, offered the first time you press Send, keeps the welcome window's promise about
  what the hooks do.
- **The next-prompt route.** Adding notes to your next prompt is handy, but the next prompt may be
  about something else. Leave it out, offer it only when you ask, or keep it as the fallback.
- **How long the hook waits.** 10 minutes, like permission requests, or longer if the spike says a
  longer timeout is fine.
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
