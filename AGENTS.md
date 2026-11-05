# Working on Mimamori

Notes for coding agents (and people) changing this repository. [CONTRIBUTING](CONTRIBUTING.md)
covers how the code is laid out and what a pull request needs; this adds what tends to trip up an
agent working here, often alongside other sessions.

## Build and test

- `swift test` runs `MimamoriCore`'s tests (Swift Testing), in a few minutes. Run it before every
  pull request.
- To build the app, run `xcodebuild -project Mimamori.xcodeproj -scheme Mimamori -configuration Debug -derivedDataPath <a folder of your own> -quiet build`.
  A DerivedData folder of your own keeps you out of other builds running at the same time.
- `Scripts/make-app.sh` builds `build/Mimamori.app`, the copy the maintainer runs. Run it only when
  the task is to rebuild that copy. `MIMAMORI_SIGN=adhoc` signs without the project's team.
- **CI compiles with Xcode 16.4 and Swift 6.1**, older than a current Mac's toolchain. Code that
  builds locally can fail there:
  - long expressions built from many `+` or chained calls fail with "unable to type-check this
    expression in reasonable time";
  - generic results that aren't `Sendable` fail when they cross an actor.

  Break long expressions into steps, and wait for the pull request's **Build and test** check.
- A Swift file added under `Sources/Mimamori` or `Sources/MimamoriCore` joins the build by itself
  (folder-synchronized groups), with no project edit.

## Conventions

- `MimamoriCore` stays free of UI, and changes to a parser, a rule or the agent status machine come
  with tests.
- Comments are short, plain sentences that say why, matching the code around them.
- Every control has a tooltip (`.help`) and an accessibility label.
- When behaviour changes, update what describes it: the README, and Help in
  `Sources/Mimamori/Help/HelpTopics.swift`.
- A change people using Mimamori would notice adds a line under *Unreleased* in
  [CHANGELOG.md](CHANGELOG.md), with its pull request's link.

## Working alongside other sessions

- One change per branch and pull request, each in a git worktree of its own.
- The main checkout belongs to the maintainer, and the app they run is built there. Don't switch
  its branch, commit in it, or rebuild `build/Mimamori.app` unless that is your task.
- Before replacing anything shared, check it hasn't changed since you looked: a release asset, a
  tag, a branch someone else pushed. Another session may be on the same job.

## Trying the app without touching real state

- Point `MIMAMORI_SUPPORT_DIR`, `CLAUDE_CONFIG_DIR` and `HERMES_HOME` at scratch folders with short
  paths, since the hook socket's path must stay under 104 bytes. Use a scratch repository.
- Never change the real `~/.claude/settings.json` or Hermes config, and never point a test copy at
  real repositories.
- Copies share a bundle ID and the widgets' App Group, so quit the running Mimamori before starting
  a test copy. Afterwards:
  - unregister your copies with `lsregister -u`;
  - re-register the maintainer's `build/Mimamori.app` with `lsregister -f`;
  - open it again.
- Debug builds take `MIMAMORI_DEBUG_FLAGS` (the README's *Debug hooks* lists them), such as
  `appearance:dark`, `diff-line:<n>` and `note-line:<n>`.
- `Scripts/capture-window.sh shot --app com.kevinross.Mimamori --title <window title> --out <png>`
  captures a window as it looks on screen.

## Git, merging and releases

- Commit with a GitHub noreply address. Personal addresses stay out of this public history.
- The maintainer merges by rebasing onto `main` and fast-forwarding, never with GitHub's merge
  button, and only once the pull request's checks pass. Don't merge, tag or publish without their
  word.
- Releases follow the README's *Releasing* section:
  - `Scripts/set-version.sh`;
  - the notes in `docs/releases/<version>.md`;
  - the version's section in `CHANGELOG.md`;
  - then `Scripts/release.sh`.
