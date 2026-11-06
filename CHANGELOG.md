# Changelog

All notable changes to Mimamori are recorded in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Mimamori
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each release's longer notes,
the ones the update window and the release page show, are in [docs/releases](docs/releases).

## [Unreleased]

## [1.2.0] - 2026-11-05

### Added

- Put an agent to sleep between turns: Mimamori stops its process and keeps its session, and
  **Wake** opens a terminal in the worktree that resumes it. For Claude Code and Codex, off until
  you turn it on in Settings › General
  ([#53](https://github.com/CocoaBeans/mimamori/pull/53)).
- Your agents on your iPhone: pair it in the new Settings › iPhone by scanning a code with its
  Camera, and it shows your agents, as the Agents window does, whenever it's on the same network.
  Off until you turn it on; each iPhone connects with a key of its own, encrypted. The iPhone app
  is built from source for now
  ([#57](https://github.com/CocoaBeans/mimamori/pull/57)).
- The iPhone tells you when an agent needs you, finishes a turn or collides with another, as the
  Mac does, and with "Stay connected in the background" on, it does while it isn't open
  ([#58](https://github.com/CocoaBeans/mimamori/pull/58)).
- "Keep the screen on" in the iPhone's settings stops it dimming and locking while Mimamori is
  open, so your agents stay in view on a stand; by default only while it's charging
  ([#60](https://github.com/CocoaBeans/mimamori/pull/60)).
- Allow or Deny Claude Code's permission requests from the iPhone, on the agent's card or its
  notification, with the exact command, the Mac's countdown, and Face ID before Allow. Needs
  "Answer permission requests in Mimamori" on, and the activity feed says which iPhone answered
  ([#61](https://github.com/CocoaBeans/mimamori/pull/61)).
- Tap an agent on the iPhone for its list of actions: every step of its turn, newest first, then
  the turns before it under their prompts, with when each ran, how long it took and whether it
  failed ([#64](https://github.com/CocoaBeans/mimamori/pull/64)).
- Claude Code's subagents: an agent stays in Working while its subagents run, "waiting on 2
  subagents", and "finished a turn" waits for the last; its card and the banner list each one's
  kind, task, steps and latest step ([#67](https://github.com/CocoaBeans/mimamori/pull/67)).
- Commands an agent runs in the background show under its subagents, with how long each has run
  and how it ended; the agent reads "ready · 2 running in the background". The iPhone shows
  subagents and background commands on its cards, and marks the steps subagents took
  ([#68](https://github.com/CocoaBeans/mimamori/pull/68)).

### Changed

- With git from Xcode or its Command Line Tools, Mimamori runs that git directly rather than
  through `/usr/bin/git`, which asked `xcrun` where git is on every call. Each git command it runs
  takes about 60% less CPU
  ([#47](https://github.com/CocoaBeans/mimamori/pull/47)).
- Cards in the Agents window move to their new place in a brief ease-out rather than a long spring.
  An agent changes place at every turn, and with three agents at work the window and the main
  window together use about a fifth less CPU
  ([#48](https://github.com/CocoaBeans/mimamori/pull/48)).

### Fixed

- One Hermes session no longer shows as two, warning that "Two Hermes sessions" edited a file,
  when it edits files from `execute_code`. Hermes reports those tools with no session, and
  Mimamori now places them on the session whose turn ran them
  ([#72](https://github.com/CocoaBeans/mimamori/pull/72)).
- Answering by itself checks a Claude Code command against your ask rules whole, up to 64 KB,
  instead of its first 8000 characters, where a rule about its end could be missed; a longer
  command waits for you. A tool Mimamori doesn't know is described by a harmless field, never by
  its content or anything named like a token, password or key
  ([#71](https://github.com/CocoaBeans/mimamori/pull/71)).
- A Claude Code subagent working in a worktree of its own no longer moves its parent's card to
  that worktree and back with every step; it shows on its parent's card, with its worktree a click
  away ([#70](https://github.com/CocoaBeans/mimamori/pull/70)).
- The Mac takes a paired iPhone's name, and finishes pairing a new one, only once it has proved
  which pairing it is, as it already did for its answers. Before, another paired iPhone could
  name itself as a different one, or as an iPhone being paired
  ([#69](https://github.com/CocoaBeans/mimamori/pull/69)).
- A script run with Python, Node or the like no longer shows as a second agent in its worktree
  because one of its arguments mentions an agent, such as a path through a folder named
  `claude-profiles`. Mimamori now judges such a process by the program it runs alone
  ([#63](https://github.com/CocoaBeans/mimamori/pull/63)).
- A diff with wrapped lines could stop responding, right after a click on Reviewed while an agent
  was editing the file, and keep Mimamori busy until it was quit. The diff no longer measures its
  lines at widths it never shows them at
  ([#52](https://github.com/CocoaBeans/mimamori/pull/52)), and wrapped diffs of up to 300 lines
  are laid out in full rather than lazily, so their layout can't go round in circles
  ([#62](https://github.com/CocoaBeans/mimamori/pull/62)).
- A closed main window, Agents window or pinned overview no longer keeps redrawing while agents
  work. With three agents busy and only the menu bar showing, Mimamori uses about two thirds less
  CPU ([#46](https://github.com/CocoaBeans/mimamori/pull/46)).

## [1.1.1] - 2026-11-05

### Added

- A notice at launch when Mimamori couldn't read all of its saved state. It says what it did
  instead, and **Show in Finder** selects the copy it kept
  ([#33](https://github.com/CocoaBeans/mimamori/pull/33)).

### Changed

- Connecting Claude Code or Hermes edits their config files more carefully
  ([#31](https://github.com/CocoaBeans/mimamori/pull/31)).
  - `settings.json` keeps its layout, a symlinked file stays a symlink, and permissions are kept.
  - A file Mimamori can't read or parse is left as it is, with the reason.
  - Backups get unique names, and the first one is kept.

### Removed

- Launch no longer carries anything over from Vigil, the app's name before 1.0. It no longer moves
  a `Vigil` folder in Application Support into Mimamori's, and no longer swaps Claude Code or
  Hermes hooks that post to `vigil.sock` for Mimamori's: those belong to other apps of that name
  ([#39](https://github.com/CocoaBeans/mimamori/pull/39)).

### Fixed

- A `state.json` Mimamori can't fully read is no longer replaced by an empty one. It opens what it
  can, or the state as it was one save earlier, and keeps a copy of the file aside
  ([#29](https://github.com/CocoaBeans/mimamori/pull/29)).
- With two subagents at work in one session, one finishing a tool call no longer drops the other's
  waiting permission request, with its Allow and Deny
  ([#27](https://github.com/CocoaBeans/mimamori/pull/27)).
- Undo after a discard is refused while an agent is in the middle of a turn in that worktree, as
  Discard is. Both are checked again just before Mimamori writes, so a turn that starts after you
  confirm stops the write ([#43](https://github.com/CocoaBeans/mimamori/pull/43)).
- Removing a repository while Mimamori is looking for its worktrees no longer can crash Mimamori,
  give another repository its worktrees, or leave it watched until you quit
  ([#40](https://github.com/CocoaBeans/mimamori/pull/40)).
- Resizing the Agents window across the width where it switches between one and two columns no
  longer leaves the cards trailing the window's edge, their names cross-fading, until they catch up
  ([#37](https://github.com/CocoaBeans/mimamori/pull/37)).
- Typing a note no longer redraws the diff around it, and an open session summary no longer
  rebuilds its Markdown for every agent activity entry
  ([#34](https://github.com/CocoaBeans/mimamori/pull/34)).
- Marking the start or taking a snapshot while a refresh runs, as right after adding a large
  repository, no longer fails with "index.lock: File exists". A worktree you hide, or a repository
  you remove, while Mimamori is still starting to watch it is no longer watched anyway
  ([#41](https://github.com/CocoaBeans/mimamori/pull/41)).
- An agent whose session ended while its process kept running no longer counts as two agents:
  the menu-bar popover no longer reads "+1" beside it, nor the sidebar "2 agents · ended"
  ([#42](https://github.com/CocoaBeans/mimamori/pull/42)).

## [1.1.0] - 2026-11-04

### Added

- Review notes for the agent ([#17](https://github.com/CocoaBeans/mimamori/pull/17)).
  - Leave a note on a line or a range of lines in a diff, on removed lines, or on a whole file.
  - A note follows its code as the file changes.
  - **Copy as Prompt** copies a file's notes, or every unsent note in the worktree, as one prompt
    for the agent.
- Discarding a hunk or a whole file from an *Uncommitted* diff
  ([#21](https://github.com/CocoaBeans/mimamori/pull/21)).
  - Off until you turn it on in Settings › General › Working tree.
  - It shows what goes and asks first, and won't run while an agent is mid-turn in that worktree.
  - It takes a snapshot first, so Undo can put the change back.
- The menu-bar popover groups agents under Needs you, Working, Ready and Ended, and each group
  folds away ([#15](https://github.com/CocoaBeans/mimamori/pull/15)).
- A turn already under way when Mimamori starts shows its real start, read from Claude Code's
  session file and Hermes's record of running turns
  ([#20](https://github.com/CocoaBeans/mimamori/pull/20)).

### Fixed

- A second copy of Mimamori, such as an older one in Applications, no longer takes the hook socket
  and leaves the running copy deaf to its agents
  ([#18](https://github.com/CocoaBeans/mimamori/pull/18)).
- Diffs of files with Windows line endings show line by line. They used to show as one line, and
  could hide the next file in the diff ([#22](https://github.com/CocoaBeans/mimamori/pull/22)).

## [1.0.0] - 2026-11-02

### Added

- The first release: a lightweight Mac app that keeps watch over git worktrees while coding agents
  work.
- Live diffs of each worktree, against a choice of baseline: uncommitted, since the branch point,
  since Mark Start, or since any earlier snapshot.
- Flags for what deserves a look:
  - secrets, lockfiles, CI and agent instruction files;
  - mass deletions, skipped tests, conflict markers and more.
- Agent awareness: Mimamori finds Claude Code, Codex, Aider, Cursor, Gemini CLI, Goose, OpenCode,
  Amp and others with no setup.
  - With hooks, it follows each prompt and tool call.
  - You can answer Claude Code's permission requests from Mimamori.
- Ways to keep an eye on things: the toolbar pill, the Agents window, the menu bar, desktop widgets
  and notifications.
- Merges, rebases and their conflicts, review marks, an activity feed, and session summaries in
  Markdown.
- Automatic updates through Sparkle.

[Unreleased]: https://github.com/CocoaBeans/mimamori/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/CocoaBeans/mimamori/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/CocoaBeans/mimamori/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/CocoaBeans/mimamori/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/CocoaBeans/mimamori/releases/tag/v1.0.0
