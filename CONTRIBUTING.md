# Contributing to Mimamori

Thank you for helping. Issues and pull requests are welcome: bugs, agents Mimamori does not
understand yet, and ideas from the [roadmap](ROADMAP.md).

## Building

You need macOS 15 or later and Xcode 16 or later. The [README](README.md#install) has the steps;
in short:

```bash
MIMAMORI_SIGN=adhoc Scripts/make-app.sh release   # build/Mimamori.app, signed ad hoc
swift test                                     # the tests, without Xcode
```

### Signing with your own team

The Xcode project signs with the maintainer's team (`555LXJXR4U`), so a plain
`Scripts/make-app.sh` fails without that team's certificate. `MIMAMORI_SIGN=adhoc` builds without it.
An ad-hoc build runs, but its desktop widget cannot read Mimamori's data: the app and the widget share
an App Group, and an App Group needs a team.

To build with your own team, widget included, change these to your team ID (and your own bundle
ID, if you like), and keep them out of your pull request:

- `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` in `Mimamori.xcodeproj` (Signing & Capabilities
  in Xcode, for each target).
- The App Group, `<TEAM>.<bundle id>`, in `Resources/Mimamori.entitlements`,
  `Resources/MimamoriWidgets.entitlements` and `AgentWidgetSnapshot.appGroup`.

## Making a change

- **Keep `MimamoriCore` free of UI.** Git, file watching, diffing, rules and agent events live there,
  where `swift test` exercises them quickly. Views live in `Sources/Mimamori` and `Sources/WidgetUI`.
- **Keep `MimamoriShared` free of UI and of macOS-only APIs.** It holds what the Mac and the
  iPhone companion (`Sources/MimamoriCompanion`) both use, with Foundation, Network, Security and
  CryptoKit only, and builds for macOS and iOS. `MimamoriCore` re-exports it.
- **Add a test** when you touch a parser, a rule, the agent status machine or anything else in
  `MimamoriCore`. The tests use Swift Testing; some run real `git` in temporary repositories.
- **Run `swift test`** before opening a pull request, and build the app once
  (`MIMAMORI_SIGN=adhoc Scripts/make-app.sh`) if you changed a view or the Xcode project.
- **Show UI changes.** A screenshot in the pull request helps. The debug hooks in the README
  (`MIMAMORI_SCREENSHOT`, `MIMAMORI_DEBUG_FLAGS` and friends) take one from a scratch run, and
  `MIMAMORI_SUPPORT_DIR` keeps that run away from your real state, hooks socket and desktop widget.
- **One change per pull request**, with a description of what changed and why.
- **Note it in the [changelog](CHANGELOG.md)** if people using Mimamori would notice it. Add a line
  under *Unreleased*, in the section that fits (Added, Changed, Fixed, Removed, Security), with a
  link to the pull request. Changes only contributors see, such as CI or scripts, need no entry.
- Comments explain why the code is the way it is, not what it does.

## Reporting a security problem

Mimamori runs `git`, reads agents' session records and listens on a local socket, so please report
anything that could let one process abuse another privately, through **Report a vulnerability**
on the repository's Security tab, rather than in a public issue.

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE),
the same as Mimamori.
