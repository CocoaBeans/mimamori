# Changelog

All notable changes to Mimamori are recorded in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Mimamori
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each release's longer notes,
the ones the update window and the release page show, are in [docs/releases](docs/releases).

## [Unreleased]

### Fixed

- Resizing the Agents window across the width where it switches between one and two columns no
  longer leaves the cards trailing the window's edge, their names cross-fading, until they catch up
  ([#37](https://github.com/CocoaBeans/mimamori/pull/37)).
- Typing a note no longer redraws the diff around it, and an open session summary no longer
  rebuilds its Markdown for every agent activity entry
  ([#34](https://github.com/CocoaBeans/mimamori/pull/34)).

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

[Unreleased]: https://github.com/CocoaBeans/mimamori/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/CocoaBeans/mimamori/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/CocoaBeans/mimamori/releases/tag/v1.0.0
