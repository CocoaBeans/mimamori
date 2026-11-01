# Plan: desktop widgets

## Goal

See your agents at a glance on the desktop, or in Notification Center, without opening Vigil:
- which worktrees have an agent;
- what each agent is doing;
- who needs you.

Showing the task and recent steps is optional. Clicking an agent opens Vigil on its worktree.

## The widgets

One widget kind, **Agents**, in each size macOS offers. Every row is tinted by the agent's state,
with the same colors and symbols as the app: orange for needs you, blue for working, green for
ready.

- **Small:** the most pressing agent:
  - its name and worktree;
  - its state, and how long it has been in it ("waiting 2m");
  - a count of the others below.

  When nothing needs you, it shows "3 working · 1 ready".
- **Medium:** up to four agents, a row each: symbol, `repository · worktree`, status, and time in
  that state.
- **Large:** up to four agents, each with its task (the prompt behind the turn) and its last two
  steps ("Edit Sources/App.swift", "Bash swift test"). A collision shows its warning line.
- **Extra large** (desktop only): two columns and up to eight agents, with tasks and steps.

Each widget can be configured (an `AppIntentConfiguration`):
- **Show tasks and steps:** on by default for the large sizes.
- **Only agents that need me.**
- **Repository:** all of them, or one.

## How data gets to the widget

Widgets run in their own sandboxed process. They can't reach Vigil's socket or its state, so
Vigil hands them a snapshot:

1. **Vigil writes a snapshot.** It writes `widgets.json` into a shared App Group container
   whenever what the widgets show changes:
   - immediately when an agent starts or stops needing you;
   - otherwise at most every 5 seconds.

   Then it asks WidgetKit to reload (`WidgetCenter.shared.reloadTimelines(ofKind:)`).
2. **What the snapshot holds.** Only what a widget shows:
   - when it was written;
   - for each agent: worktree path, repository and worktree names, agent name, state, status
     text, since when, task, the last few steps, and any collision line.

   It's a small `Codable` type shared by the app and the extension. It could live in VigilCore,
   which has no SwiftUI, or in a tiny shared module of its own.
3. **The widget reads it.** Its timeline provider reads the snapshot and returns a single entry.
   "Waiting 2m" and similar times use `Text(date, style: .relative)` and tick without reloads.
4. **A stale snapshot says so.** If the snapshot is older than a few minutes and Vigil isn't
   running, the widget shows "Vigil isn't running" instead of stale states. The provider also
   schedules its own reload every 15 minutes to notice this.

**Privacy:** tasks can be sensitive and the desktop is visible to anyone nearby. A
Settings › Agents option, "Show tasks in widgets", controls whether tasks and steps are written to
the snapshot at all.

## Clicking through

- **Open in Vigil.** Each row links to `vigil://worktree?path=…` (`Link` and `widgetURL`).
  - Vigil registers the `vigil` URL scheme (`CFBundleURLTypes`).
  - It handles the link with `.onOpenURL`, selecting that worktree, or opening its summary with
    `vigil://summary?path=…`.
- **Later:** a "Go to agent" button using an App Intent (macOS 14+), which brings the agent's app
  to the front the way the banner's button does. The intent has to run in Vigil's own process.

## Packaging and signing (most of the work)

- **A widget is an app extension.** It's a sandboxed `.appex` in `Vigil.app/Contents/PlugIns`,
  with extension point `com.apple.widgetkit-extension`.
- **SwiftPM can't build one.** Vigil is built with Swift Package Manager and `Scripts/make-app.sh`.
  - **Recommended:** an Xcode project. Either one just for the extension, or, better, one for the
    whole app.
    - `make-app.sh` and CI then call `xcodebuild`.
    - The same project is what Developer ID signing, notarization and Sparkle (all in the
      roadmap) want anyway.
  - **Not recommended:** compiling the extension with `swiftc`, assembling the bundle and its
    Info.plist by hand, and signing it. Possible, but fragile.
- **Shared data needs an App Group.** Both the app and the extension need the App Group
  entitlement. Use the team-prefixed form, `555LXJXR4U.com.kevinross.Vigil`, which works with Developer ID
  signing without a provisioning profile; check this in the spike below.
  - The extension is sandboxed (`com.apple.security.app-sandbox`).
  - The app stays unsandboxed, and reaches the container with
    `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`.
- **Real signing.** Today's builds are ad-hoc signed, and macOS may refuse to load a widget
  extension signed that way. Widgets will need signing with your team, which ties this to the
  roadmap's Developer ID item. CI can keep an unsigned build that leaves the extension out.

## Limits to design around

- **Not live.** WidgetKit decides when a reload actually happens, and limits frequent ones. Expect
  updates within seconds while Vigil runs, with no guarantee; times keep ticking on their own.
- **No scrolling**, and only buttons and links for interaction.
- **Display modes.** Desktop widgets fade into the wallpaper when another app is in front, and are
  drawn in a tinted mode. Use `widgetRenderingMode` and `widgetAccentable`, and check each size in
  full color and tinted.

## Steps

1. **Spike, about half a day.** A shell Xcode project with the app and a widget extension, built
   by `xcodebuild` from `make-app.sh` and signed with your team. A static widget on the desktop.
   This settles:
   - how packaging and signing work;
   - the App Group id;
   - that the unsandboxed app can write to the shared container.
2. **Data.** The snapshot type, the app writing it (throttled, plus reload requests) and the
   widget reading it. Small and medium views.
3. **Details.** Large and extra-large views with tasks and steps, the per-widget configuration,
   and "Vigil isn't running".
4. **Links.** The `vigil://` scheme and opening worktrees and summaries from a widget.
5. **Finishing.**
   - The "Show tasks in widgets" setting.
   - Previews for every size and mode, and screenshots from them.
   - A README section.
   - CI building the extension.

## To decide first

- An Xcode project for the extension only, or for the whole app.
- The Team ID and App Group id to use.
- Whether tasks show in widgets by default.
