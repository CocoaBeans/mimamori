# Plan: a simple Help window

## Goal

A short, friendly guide inside Mimamori that says what it does and how to use it. It opens from
**Help › Mimamori Help** (⌘?). Today that menu item only says help isn't available.

This isn't a manual. Each topic is about a screenful and takes a minute to read. The README stays
the reference for developers.

## Approach

- **A Help window.** A SwiftUI `Window("Mimamori Help", id: "help")` with a list of topics on the
  left and the chosen topic on the right. It opens from Help › Mimamori Help (⌘?), which replaces
  the default help command (`CommandGroup(replacing: .help)`). Like the summary window, it can be
  moved and resized and kept beside your work.
- **Rendering.** Reuse `MarkdownPreview` from the session summary. It already draws headings,
  bullets, notes and code, in light and dark mode. Write the topics in what it supports, using
  bullets rather than tables, so it needs no changes.
- **Where the text lives.** One Swift file, `Sources/Mimamori/Help/HelpTopics.swift`, holds the
  topics (title, SF Symbol, Markdown) as string literals.
  - No resource bundle, which would need `Bundle.module` and extra copying in
    `Scripts/make-app.sh`.
  - `swift run` and the app bundle show the same thing.
  - Editing a topic is editing a string.

Not chosen:
- **An Apple Help Book.** It needs a `.help` bundle, `hiutil` indexing, Info.plist keys and the
  slow Help Viewer: too much for a few pages.
- **A link to the README on GitHub.** It needs a network connection and a public repository, and
  the README is written for developers.

## Topics

Each topic is short, plain and task-first. Settings and menu items are named exactly as they
appear.

1. **Welcome.** Mimamori watches your git worktrees while coding agents work in them. It shows:
   - what changed;
   - what needs a look;
   - what each agent is doing.

   It never touches your branches, index or working tree.
2. **Getting started.**
   - Add Repository (⌘O); its worktrees appear in the sidebar.
   - The three columns: changes, diff and activity.
   - The menu bar icon.
3. **Reviewing changes.**
   - Baselines: Uncommitted, Branch point, Since start, Since snapshot.
   - Marking a file reviewed (⌘↩).
   - The To review filter and filtering by name.
   - The diff view's options: side by side and wrap.
4. **What needs attention.**
   - What gets flagged (secrets, dependency lists, large deletions…) and why.
   - The attention popover.
   - Tuning the rules in Settings › Attention.
5. **Commits.** The Commits list, opening a commit, and its files and diffs.
6. **Agents.**
   - What shows with no setup: agent processes.
   - Installing hooks for Claude Code and Hermes.
   - Connecting other agents (Settings › Agents › Other agents).
   - The banner, the Agents window (⇧⌘A) and notifications.
   - When several agents share a worktree.
7. **Session summary.**
   - Opening it (⇧⌘E), what's in it, and the Include options.
   - Copy Markdown and Save.
   - It keeps itself up to date in its own window.
8. **Snapshots.**
   - What a snapshot is, and the Start marker.
   - The Disk space row, and deleting snapshots.
9. **Keyboard shortcuts.** A bulleted list of every menu shortcut.
10. **Privacy.**
    - What Mimamori reads.
    - What it writes, and where.
    - That nothing leaves your Mac.
11. **Troubleshooting.**
    - "No hooks installed".
    - Hermes hooks waiting for approval.
    - git not found.
    - An agent shown only as "Agent": add `?agent=` to its hook.
    - A summary marked out of date.

## Keeping it accurate

- A comment at the top of `HelpTopics.swift` says to update it with any change that adds or
  renames a feature, menu item, shortcut or setting.
- A `MIMAMORI_DEBUG_FLAGS=help:<topic>` flag opens the Help window on a topic, so headless runs can
  screenshot each one.

## Steps

One small PR, a few hours of work:

1. Write `HelpTopics.swift` following the outline above.
2. Add the `HelpWindow` view: a `NavigationSplitView` with a topic list and a scrolling
   `MarkdownPreview`. Add its `Window` scene and the Help › Mimamori Help (⌘?) command.
3. Give the topic list accessible names and tooltips, and select Welcome by default.
4. Add the debug flag and screenshot every topic in light and dark mode.
5. Add a README line pointing to Help › Mimamori Help.

## Later, if wanted

- **"?" buttons** in each Settings pane that open the matching topic. That means keying the
  window by topic (`WindowGroup(for: HelpTopic.ID.self)`) or keeping the selected topic on the
  model.
- **Search.** A filter field over the topics, once there are enough to need one.
- **Onboarding.** The Welcome and Getting started topics could double as the first-run screen in
  the roadmap.
