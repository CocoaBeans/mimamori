# Plan: rename Vigil to Mimamori

## Why

"Vigil" comes from the Latin for wakefulness, and "keep vigil" means to stay up and watch. But
its commonest modern sense is a candlelight vigil for the dead, so "a vigil for your code" reads
as mourning it, and the flame icon leans that way. The name is also taken in exactly this niche:
an open-source monitoring tool (valeriansaliou/vigil, about 1.9k stars), a macOS menu-bar app for
AI coding agents (botus-ai/vigil), a macOS terminal that oversees Claude Code and Codex (on
Product Hunt), and a pull-request agent tool (hyperb1iss/vigil).

**Mimamori** (見守り) is Japanese for watching over someone with care: 見 to see, 守る to protect.
It is the word for watching children at play, or the volunteers who see children safely to
school. That is the app's relationship with agents: let them work, keep an eye out, step in when
one needs you. No developer tool or macOS app by that name turned up.

Renaming is cheap now, with one user, and breaks everyone's hooks after a public release, so it
comes before anything else on the release checklist.

## Decisions first

1. **Names.** "Mimamori" where people read it; `mimamori` in identifiers and files. The README
   opens with a line on the word and how to say it (mee-mah-MOH-ree).
2. **Identifiers.** Bundle IDs `com.kevinross.Mimamori`, `.Core` and `.Widgets`; App Group
   `555LXJXR4U.com.kevinross.Mimamori` (team-prefixed, so it needs no registration); URL scheme
   `mimamori://`.
3. **Modules and folders.** `Mimamori` (app), `MimamoriCore`, `MimamoriWidgets`,
   `MimamoriCoreTests`; `WidgetUI` keeps its name.
4. **Debug variables.** `MIMAMORI_*` in place of `VIGIL_*`. They are for development only, so
   no aliases for the old names.
5. **The repository.** Rename `CocoaBeans/vigil` to `CocoaBeans/mimamori` (GitHub redirects old
   links and clones), or, if Mimamori goes public as a fresh repository, create that one as
   `mimamori` and keep this one private.
6. **The icon.** The flame suits "vigil" more than "mimamori". A paper lantern (chōchin) over the
   branches, or a gentle watching eye, would carry the same light in the dark. This does not
   block the rename; it can follow.

## What changes in the repository

The name appears about 600 times in 92 files. Most of it is mechanical:

- **Modules, folders, targets.** `Sources/Vigil` → `Sources/Mimamori`, `VigilCore` →
  `MimamoriCore`, `VigilWidgets` → `MimamoriWidgets`, the tests likewise; every
  `import VigilCore`; `Package.swift`; the Xcode project's targets, products, synchronized
  folders, Info.plist and entitlements paths, and its scheme; types such as `VigilApp`.
- **Identifiers.** Bundle IDs and the App Group in `Resources/`, the project and
  `AgentWidgetSnapshot.appGroup`; the URL scheme in Info.plist and `AgentWidgetSnapshot`'s links;
  dispatch queue labels.
- **Names on disk and in other apps' config.** These need the migration below:
  - the settings folder, `~/Library/Application Support/Vigil`;
  - the socket, `vigil.sock`, and the hook commands' URL, `http://vigil/event`;
  - Claude Code's marker for our hooks (`ClaudeHooksConfig.marker`, `vigil.sock`);
  - Hermes's config block markers (`# --- Vigil hooks …`) and its script, `agent-hooks/vigil.sh`;
  - the setups for other agents (`AgentHookRecipe`), and backup suffixes, `.vigil-backup`.
- **Debug variables.** `VIGIL_SUPPORT_DIR`, `VIGIL_DEBUG_FLAGS`, `VIGIL_SCREENSHOT` and the rest,
  in `DebugHooks`, `AppSettings`, `AgentsWindow`, the README and CONTRIBUTING.
- **Words.** Menu items ("Open Vigil", "Quit Vigil"), the welcome screen, Settings text, tooltips,
  log prefixes; the README, CONTRIBUTING, ROADMAP and the living plans (finished plans stay as
  they were written).
- **Scripts and CI.** `build/Vigil.app` → `build/Mimamori.app` in `make-app.sh`, with its
  `lsregister` lines; the iconset folder in `make-icon.swift`; `release.sh`'s archive name;
  `simulate-agent.sh`'s temporary folder; the CI scheme and artifact names.
- **Tests** that check hook commands or paths with the name in them.
- **A guard against stragglers:** a test that fails if "vigil" appears anywhere in the sources
  except the migration's list of old names.

Snapshot refs are stored under `refs/monitor/` in each repository, which has no name in it, so
existing snapshots carry over untouched.

## Migration, once, on the first launch of Mimamori

Vigil's footprint on this Mac today: a 15 MB settings folder (state, activity log, shadow
indexes, socket); 13 hook entries in Claude Code's settings; a block, a script and 11 approvals
for Hermes; the widget's data in the App Group container. No other agent's config points at
Vigil, and there is no login item, keychain item or user defaults.

1. **Settings folder.** When `~/Library/Application Support/Mimamori` does not exist and
   `…/Vigil` does, move it across in one rename (same volume, so it is atomic), then delete the
   stale `vigil.sock`. Repositories, reviews, settings and the activity log carry over.
2. **Claude Code hooks.** Treat commands with the old marker as ours: replace them with
   Mimamori's, after saving a backup, as the installer already does when a newer version
   listens to more events. Log it, and say so in Settings › Agents › Hooks.
3. **Hermes.** Recognise the old block and script: rewrite the block, write `mimamori.sh`, and
   delete `vigil.sh`, backup first. Hermes approves hooks by their exact command, so the new
   ones need `hermes --accept-hooks` once; the Hooks pane already shows hooks waiting for
   approval, with the command to copy.
4. **Other agents' setups.** None on this Mac. Anyone else re-copies the setup from Settings ›
   Agents › Other Agents. Hooks still pointing at the old socket fail quietly in under a second,
   so nothing breaks, they just stop reporting.
5. **The desktop widget** belongs to the old extension. Remove it, add Mimamori's from Edit
   Widgets, and delete the old App Group container.
6. **Notifications.** A new bundle ID asks for permission again.
7. **The old app.** Unregister and delete `build/Vigil.app`, so its widget extension does not
   linger in the widget gallery.

The migration code lists the old names in one place and is tested against copies of real
configs: a Claude `settings.json` with 13 Vigil hooks and a user hook of its own, and a Hermes
`config.yaml` with the Vigil block among comments. A scratch run (`MIMAMORI_SUPPORT_DIR`,
`CLAUDE_CONFIG_DIR`, `HERMES_HOME`) with a fake old settings folder checks the whole first
launch, without touching the real configs.

## Order of work

1. Settle the decisions above.
2. One pull request: the mechanical rename, identifiers, words, migration and its tests, and the
   guard test. `swift test`, an Xcode build, and the scratch first-launch run.
3. Merge. Build `build/Mimamori.app`, quit Vigil, launch Mimamori: check the folder moved, Claude
   Code's events arrive, Hermes asks for approval, and the widget can be added. Then remove
   `build/Vigil.app`.
4. Rename the GitHub repository and point the local remote at it.
5. Later, separately: the icon, and a fresh README screenshot. The screenshot is a real screen
   capture (⌘⇧4, then Space, for one window), since the app's own captures flatten glass and
   vibrancy: a demo copy runs with sample repositories and test agents, so no real project shows.

## Risks

- **A missed occurrence:** the guard test catches it.
- **Losing state in the move:** the folder moves in one step and only when the new one does not
  exist; `state.json` is copied aside first.
- **Hooks:** every edit makes a backup first, and only our own entries change.
- **Hermes skips the new hooks until approved:** the Hooks pane says so, with the command.
- **Both apps open at once during the switch:** they use different sockets and folders, so they
  do not collide; the widget follows whichever was last launched.
