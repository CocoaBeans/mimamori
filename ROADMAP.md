# Roadmap

## Public release

Mimamori ships outside the Mac App Store: the App Sandbox would block process scanning, the
hook installers, reading agents' session records and running `git` on arbitrary folders.
The plan is a free, open-source release distributed as a notarized download and a Homebrew
cask. These items gate it.

### Name

- [x] Rename Vigil to Mimamori, first, while the only hooks to migrate are the maintainer's.
      Planned in [docs/plans/rename-to-mimamori.md](docs/plans/rename-to-mimamori.md).

### Distribution

- [x] Sign with a Developer ID certificate and notarize each build (`notarytool`), stapling the ticket.
- [x] Package a DMG (`Scripts/release.sh`).
- [x] Publish 1.0.0 on GitHub Releases, from the public repository.
- [x] Publish a Homebrew cask (`brew install --cask cocoabeans/tap/mimamori`).
- [x] Add automatic updates with Sparkle (signed appcast), published with each GitHub release.
- [ ] Release workflow in CI: build, sign, notarize, attach the DMG, update the appcast and cask.

### First run and hooks

- [x] Onboarding that explains what Mimamori watches and what hooks are, before anything is installed.
- [x] Make it clear which files the hook installers change (`~/.claude/settings.json`,
      `~/.hermes/config.yaml`), where backups go, and how to uninstall cleanly.
- [x] Remove Mimamori's hooks when the app is deleted, or document how to: Mimamori › Uninstall
      Mimamori…, and the README's manual steps.
- [x] Troubleshooting for hooks: what became of each event, a test event, and diagnostics to
      copy into a bug report.

### Compatibility

- [ ] Test with more agent setups: Claude Code CLI and desktop, Hermes CLI, gateway and desktop,
      Codex, Cursor, Aider, and several agents in one worktree.
- [ ] Test on large repositories and many worktrees for CPU, memory and refresh latency.
- [ ] Decide the minimum macOS version and test on it.

### Cleanup

- [x] Keep the debug hooks (`MIMAMORI_DEBUG_*`, `DebugHooks.swift`) out of release builds,
      or gate them behind a build flag.
- [x] Every control has a tooltip and an accessibility label.

### Trust and docs

- [x] A privacy statement: no telemetry, the one network request (the update check), what is
      written to disk and where: the README's "Privacy and footprint", and Help's Privacy topic.
- [x] Add CONTRIBUTING and a security contact (the code is already MIT licensed).
- [x] Screenshots and a short demo for the README and release page.
- [x] A short in-app guide under Help › Mimamori Help (⌘?): what Mimamori does and how to use it.
      Planned in [docs/plans/help-window.md](docs/plans/help-window.md).

## Visual polish

Planned in [docs/plans/visual-polish.md](docs/plans/visual-polish.md). Animate only on a change of
state, never on a loop.

- [x] One look per agent: a glyph per agent kind, colour for state only, one attention language.
- [x] Group the activity feed by turn, with day separators.
- [x] An agent banner that fits its column: two rows when narrow, never a bare "…".
- [x] A mini diff bar and file-type icons on each changed file.
- [x] Compact sidebar rows: agent glyph and chips for changed, flagged and to-review files.
- [x] A menu-bar popover that reuses the widget's views.
- [x] A change overview beside the diff, and hunk headers that stay put.
- [x] Settings › Agents split into tabs.
- [x] A real app icon.
- [x] A status pill in the toolbar for the most pressing agent.

### Agents window

- [x] Agents grouped under headings: Needs you, Working, Ready, Ended, each one foldable.
- [x] Each agent a card tinted like the banner, with the widget's badge: its glyph in a disc the
      colour of its state.
- [x] Each agent's timer in a pill the colour of its state.
- [x] Go to agent and Summary as icon buttons that appear on hover; agents that need you keep a
      tinted Go to agent.
- [x] A turn timeline: one tick per tool call, coloured by kind, so a turn's rhythm and a long
      silence show at a glance.
- [x] "Quiet for 4m" on an agent still working that has made no tool call for a while.
- [x] Two columns when the window is wide, like the extra-large widget.
- [x] Mini diff bars on the file chips, with the changed-file diff bars above.

## Later

- [x] Desktop widgets showing the running agents, who needs you, and optionally each task
      ([docs/plans/desktop-widgets.md](docs/plans/desktop-widgets.md)).
- [x] Discard a hunk or a whole file from an uncommitted diff: off until you turn it on, refused
      while an agent is mid-turn, after a snapshot, with Undo.
- [ ] An iPhone companion: the agents at work, who needs you, and Allow or Deny from the phone, on
      the same network first, then over cellular
      ([docs/plans/iphone-companion.md](docs/plans/iphone-companion.md)).
- [ ] Review notes: comment on lines in the diff and send the notes to the agent, which picks
      them up through its hooks ([docs/plans/review-notes.md](docs/plans/review-notes.md)).
- [ ] Read an agent's transcript while its hooks are silent, opt-in, and give a turn already under
      way at launch its real start ([docs/plans/transcript-adapter.md](docs/plans/transcript-adapter.md)).
- [ ] A history of agent sessions per worktree: what each was asked, what it changed, its notes
      and pull request, with a command to resume it or a prompt to hand it on
      ([docs/plans/session-history.md](docs/plans/session-history.md)).

- Paid "supporter" build or team features, if there is demand after release.
