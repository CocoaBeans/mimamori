# Plan: a simple Help window

## Goal

A short, friendly guide inside Mimamori that says what it does and how to use it. It opens from
**Help › Mimamori Help** (⌘?). Today that menu item only says help isn't available, which a new
user is likely to find in their first few minutes, so it ships before 1.0.

This isn't a manual. Each topic is about a screenful and takes a minute to read. The README stays
the reference for developers. The welcome window stays the place to set up: Help explains, and
points back to it for connecting agents.

## Approach

- **A Help window.** A SwiftUI `Window("Mimamori Help", id: "help")` with a list of topics on the
  left and the chosen topic on the right. Like the summary window, it can be moved and resized
  and kept beside your work.
- **The Help menu.** `CommandGroup(replacing: .help)` puts Mimamori Help (⌘?) first, in place of
  the default command, followed by the items already there:
  - Welcome to Mimamori;
  - Troubleshoot Agent Hooks… and Copy Diagnostics;
  - Mimamori on GitHub.
- **Rendering.** Reuse `MarkdownPreview` from the session summary. It already draws headings,
  bullets, notes and code, in light and dark mode. Write the topics in what it supports, using
  bullets rather than tables. Its one change: paragraphs in the primary colour, since the
  summary dims its own as asides.
- **Where the text lives.** One Swift file, `Sources/Mimamori/Help/HelpTopics.swift`, holds the
  topics (title, SF Symbol, Markdown) as string literals.
  - No resource bundle, which would need `Bundle.module` and extra copying in
    `Scripts/make-app.sh`. The Xcode project's synchronized folders pick the file up by
    themselves.
  - `swift run` and the app bundle show the same thing.
  - Editing a topic is editing a string.

Not chosen:
- **An Apple Help Book.** It needs a `.help` bundle, `hiutil` indexing, Info.plist keys and the
  slow Help Viewer: too much for a few pages.
- **A link to the README on GitHub.** It needs a network connection, and the README is written
  for developers.

## Topics

Each topic is short, plain and task-first. Settings and menu items are named exactly as they
appear. Examples use made-up repositories and branches (`acme-store`, `feature/login`), never
real ones.

1. **Getting started.**
   - What Mimamori is: it watches your git worktrees while coding agents work in them, and shows
     what changed, what needs a look and what each agent is doing. It never changes your code,
     branches or index.
   - Add Repository (⌘O), or drop a folder on the sidebar or the Dock icon; its worktrees appear
     in the sidebar.
   - The sidebar: repository icons and colours, hiding worktrees, the agents-only filter.
   - The window: changes, diff and activity.
   - Help › Welcome to Mimamori, to connect agents.
2. **Reviewing changes.**
   - Baselines: Uncommitted (⌘1), Since branch point (⌘2), Since start (⌘3, with Mark Start) and
     Since snapshot.
   - What the file list shows: the glow on recent edits, the diff bars.
   - Marking a file reviewed (⌘↩), the To review filter (⌥⌘R), and "changed since your review".
   - The diff: side by side (⌥⌘L), wrapping, the strip beside long diffs, filtering by name (⌘F).
3. **What needs attention.**
   - What gets flagged (secrets, lockfiles, mass deletions, skipped tests…) and why.
   - The orange count and its popover; flagged lines in the diff.
   - Tuning the rules in Settings › Attention.
4. **Commits and conflicts.**
   - The Commits list (⇧⌘H): opening a commit, its files and diffs.
   - The banner for a merge, rebase, cherry-pick or revert in progress.
   - Conflicted files (U) and how the diff draws the two sides: current in blue, incoming in
     purple, the common ancestor in grey.
5. **Agents.**
   - What shows with no setup: agent processes, and the worktree each works in.
   - What hooks add, and connecting them (Claude Code and Hermes in a click; others in
     Settings › Agents).
   - The toolbar pill, the banner and the Agents window (⇧⌘A): sections, the turn timeline,
     Go to agent.
   - Answering permission requests, in Mimamori or in the agent's own prompt.
   - Notifications, and several agents in one worktree.
6. **Menu bar and widgets.**
   - The menu bar icon and its popover; pinning it as a floating window.
   - The desktop widgets.
7. **Activity and summaries.**
   - The activity feed: what it records, its filter, how long it keeps entries
     (Settings › General), Show Earlier Activity.
   - The session summary (⇧⌘E): what's in it, the Include options, Copy Markdown and Save.
8. **Snapshots.**
   - What a snapshot is (a commit under `refs/monitor/`, never a branch), and the Start marker.
   - Settings › Snapshots: how often, how many are kept, disk space, deleting them.
9. **Keyboard shortcuts.** A bulleted list of every menu shortcut, checked against the menus.
10. **Privacy and uninstalling.**
    - What Mimamori reads, and what it writes and where.
    - That nothing leaves your Mac, except the update check, and when it happens.
    - Removing hooks in Settings › Agents › Hooks, the backups kept, and Mimamori › Uninstall
      Mimamori….
11. **Troubleshooting.**
    - Help › Troubleshoot Agent Hooks…: what became of each event, and a test event.
    - "No hooks installed", and Hermes hooks waiting for approval.
    - git not found.
    - An agent shown only as "Agent": add `?agent=` to its hook.
    - Copy Diagnostics, for a bug report.

## Keeping it accurate

- A comment at the top of `HelpTopics.swift` says to update it with any change that adds or
  renames a feature, menu item, shortcut or setting.
- A `MIMAMORI_DEBUG_FLAGS=help:<topic>` flag (`help` alone opens the first topic) opens the Help
  window on a topic, so headless runs can screenshot each one. `appearance:light` and `appearance:dark` draw it
  either way, whatever the system's setting.

## Steps

One small PR:

1. Write `HelpTopics.swift` following the outline above, checking each name and shortcut
   against the app.
2. Add the `HelpWindow` view: a `NavigationSplitView` with a topic list and a scrolling
   `MarkdownPreview`. Add its `Window` scene and the Help menu above.
3. Give the topic list accessible names and tooltips, and select Getting started by default.
4. Link to it from the empty window ("Mimamori Help") beside the existing welcome link.
5. Add the debug flag and screenshot every topic in light and dark mode, for a read-through of
   the wording before merging.
6. Add a README line pointing to Help › Mimamori Help, and tick the roadmap item.

## Later, if wanted

- **"?" buttons** in each Settings pane that open the matching topic. That means keying the
  window by topic (`WindowGroup(for: HelpTopic.ID.self)`) or keeping the selected topic on the
  model.
- **Search.** A filter field over the topics, once there are enough to need one.
