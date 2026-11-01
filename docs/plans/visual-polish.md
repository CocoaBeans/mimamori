# Plan: visual polish

Ideas from looking at Vigil's screens while agents work, most valuable first. The roadmap tracks
them; the first three are being built now. One rule for all of them: animate only on a change of
state, never on a loop. A repeating animation keeps the screen redrawing and undoes the energy
work.

## 1. One look for each agent, and one for "needs you"

**Today:** Codex, Claude Code and Hermes all look alike: a sparkle and a name. Attention appears
as a hand, a triangle or plain orange text.

**Plan:**
- **A glyph per agent kind.** A generic SF Symbol, never a product logo: `AgentKind.symbolName`
  in VigilCore, so the app, the widget snapshot and the package build all share it.

  | Agent | Glyph |
  |---|---|
  | Claude Code | `sparkle` |
  | Codex | `curlybraces` |
  | Gemini CLI | `diamond` |
  | Cursor | `cursorarrow.rays` |
  | Hermes | `paperplane` |
  | Aider | `wrench.adjustable` |
  | Goose | `bird` |
  | OpenCode | `chevron.left.forwardslash.chevron.right` |
  | Amp | `bolt` |
  | Any other agent | the circled first letter of its name (`m.circle`) |

- **Colour means state, and only state:** orange needs you, blue working, green ready, grey
  otherwise. The glyph says who; the colour says how it's doing.
- **One attention language:**
  - A hand (`hand.raised.fill`) means an agent is waiting on you.
  - A triangle means risk: a flagged file, or two agents colliding.
- **Everywhere an agent appears:**
  - the sidebar badge;
  - the banner and its "Also here" lines;
  - the Agents window;
  - activity-feed entries made by agents;
  - the menu bar list;
  - the widgets, which get the glyph through the snapshot.

## 2. Group the activity feed by turn

**Today:** every tool call is its own row, all with the same tool icon, so a busy agent buries
everything else.

**Plan:**
- **Fold a turn into one row.** An agent's run of consecutive tool calls in one worktree becomes a
  single row, for example "Codex · 6 edits, 2 commands in plan", with when it started and its
  glyph. It expands in place to show each step.
- **What ends a run:** anything else in the feed, a different agent or worktree, the turn
  finishing, or a gap of five minutes.
- **What stays on its own:**
  - file changes, commits, flags;
  - turn starts and ends;
  - permission requests and collisions, which must not hide inside a group.
- **Day separators:** Today, Yesterday, then dates.
- **Where it lives:** grouping is a pure function over the entries in VigilCore, with tests. The
  feed view only draws groups.

## 3. A banner that fits its column

**Today:** the banner sits in the diff column. With the activity feed open that column is narrow,
the headline shrinks to "…" and only the timer and buttons show.

**Can it span the columns?** SwiftUI's three-column split view can't give a banner a row across
the change list and the diff. A banner above the whole window would also run over the sidebar.

**Plan:** the banner adapts instead.
- **Wide:** one row, as now: agent and state, then the timer and buttons on the right.
- **Narrow:** two rows. The agent and state get the first row to themselves; the timer, step
  count and buttons move to the second. The headline never truncates to nothing.

Spanning the window can come later as a status pill in the toolbar (see the list below).

## Later

4. **A mini diff bar per changed file:** a small green and red bar showing how much each file
   changed, plus file-type icons.
5. **Compact sidebar rows:** the agent glyph, plus chips for changed, flagged and to-review files,
   instead of text that truncates.
6. **A menu-bar popover that looks like the widget:** reuse the widget's views, so the menu bar
   shows agent rows with live timers instead of a text menu.
7. **A change overview beside the diff:** a thin strip showing where changes are, and hunk headers
   that stay put while you scroll.
8. **Split Settings › Agents into tabs:** Hooks, Other agents, Widgets and Notifications.
9. **A real app icon** in place of the emoji candle.
10. **A status pill in the toolbar:** the most pressing agent across the window, like Xcode's
    activity view, with the banner's details in a popover.
