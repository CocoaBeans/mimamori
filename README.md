# Vigil

[![CI](https://github.com/CocoaBeans/vigil/actions/workflows/ci.yml/badge.svg)](https://github.com/CocoaBeans/vigil/actions/workflows/ci.yml)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
[![MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

A small, native macOS app that keeps watch over git worktrees while coding agents work in them. It sits beside Claude Code, Codex, Aider, Cursor or whatever you run, and answers two questions at a glance: **what is it doing right now**, and **should I be worried**.

Vigil is strictly read-only. It never stages, commits, checks out, or takes the repository's `index.lock`, so it can watch any repository while another tool is busy in it.

![Vigil watching a worktree: change list with flags, a diff with word-level emphasis, and the activity feed](docs/vigil-main.png)

## Why

Git clients are built for committing. When an agent is editing on your behalf, you want something closer to a monitor: it should refresh by itself, show you what changed in the last minute, keep showing you the whole session's work even after the agent commits, and point out the handful of changes that deserve a human look before anything ships. Vigil is that monitor.

## What it does

- **Watches live.** FSEvents on the worktree and the git directory drive refreshes a few hundred milliseconds after files settle. Recently touched files glow and say "12s ago", so you can see where the agent is working. Bursts that only touch ignored paths (build output, `node_modules`) are discarded without a refresh.
- **Compares against the right baseline.** Agents commit as they go, so a plain working-tree diff goes blank after each commit. Switch between:
  - *Uncommitted*: working tree versus HEAD, including untracked files.
  - *Since branch point*: everything since the branch diverged from the default branch (or from its upstream when you are on the default branch).
  - *Since start*: everything since you pressed **Mark Start**.
  - *Since snapshot*: any earlier snapshot Vigil recorded.
- **Follows every worktree.** Add a repository and Vigil discovers its linked worktrees (for example the ones agent tools create under `.claude/worktrees/`) and watches them all. Repositories collapse in the sidebar; worktrees you do not care about can be hidden. Stop watching a repository from any of its rows' context menu, the File menu (⌘⌫), or the Delete key.
- **Flags what deserves a look.** Lockfiles, `.env` and key material, secret-looking strings in added lines, CI and agent instruction files, `.gitignore` edits, mass deletions, deleted or skipped tests, conflict markers, lint suppressions, debug leftovers, permission changes, huge files, and edits outside a scope you define. Click the orange count to see every flagged file and why. Every rule can be switched off and thresholds are adjustable.
- **Shows diffs the way you read them.** Unified diff with line numbers, word-level emphasis on the parts of a line that actually changed, wrapping or horizontal scrolling, copy as a patch, and flags that jump to the offending line. ⌘F filters the file list.
- **Remembers what you have reviewed.** Mark a file reviewed (⌘↩ marks it and moves to the next one) and it dims in the list; hide reviewed files to see only what is left. A mark covers the content you saw, so when an agent edits the file again it comes back as *changed since your review*, and the diff can show just the edits made after you looked. The sidebar counts what is left to review in each worktree.
- **Records snapshots.** When the tree changes, Vigil writes a commit object of the whole working tree (untracked files included) under `refs/monitor/<worktree-id>/`. Branches, the index and the working tree are untouched. Snapshots keep the Start marker alive across restarts and let you compare against any earlier moment.
- **Keeps an activity feed.** Created, modified, deleted and reverted files, commits, branch switches and new flags, newest first, for one worktree or all of them. Click an entry to jump to the file.
- **Knows where the agents are.** Vigil scans for agent processes (Claude Code, Codex, Aider, Cursor, Gemini, Goose, OpenCode, Amp, or names you add) and shows which worktree each one is working in. With Claude Code hooks installed (Settings › Agents, one click, reversible) it also knows exactly what the agent is doing: when a turn starts and ends, each tool call, and when it is waiting for your permission or input. File changes are attributed to the tool call that made them, worktrees that need you are counted in the sidebar and the menu bar, and you can be notified when an agent needs permission.
- **Lives in the menu bar.** A glance shows total changed and flagged files, and how many agents are waiting for you; the menu lists every repository and worktree.


## Requirements

- macOS 15 or later (developed on macOS 26).
- A `git` binary. Homebrew or MacPorts git is preferred; the Xcode shim at `/usr/bin/git` works when the Command Line Tools are installed. A custom path can be set in Settings.
- Xcode 16 or later (Swift 6) to build from source.

## Install

Until signed releases exist, build it yourself. It takes about a minute:

```bash
git clone https://github.com/CocoaBeans/vigil.git
cd vigil
Scripts/make-app.sh release
open build/Vigil.app
```

Or `Scripts/run.sh` for a debug build that opens immediately. You can also run `swift run Vigil`, or open `Package.swift` in Xcode and run the `Vigil` scheme. Notifications only work from the app bundle.

The locally built app is ad-hoc signed. The first launch may ask you to confirm in System Settings › Privacy & Security, or you can right-click the app and choose Open.

### Try it with a simulated agent

```bash
Scripts/simulate-agent.sh
```

This creates a throwaway repository, prints its path, and then edits, adds, deletes and commits files every few seconds, including a few changes that should be flagged. Add the printed path to Vigil and watch.

## How it works

- **VigilCore** (`Sources/VigilCore`) is a UI-free library: a typed git client, parsers for `status --porcelain=v2`, `diff --raw`, `--numstat` and unified patches, an FSEvents wrapper, the attention heuristics, an intraline diff, the activity differ, and the `WorktreeInspector` actor. The SwiftUI app in `Sources/Vigil` is a thin shell over it.
- **Shadow index.** Each worktree gets a private git index file in `~/Library/Application Support/Vigil/index/`. Every refresh runs `git add -A` against that file (with `GIT_INDEX_FILE`), which mirrors the working tree, honours ignore rules, and never touches the repository's own index. `git diff --cached <baseline>` against the shadow index then yields a complete, rename-aware diff that includes untracked files. Untracked files above a size limit are skipped and listed in the header.
- **No lock contention.** Every git invocation runs with `--no-optional-locks`, so `git status` from Vigil never writes the repository index and never races an agent for `index.lock`.
- **Snapshots** are `commit-tree` objects (parent: current HEAD) referenced from `refs/monitor/<id>/snapshots/<unix-ms>`, plus `refs/monitor/<id>/start` for the Start marker. They show up in `git log --all`, never in `git branch`, and are not pushed by a normal `git push`. Remove them from Settings, or by hand:

  ```bash
  git for-each-ref --format='%(refname)' refs/monitor | xargs -n1 git update-ref -d
  ```

- **Review marks** record, per file, the blob you saw (from the shadow index). Comparing that against the current blob tells reviewed, unreviewed and changed-since-review apart, and `git diff <reviewed blob> <current blob>` gives the since-review diff. Marks live with the worktree's settings in `state.json`; blobs nothing else references are eventually pruned by `git gc`, after which only the full diff is available.
- **Refresh pacing.** File events are debounced (default 400 ms) with a maximum delay (default 2.5 s) so continuous churn still refreshes. A quiet, staggered backstop poll runs every 45 s per worktree.

## Agents and hooks

Without any setup, Vigil detects agent processes by their working directory and shows them on the worktree they sit in. That tells you an agent is there and whether it is busy, nothing more.

Hooks tell Vigil what the agent is doing. **Settings › Agents › Install Hooks** adds entries to `~/.claude/settings.json` for Claude Code's `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Notification`, `Stop`, `SubagentStop` and `SessionEnd` events. Each entry runs:

```bash
curl -s -m 1 -H 'Expect:' -H 'Content-Type: application/json' \
  --unix-socket "$HOME/Library/Application Support/Vigil/vigil.sock" \
  --data-binary @- http://vigil/event >/dev/null 2>&1 || true
```

A timestamped backup of the settings file is written first, hooks you already have are kept, and **Uninstall Hooks** removes only Vigil's entries. When Vigil is not running the command fails silently in under a second, so agents are never slowed down. Events are kept in memory only; nothing is written to disk and nothing leaves the machine. **Hermes Agent** is supported the same way. **Install Hermes Hooks** writes a small script to `~/.hermes/agent-hooks/vigil.sh` and appends a delimited `hooks:` block to `~/.hermes/config.yaml` (backup first). If your config already has a `hooks:` key, Vigil copies the entries to the clipboard for you to paste instead. Hermes asks for consent once per event the first time a hook runs. Events arrive on `http://vigil/event/hermes` and are translated from Hermes's names (`pre_tool_call`, `pre_approval_request`, `on_human_input_request`, `pre_verify`, …).

Other agents with a hook mechanism can post the Claude Code JSON shape (`hook_event_name`, `cwd`, `tool_name`, `tool_input`, …) to `http://vigil/event`.

## Privacy and footprint

Vigil talks to nothing but your local `git`. It has no network code beyond a Unix-domain socket that only local processes can reach, and no telemetry. On disk it writes:

- `~/Library/Application Support/Vigil/`: settings, the list of watched repositories, and the shadow index files.
- `refs/monitor/…` inside watched repositories, for snapshots (see above).
- `~/.claude/settings.json`, only when you click Install Hooks, with a backup beside it.

## Development

```bash
swift build          # build
swift test           # parsers, rules, differ, plus integration tests against real git
Scripts/make-app.sh  # wrap the binary in build/Vigil.app (debug|release)
```

### App icon

The icon is an emoji rendered onto a macOS-style rounded background by `Scripts/make-icon.swift`. Change it with any emoji and rebuild:

```bash
swift Scripts/make-icon.swift "🕯️"
```

### Debug hooks

Environment variables for driving the app headlessly, useful on machines without screen-recording permission:

| Variable | Effect |
|---|---|
| `VIGIL_SCREENSHOT=/path.png` | Write the main window (and any popover) to PNG after launch |
| `VIGIL_SCREENSHOT_INTERVAL=5` | Rewrite it (and the dump) every 5 seconds |
| `VIGIL_DEBUG_DUMP=/path.txt` | Write a text summary of repositories, sessions, changes and activity |
| `VIGIL_DEBUG_SELECT=src/app.py` | Select that file in the selected worktree once it appears |
| `VIGIL_DEBUG_REVIEW=README.md,src/app.py` | Mark those files in the selected worktree reviewed once they appear |
| `VIGIL_WINDOW=1000x640` | Resize the main window after launch (clamped to the content minimum) |
| `VIGIL_DEBUG_FLAGS=popover:sidebar,cycle` | Open the attention popover; cycle the selection through all worktrees; `toggle-review` presses ⌘↩ once on the selected file |
| `VIGIL_SUPPORT_DIR=/tmp/vigil-scratch` | Keep state, shadow indexes and the hook socket in that folder, leaving your real setup alone |

Example: `open --env VIGIL_SCREENSHOT=/tmp/vigil.png build/Vigil.app`

### Releasing

`Scripts/release.sh` builds, signs with a Developer ID certificate, notarizes with `notarytool` and staples the ticket. It needs the certificate in the login keychain and an App Store Connect API key passed as `ASC_KEY_ID` and `ASC_ISSUER_ID` (the key file is read from `~/.appstoreconnect/private_keys/`).

## Ideas not built yet

- A read-only transcript adapter for agents without hooks installed.
- Side-by-side diffs and syntax highlighting.
- A timeline scrubber across snapshots.
- A gated "discard this hunk" escape hatch.

## Contributing

Issues and pull requests are welcome. Keep `VigilCore` free of UI, add a test when you touch a parser or a rule, and run `swift test` before opening a pull request.

## License

[MIT](LICENSE)
