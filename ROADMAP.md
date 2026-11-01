# Roadmap

## Public release

Vigil ships outside the Mac App Store: the App Sandbox would block process scanning, the
hook installers, reading agents' session records and running `git` on arbitrary folders.
The plan is a free, open-source release distributed as a notarized download and a Homebrew
cask. These items gate it.

### Distribution

- [ ] Sign with a Developer ID certificate and notarize each build (`notarytool`), stapling the ticket.
- [ ] Package a DMG and publish it from GitHub Releases or a small site.
- [ ] Publish a Homebrew cask (`brew install --cask vigil`).
- [ ] Add automatic updates with Sparkle (signed appcast).
- [ ] Release workflow in CI: build, sign, notarize, attach the DMG, update the appcast and cask.

### First run and hooks

- [ ] Onboarding that explains what Vigil watches and what hooks are, before anything is installed.
- [ ] Make it clear which files the hook installers change (`~/.claude/settings.json`,
      `~/.hermes/config.yaml`), where backups go, and how to uninstall cleanly.
- [ ] Remove Vigil's hooks when the app is deleted, or document how to.

### Compatibility

- [ ] Test with more agent setups: Claude Code CLI and desktop, Hermes CLI, gateway and desktop,
      Codex, Cursor, Aider, and several agents in one worktree.
- [ ] Test on large repositories and many worktrees for CPU, memory and refresh latency.
- [ ] Decide the minimum macOS version and test on it.

### Cleanup

- [ ] Keep the debug hooks (`VIGIL_DEBUG_*`, `DebugHooks.swift`) out of release builds,
      or gate them behind a build flag.
- [x] Every control has a tooltip and an accessibility label.

### Trust and docs

- [ ] A privacy statement: no network access, no telemetry, what is written to disk and where
      (expanding the README's "Privacy and footprint").
- [ ] Add CONTRIBUTING and a security contact (the code is already MIT licensed).
- [ ] Screenshots and a short demo for the README and release page.
- [ ] A short in-app guide under Help › Vigil Help (⌘?): what Vigil does and how to use it.
      Planned in [docs/plans/help-window.md](docs/plans/help-window.md).

## Later

- [x] Desktop widgets showing the running agents, who needs you, and optionally each task
      ([docs/plans/desktop-widgets.md](docs/plans/desktop-widgets.md)).

- Paid "supporter" build or team features, if there is demand after release.
