# Vigil

A lightweight, native macOS monitor for git worktrees, built for sitting beside a coding agent and answering two questions: *what is it doing right now*, and *should I be worried?*

Vigil is read-only. It never stages, commits, checks out, or takes the repository's `index.lock`, so it can watch any repository while another tool works in it.

> "Vigil" is a working name. Rename it in `Package.swift`, `Resources/Info.plist` and `Scripts/make-app.sh`.

## What it does

- **Watches live.** FSEvents on the worktree and the git directory drive refreshes a few hundred milliseconds after files settle. Rows glow and show "12s ago" for recently touched files, so you can see where the agent is working.
- **Compares against the right baseline.** Agents commit as they go, so a plain working-tree diff goes blank after every commit. Switch between:
  - *Uncommitted*: working tree versus HEAD, including untracked files.
  - *Since branch point*: everything since the branch diverged from the default branch (or from its upstream when you are on the default branch).
  - *Since start*: everything since you pressed **Mark Start**.
  - *Since snapshot*: any earlier snapshot Vigil recorded.
- **Follows every worktree.** Add a repository and Vigil discovers its linked worktrees (for example the ones agent tools create under `.claude/worktrees/`) and watches them all, with per-worktree change and flag counts in the sidebar and the menu bar.
- **Records snapshots.** When the tree changes, Vigil writes a commit object of the whole working tree (untracked files included) under `refs/monitor/<worktree-id>/`. Branches, the index and the working tree are untouched. Snapshots keep the Start marker alive across restarts and let you compare against any earlier moment.
- **Flags what deserves a look.** Lockfiles, `.env` and key material, secret-looking strings in added lines, CI and agent instruction files, `.gitignore` edits, mass deletions, deleted or skipped tests, conflict markers, lint suppressions, debug leftovers, permission changes, huge files and edits outside a scope you define. Each rule can be switched off; thresholds are adjustable.
- **Shows diffs the way you read them.** Unified diff with line numbers, word-level emphasis on the parts of a line that actually changed, wrapping or horizontal scrolling, a copy-as-patch button, and flags that jump to the offending line. ⌘F filters the file list.
- **Keeps an activity feed.** Created, modified, deleted and reverted files, commits, branch switches and new flags, newest first, across one worktree or all of them. Click an entry to jump to the file.
- **Lives in the menu bar.** A glance shows total changed and flagged files; the menu lists every worktree.

## Requirements

- macOS 15 or later.
- A `git` binary. Homebrew or MacPorts git is preferred; the Xcode shim at `/usr/bin/git` is used when the Command Line Tools are installed. A custom path can be set in Settings.
- Xcode 16 or later (Swift 6) to build.

## Build and run

```bash
Scripts/run.sh
```

That builds a debug binary, wraps it in `build/Vigil.app` and opens it. For an optimized build:

```bash
Scripts/make-app.sh release
```

You can also run it straight from SwiftPM (`swift run Vigil`), or open `Package.swift` in Xcode and run the `Vigil` scheme. Notifications only work from the app bundle.

### Try it with a simulated agent

```bash
Scripts/simulate-agent.sh
```

This creates a throwaway repository, prints its path, and then edits, adds, deletes and commits files every few seconds, including a few changes that should be flagged. Add the printed path to Vigil and watch.

### Tests

```bash
swift test
```

The suite covers the parsers, the attention rules and the activity differ, plus integration tests that drive the real `git` binary against temporary repositories.

## How it works

- **VigilCore** (`Sources/VigilCore`) is a UI-free library: a typed git client, parsers for `status --porcelain=v2`, `diff --raw`, `--numstat` and unified patches, an FSEvents wrapper, the attention heuristics, the activity differ, and the `WorktreeInspector` actor.
- **Shadow index.** Each worktree gets a private git index file in `~/Library/Application Support/Vigil/index/`. Every refresh runs `git add -A` against that file (with `GIT_INDEX_FILE`), which mirrors the working tree, honours ignore rules, and never touches the repository's own index. `git diff --cached <baseline>` against the shadow index then yields a complete, rename-aware diff that includes untracked files. Untracked files above a size limit are skipped and listed in the header.
- **No lock contention.** Every git invocation runs with `--no-optional-locks`, so `git status` from Vigil never writes the repository index and never races an agent for `index.lock`.
- **Snapshots** are `commit-tree` objects (parent: current HEAD) referenced from `refs/monitor/<id>/snapshots/<unix-ms>`, plus `refs/monitor/<id>/start` for the Start marker. They show up in `git log --all`, never in `git branch`, and are not pushed by a normal `git push`. Remove them from Settings, or by hand:

  ```bash
  git for-each-ref --format='%(refname)' refs/monitor | xargs -n1 git update-ref -d
  ```

- **Refresh pacing.** File events are debounced (default 400 ms) with a maximum delay (default 2.5 s) so continuous churn still refreshes. Bursts that touch only ignored paths (build output, `node_modules`) are discarded without a refresh. A slow safety poll runs every 45 s as a backstop.

## Debug hooks

Environment variables for driving the app headlessly (handy for development without screen-recording permission):

| Variable | Effect |
|---|---|
| `VIGIL_SCREENSHOT=/path.png` | Write the main window to a PNG after launch |
| `VIGIL_SCREENSHOT_INTERVAL=5` | Rewrite it (and the dump) every 5 seconds |
| `VIGIL_DEBUG_DUMP=/path.txt` | Write a text summary of repositories, sessions, changes and activity |
| `VIGIL_DEBUG_SELECT=src/app.py` | Select that file in the selected worktree once it appears |

Example: `open --env VIGIL_SCREENSHOT=/tmp/vigil.png build/Vigil.app`

## Ideas not built yet

- Side-by-side and word-level diff highlighting.
- A timeline scrubber across snapshots.
- A gated "discard this hunk" escape hatch.
- A local socket that agent hooks can post tool events to, so each change can be attributed to the tool call that made it.
- Per-repository scope presets and notification rules.
