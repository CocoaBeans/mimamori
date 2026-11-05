import Foundation

/// One page of Help › Mimamori Help.
///
/// Keep these in step with the app: a change that adds or renames a feature, menu item, shortcut
/// or setting updates the topic that mentions it. The text is what `MarkdownPreview` draws: one
/// line per paragraph or bullet, `##` for a heading, `_…_` for a note, and `[text](help:<id>)`
/// for a link to another topic. Examples name made-up repositories and branches only.
struct HelpTopic: Identifiable {
    enum ID: String, CaseIterable {
        case gettingStarted = "getting-started"
        case reviewing
        case attention
        case commits
        case agents
        case menuBar = "menu-bar"
        case activity
        case snapshots
        case shortcuts
        case privacy
        case troubleshooting
    }

    let id: ID
    let title: String
    let symbol: String
    /// One line under the title, and the topic's tooltip in the list.
    let summary: String
    let actions: [HelpAction]
    let markdown: String

    static func topic(_ id: ID) -> HelpTopic {
        all.first { $0.id == id }!
    }

    static let all: [HelpTopic] = [
        HelpTopic(
            id: .gettingStarted, title: "Getting started", symbol: "hand.wave",
            summary: "Watch your first repository and find your way around.",
            actions: [.addRepository, .welcome],
            markdown: """
            Mimamori keeps watch over your git worktrees while coding agents work in them. It shows what changed, what deserves a look, and what each agent is doing right now. It never changes your branches or your index, and changes your code only when you discard something, which is off until you turn it on.

            ## Watch a repository
            - Choose **File › Add Repository…** (⌘O), drop a folder on the sidebar or on Mimamori's Dock icon, or run `open -a Mimamori <folder>` in Terminal.
            - Mimamori finds the repository's other worktrees, including the ones agent tools create, and watches them all.
            - To stop, choose **Stop Watching Repository…** from the repository's context menu or the File menu (⌘⌫).

            ## Find your way around
            - **The sidebar** lists each repository under its icon, or its initials on a muted colour, with its worktrees beneath. Hide a worktree from its context menu; the filter button at the bottom shows only worktrees with an agent at work.
            - **The file list** shows what changed in the selected worktree. Choose a file to read its diff beside it.
            - **The activity feed**, which the toolbar's Activity button (⌃⌘I) shows and hides, records each change, commit and agent step as it happens.
            - **The menu bar** keeps a summary in view when the window is closed. See [Menu bar and widgets](help:menu-bar).

            ## Connect your agents
            Mimamori spots agents with no setup at all. Hooks tell it exactly what each one is doing. **Help › Welcome to Mimamori** connects Claude Code and Hermes in a click, and [Agents](help:agents) explains the rest.
            """),

        HelpTopic(
            id: .reviewing, title: "Reviewing changes", symbol: "checkmark.circle",
            summary: "Choose a baseline, read the diffs, and keep track of what you've read.",
            actions: [],
            markdown: """
            ## Choose what to compare against
            Agents commit as they go, so a plain diff of uncommitted work goes blank after each commit. The menu above the file list picks the baseline:
            - **Uncommitted** (⌘1): the working tree against the last commit, new files included.
            - **Since Branch Point** (⌘2): everything since the branch left the default branch.
            - **Since Start** (⌘3): everything since you chose **Monitor › Mark Start** (⇧⌘S). Mark the start before you give an agent a task, then see all it did.
            - **Since Snapshot**: any earlier moment Mimamori recorded. See [Snapshots](help:snapshots).

            ## Read the file list
            - A file an agent just touched glows and says how long ago, so you can see where it is working.
            - The five-block bar shows how much changed: green for added lines, red for removed.
            - **Filter Files** (⌘F) narrows the list by name.

            ## Read a diff
            - **Side-by-Side Diff** (⌥⌘L) and **Wrap Diff Lines** (⌥⌘W) are in the Monitor menu.
            - The words that changed within a line are emphasised.
            - Beside a long diff, a strip marks where lines were added and removed. Click or drag on it to go there.

            ## Keep track of what you've read
            - **Mark as Reviewed** (⌘↩) dims the file and moves to the next one.
            - The **To review** count above the list is also a filter (⌥⌘R) that shows only what's left.
            - When an agent edits a file you reviewed, it comes back as changed since your review, and the diff can show just the newer edits.

            ## Leave notes for the agent
            - Hover over a line in a diff and click the bubble beside its number to leave a note. Shift-click another line's bubble to cover the lines between. Return saves, Option-Return starts a new line.
            - The bubble menu in the diff's header adds a note on the whole file, and copies notes as one prompt to paste where you talk to the agent.
            - A note follows its lines as the file changes. When they're gone, it moves above the diff with the lines it was written on.
            - Resolve a note once the agent has dealt with it. The file list and the sidebar count the notes not sent yet.

            ## Throw a change away
            _Off until you turn on Offer discarding hunks and files, in Settings › General › Working tree._
            - In an **Uncommitted** diff, **Discard…** on a hunk's header (or **Discard This Hunk…** in a line number's context menu) puts that hunk's lines back as they are in the last commit.
            - **Discard File…** in the diff's header, or **Discard Changes…** in the file list's context menu, does it for the whole file: a changed file gets the last commit's version and mode back, a new file moves to the Trash, and a deleted file comes back.
            - Mimamori shows you what goes and asks first. It won't discard, or undo a discard, while an agent is in the middle of a turn in that worktree, and warns you when one is between turns, since it won't know.
            - It checks that the file still matches the diff, and takes a snapshot first. **Undo** in the bar above the diff puts it back, and the activity feed records both.
            - Only that file changes: what you staged stays staged, and the index is never touched. Files git changes on the way in or out (line-ending or filter settings) and renamed files are left to you.
            """),

        HelpTopic(
            id: .attention, title: "What needs attention", symbol: "exclamationmark.triangle",
            summary: "What Mimamori flags, and how to tune it.",
            actions: [.settings(.attention, "Attention Settings…")],
            markdown: """
            Mimamori flags changes that deserve a second look before you trust them:
            - secrets: `.env` files, keys, and added lines that look like credentials;
            - dependency lockfiles, CI settings and agent instruction files;
            - `.gitignore` edits, permission changes and very large files;
            - mass deletions, and deleted or skipped tests;
            - leftover conflict markers, lint suppressions and debugging code;
            - edits outside a scope you set for the worktree.

            ## See why
            - The orange count above the file list opens every flagged file with the reason. **Flagged Only** (⇧⌘F) narrows the list to them.
            - In the diff, a flagged line takes the flag's colour, orange or red for a secret or a conflict marker, and shows the reason when you point at it.

            ## Tune it
            **Settings › Attention** turns each rule on or off, adjusts the thresholds, sets the scope for the selected worktree, and can notify you when a change is flagged.
            """),

        HelpTopic(
            id: .commits, title: "Commits and conflicts", symbol: "arrow.triangle.merge",
            summary: "Read a branch's commits, and see merges, rebases and conflicts.",
            actions: [],
            markdown: """
            ## The Commits list
            **Monitor › Show Commits** (⇧⌘H), or the Changes | Commits switch above the file list, shows the worktree's commits: first what the branch added, then earlier history. Choose a commit to read its message, expand it to its files, and choose a file for its diff. A commit's files are flagged the same way as uncommitted changes.

            ## A merge or rebase in progress
            When a worktree stops in the middle of a merge, rebase, cherry-pick or revert, a banner above its changes says so, as in "Rebasing feature/login onto main · 3 of 7". The sidebar and the menu bar say so too.

            ## Conflicts
            - A conflicted file is marked **U**.
            - Its diff draws each conflict as the two sides git couldn't merge: the current side in blue, the incoming side in purple, and the common ancestor in grey when git includes it.
            - Labelled dividers count the conflicts ("Conflict 1 of 2"), and the strip beside a long diff marks where each one starts.

            _Mimamori only shows conflicts. Resolve them in your editor, or ask the agent to._
            """),

        HelpTopic(
            id: .agents, title: "Agents", symbol: "person.2",
            summary: "See what each agent is doing, and answer it from Mimamori.",
            actions: [.agentsWindow, .settings(.agents, "Agent Settings…")],
            markdown: """
            ## With no setup
            Mimamori notices agent processes (Claude Code, Codex, Aider, Cursor, Gemini, Goose, OpenCode, Amp, and any names you add in Settings › Agents) and shows each one on the worktree it works in. That tells you an agent is there and whether it's busy.

            ## With hooks
            A hook is a command the agent runs at each step, and Mimamori's passes the step on through a socket only you can reach. With hooks, Mimamori knows when a turn starts and ends, each tool call, which edit changed which file, and when the agent needs your permission or asks you something.
            - **Claude Code and Hermes:** Help › Welcome to Mimamori or Settings › Agents › Hooks installs them in a click, after a backup. Hermes asks you to approve them once.
            - **Codex, Gemini CLI, Cursor and others:** Settings › Agents › Other Agents shows what to paste, with a Copy button.
            - Agents read their hooks when a session starts, so start a new session afterwards.

            ## Keep an eye on them
            - The pill in the toolbar names the agent waiting on you longest, or how many are working. Click it for each agent's task, steps and files.
            - **Window › Agents** (⇧⌘A) shows every agent as a card: what it's doing and for how long, its task, its latest steps, and the files it touched this turn. **Go to agent** brings its terminal or app to the front, and **Keep on Top** keeps the window above the others.
            - Settings › Agents › Notifications can tell you when an agent needs permission, asks a question or finishes a turn.

            ## Answer permission requests
            When Claude Code asks permission for a tool call, **Allow** and **Deny** appear in the agent's banner, on its card in the Agents window and in the notification. Claude Code shows its own prompt at the same time and takes whichever answer comes first, so answer wherever you are. A deny rule in your Claude Code settings always wins.

            Settings › Agents › Hooks can also answer by itself after a wait you choose, but never for a call that matches one of your ask rules.

            ## Several agents in one worktree
            Mimamori keeps each session apart. When two of them edit the same file, the banner warns you and names the files, since one may undo the other's work.
            """),

        HelpTopic(
            id: .menuBar, title: "Menu bar and widgets", symbol: "menubar.rectangle",
            summary: "Keep an eye on things with the window closed.",
            actions: [],
            markdown: """
            ## The menu bar
            The eye in the menu bar shows how many files changed, how many need a look, and how many agents are waiting for you. Click it for each agent at work, with a live timer, its task and its latest steps, then every repository and worktree. Click an agent or a worktree to open it.
            - Agents are grouped under Needs you, Working, Ready and Ended, as in the Agents window.
            - Fold the Agents or Worktrees section, or one of the agents' groups, away by its heading.
            - The pin at the bottom keeps it open as a small window above the others. It opens again at launch until you unpin it.
            - **Settings › General › Show in menu bar** hides it.

            ## Desktop widgets
            Add the **Agents** widget from the desktop's Edit Widgets menu, or from Notification Center, to see your agents without opening Mimamori. The small one shows the agent that needs you first; the larger ones list more, with tasks and steps. Click an agent to open its worktree.
            - **Edit Widget** can hide tasks and steps, or show only agents that need you.
            - **Settings › Agents › Feed & Widgets** keeps tasks and steps off every widget, since anyone near your screen can read them.
            """),

        HelpTopic(
            id: .activity, title: "Activity and summaries", symbol: "list.bullet.rectangle",
            summary: "What happened while you were away, and a write-up to share.",
            actions: [],
            markdown: """
            ## The activity feed
            The feed lists, newest first, files created, changed, deleted and reverted, discards, commits, branch switches, new flags and agent steps, for the selected worktree or for all of them.
            - Click an entry to go to its file or commit.
            - Its filter menu shows only agents' work, or hides agents' own events.
            - It keeps a week of activity by default (Settings › General), across restarts. It lists the newest 400 entries, and **Show Earlier Activity** at the bottom loads more.

            ## Session summary
            **Monitor › Session Summary…** (⇧⌘E) writes up a worktree's session in Markdown, in a window of its own: what changed, what needs attention and why, what you reviewed, the commits since the baseline, and what the agent did. Include diffs if you want them.
            - It gathers itself again a couple of seconds after the worktree changes. With diffs included, it waits for **Refresh** instead.
            - **Copy Markdown** (⇧⌘C) puts it on the clipboard, for a pull request or a handoff note, and **Save…** writes it to a file.
            """),

        HelpTopic(
            id: .snapshots, title: "Snapshots", symbol: "camera",
            summary: "Earlier moments of a worktree, to compare against.",
            actions: [.settings(.snapshots, "Snapshot Settings…")],
            markdown: """
            When a worktree changes, Mimamori records a snapshot: a commit object of the whole working tree, new files included, under `refs/monitor/` in the repository. It's never a branch, and your index and files are untouched. Discarding a hunk or a file takes one first, so you can get back what it threw away.

            Snapshots let you compare against any earlier moment (**Since Snapshot**, in the menu above the file list), and they keep the start marker across restarts. **Monitor › Take Snapshot Now** records one whenever you like.

            ## Settings › Snapshots
            - Turn automatic snapshots off, or choose how often they're taken and how many each worktree keeps.
            - See how much disk space the selected worktree's snapshots use, and delete them all. git frees the space the next time it cleans up, by default after about two weeks.
            """),

        HelpTopic(
            id: .shortcuts, title: "Keyboard shortcuts", symbol: "keyboard",
            summary: "Every menu command with a shortcut.",
            actions: [],
            markdown: """
            ## Watching
            - **⌘O** Add Repository…
            - **⌘⌫** Stop Watching Repository…
            - **⌘R** Refresh, and **⇧⌘R** Refresh All

            ## Comparing
            - **⌘1** Compare Uncommitted
            - **⌘2** Compare Since Branch Point
            - **⌘3** Compare Since Start
            - **⇧⌘S** Mark Start
            - **⇧⌘H** Show Commits

            ## Reviewing
            - **⌘↩** Mark as Reviewed, and go to the next file
            - **⌥⌘↩** Mark All as Reviewed
            - **⌘F** Filter Files
            - **⇧⌘F** Flagged Only
            - **⌥⌘R** Only Files to Review
            - **⌥⌘L** Side-by-Side Diff
            - **⌥⌘W** Wrap Diff Lines

            ## Windows
            - **⇧⌘A** Agents
            - **⌃⌘I** the activity feed (View › Show Inspector)
            - **⇧⌘E** Session Summary…, and **⇧⌘C** to copy it as Markdown
            - **⌘,** Settings
            - **⌘?** Mimamori Help
            """),

        HelpTopic(
            id: .privacy, title: "Privacy and uninstalling", symbol: "lock.shield",
            summary: "What Mimamori reads and writes, and how to take it all away.",
            actions: [.uninstall],
            markdown: """
            ## What stays on your Mac
            Mimamori talks to nothing but your local git, and a socket only your own processes can reach. It has no telemetry. Agent events are kept in memory, and nothing about your code or your prompts leaves your Mac.

            ## Updates
            The one exception: Mimamori asks GitHub whether there's a new version when you choose **Mimamori › Check for Updates…**, or once a day if you agreed to automatic checks (Settings › General). Nothing about you or your Mac goes with it, and a new version is checked against Mimamori's signing key before it's installed.

            ## What it writes
            - Its settings, the repositories you watch, your review marks and the activity feed, in `~/Library/Application Support/Mimamori/`.
            - Snapshots, inside each repository under `refs/monitor/`.
            - Your files only when you discard a hunk or a file, which is off until you turn it on: that one file, after a snapshot, and never the index.
            - The hooks you choose to install, in Claude Code's or Hermes's settings, after a backup of the file. It keeps the newest five backups.

            ## Removing Mimamori
            - **Settings › Agents › Hooks** removes the hooks and leaves your own as they are.
            - **Mimamori › Uninstall Mimamori…** lists everything Mimamori added, each with a checkbox: its hooks, its snapshots, its settings and data, and the app itself. It removes what you choose, then quits.
            """),

        HelpTopic(
            id: .troubleshooting, title: "Troubleshooting", symbol: "wrench.and.screwdriver",
            summary: "When an agent doesn't show up, and how to report a problem.",
            actions: [.settings(.agents, "Troubleshoot Agent Hooks…"), .copyDiagnostics],
            markdown: """
            ## An agent doesn't show up, or says nothing
            Open **Help › Troubleshoot Agent Hooks…**.
            - **Socket** says whether Mimamori is listening for hooks. While two copies of Mimamori run, only one listens; the other takes over a few seconds after it quits.
            - **Send Test Event** runs the hook command as an agent would, and says whether the event arrived.
            - **Recent Events** lists what came in and where it went. *Not placed* means no watched worktree holds the folder the agent works in, so add its repository (⌘O). Nothing at all means the agent isn't running its hooks: start a new session after installing them.
            - Hermes runs a hook only once you approve it. Run `hermes --accept-hooks` once in Terminal, then start a new session.

            ## An agent shown only as "Agent"
            Its hook didn't say which agent it is. Add `?agent=<name>` to the address in its hook command, as the setups in Settings › Agents › Other Agents do.

            ## No usable git
            Mimamori needs git. Install the Command Line Tools (`xcode-select --install`) or git from Homebrew, or set its path in Settings › General › Git.

            ## A summary marked out of date
            With diffs included, a session summary waits for you to click **Refresh**, since every diff is read again.

            ## Report a problem
            **Help › Copy Diagnostics** copies the versions, the socket, which hooks are installed and the recent events, never prompts, commands or file contents. It does name your worktrees' folders, so look it over before you post it. Then open an issue from **Help › Mimamori on GitHub**.
            """),
    ]
}

/// A button at the foot of a topic that does what the topic describes.
enum HelpAction: Hashable {
    case addRepository
    case welcome
    case agentsWindow
    case settings(SettingsTab, String)
    case copyDiagnostics
    case uninstall

    var title: String {
        switch self {
        case .addRepository: "Add Repository…"
        case .welcome: "Welcome to Mimamori"
        case .agentsWindow: "Open Agents Window"
        case .settings(_, let title): title
        case .copyDiagnostics: "Copy Diagnostics"
        case .uninstall: "Uninstall Mimamori…"
        }
    }
}
