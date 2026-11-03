# Plan: an iPhone companion

> **Proposed.** Nothing is built yet. Two questions shape the order of the work (see
> "To decide first"): App Store or TestFlight, and whether the live view or "needs you"
> notifications matter more.

## Goal

Keep tabs on your agents from your iPhone, the way the Agents window does on the Mac:
- which worktrees have an agent, and what each one is doing;
- who needs you, and for how long;
- with your OK, answer a permission request ("Claude Code needs permission · Bash") from the phone.

It works on the same Wi-Fi first. Over cellular is the stretch goal, and one cheap route gets most
of the way there.

## What Mimamori already has

Most of the hard work is done, for the desktop widgets:

- **A snapshot to send.** `AgentWidgetSnapshot` (in MimamoriCore) is small, `Codable` JSON:
  agents most pressing first, each with state, status, since when, task, latest steps, other
  agents in the worktree and any collision. The desktop widget reads exactly this.
- **When to send it.** `WidgetPublisher` writes at once when who needs you changes, otherwise at
  most every 10 s, and only when something shown changed, plus a heartbeat every 15 minutes. A
  companion publisher can sit beside it and follow the same rules.
- **Views to draw it.** `Sources/WidgetUI` is SwiftUI. Its only Mac-only piece is `NSImage` for
  repository icons (`RepositoryTag.swift`), so the phone can draw the same cards as the widget and
  the menu-bar popover.
- **A way to answer.** `PermissionBroker` holds a Claude Code `PermissionRequest` open for up to
  590 s (the hook's own timeout is 600 s) while Mimamori's Allow and Deny answer it, and
  whichever is answered first counts. The phone's Allow and Deny would go through the same
  `answerPermission` call. Other agents don't hand Mimamori their permission prompts, so for them
  the phone can only say "needs you".

What the snapshot lacks is what the Agents window adds to the widget: the turn timeline strip
(`TurnTimeline`), the files touched this turn with their diff bars, and how much is left to
review. These become optional fields, so older widgets keep decoding it.

## The constraint: an iPhone app in your pocket

iOS suspends an app soon after it leaves the screen, and a suspended app keeps no connection open.
So there are two separate jobs:

1. **The live view while the app is open.** A direct connection to the Mac. Easy.
2. **A tap on the shoulder when it isn't.** Only a push notification reaches a phone in your
   pocket. Which kind of push is the real choice in this plan.

## On the same network

- **Finding the Mac.** Mimamori advertises `_mimamori._tcp` with Bonjour and listens on a port of
  its own. The phone browses for it, so there is no address to type. Network.framework does both:
  `NWListener` and `NWBrowser` on macOS 15, or the newer `NetworkListener` and
  `NetworkConnection` on macOS and iOS 26, which can send `Codable` values directly.
- **What goes over it.**
  - Mac to phone: a snapshot when one is due, as above.
  - Phone to Mac: Allow or Deny for a request id, and "send me a fresh snapshot".
  - JSON, with a version field so the two apps can be updated at different times.
- **Pairing.** Settings › Companion shows a QR code holding a random key and the Mac's name. The
  phone scans it, and every connection after that is TLS with that pre-shared key
  (`sec_protocol_options_add_pre_shared_key`), so nobody else on the network can read it or
  answer for you. Settings lists each paired phone, with when it was last seen and a Remove
  button.
- **Local network permission, on both ends.** The phone asks the first time it browses
  (`NSLocalNetworkUsageDescription` and `NSBonjourServices` in its Info.plist). Since macOS 15
  the Mac asks too: registering a Bonjour service needs local network access. Mimamori should
  only register once the companion is switched on, so the prompt comes when you expect it.
- **Background notifications without Apple's push servers.** Local Push Connectivity
  (`NEAppPushProvider`) lets an app on a named Wi-Fi network get pushes from a server on that
  network. It's an entitlement you request from Apple, meant for networks with no route to Apple's
  push servers, so a home or office network may not qualify. Ask once; don't plan on it.

Serving a web page instead of an iPhone app (Add to Home Screen) is possible and skips the App
Store. But HTTPS on a local network needs a certificate the phone trusts, and without it there is
no web push and pairing is weaker. Not recommended.

## Over cellular

Cheapest first:

1. **Bring your own VPN: Tailscale.** With both devices on a tailnet, the same-network design
   works unchanged, since the listener accepts connections on every interface. Bonjour doesn't
   cross Tailscale, so the phone also offers "Connect to a host" (a MagicDNS name or address),
   kept beside paired Macs it found itself. No server, no account of Mimamori's. This is the
   cellular route for the first version.
2. **CloudKit as the relay, for notifications.**
   - The Mac keeps one record per paired phone in your private iCloud database, updated when who
     needs you changes, not on every step.
   - The phone subscribes (`CKQuerySubscription`), so a change arrives as a notification even
     when the app isn't running. Allow and Deny are buttons on it, which write an answer record
     the Mac picks up within seconds, well inside the 590 s.
   - Your Apple ID is the account, the data stays in your private database, and Mimamori runs no
     server. Apple's capability table lists CloudKit and push notifications for Developer ID
     apps.
   - The cost: today's signing needs no provisioning profile at all. CloudKit needs an iCloud
     container and a Developer ID provisioning profile in `Scripts/release.sh` and CI, and the
     production CloudKit environment for release builds.
3. **A relay of our own, for Live Activities and the Watch.** "Claude Code · working · 4m · Edit"
   on the Lock Screen and in the Dynamic Island means updating a Live Activity while the app is in
   the background. That takes pushes from a server holding an APNs key, and the key can't ship in
   an open-source Mac app. So this needs a small relay (a Cloudflare Worker would do), with the
   payload encrypted end to end by the paired key so the relay sees only ciphertext. It also
   needs an APNs key of its own; the Mac's App Store Connect key can't send pushes.

## Trust

The README promises that Mimamori talks to nothing but local `git` and a socket only you can
reach. The companion changes that, so:

- **Off until you switch it on**, in Settings › Companion, and nothing listens or registers with
  Bonjour before then.
- **The same privacy line as the widgets.** With "Show tasks and steps in widgets" off, tasks and
  steps never leave the Mac either. Paths in steps and statuses are shortened to the worktree, as
  the widget's are.
- **Watching and answering are separate switches.** Answering also needs "Answer permission
  requests in Mimamori" on.
- **Allow from the phone runs a command on the Mac**, so the phone shows the exact command or file
  before you answer, asks for Face ID before Allow, and makes Deny one tap.
- **Documented** in "Privacy and footprint" and Help's Privacy topic. Uninstall Mimamori… removes
  the pairings, and the CloudKit records when that route exists.

## Code layout

- **A small shared target.** MimamoriCore is macOS-only in `Package.swift`, and four of its files
  use macOS-only APIs (`FSEventsWatcher`, `ProcessInspector`, `ProcessRunner` behind the git
  client, and `HookSocketServer`). Rather than gate them, move what the phone needs into a target
  that builds for both: the snapshot model, `AgentKind`'s names and symbols, `RepositoryColor`,
  and the companion's wire messages. MimamoriCore depends on it, so nothing else moves.
- **WidgetUI on iOS.** A platform image typealias in `RepositoryTag.swift`, and repository icons
  sent once per repository as PNG data rather than in every snapshot.
- **On the Mac.** A `CompanionPublisher` beside `WidgetPublisher`, fed from
  `AppModel.publishWidgets()`, owning the listener, the pairings and the connections.
- **On the phone.** An iOS app target in `Mimamori.xcodeproj`: a paired-Macs screen, the agents
  list, an agent's detail with its timeline and files, and Allow and Deny. Later, an iOS widget
  from the same views.

## Steps

1. **Spike, about an afternoon.** The Mac advertises over Bonjour and streams unencrypted snapshot
   JSON; a bare iPhone app lists agents with the widget's views. This settles:
   - the shared target, and WidgetUI building for iOS;
   - the local network prompts on both ends;
   - how quickly changes arrive.
2. **Same-network companion.**
   - QR pairing and TLS with the pre-shared key; the paired phones list.
   - The richer snapshot fields; an agent's detail on the phone.
   - Allow and Deny with Face ID.
   - The Settings tab, Help and README text, and Uninstall.
3. **Cellular through Tailscale.** "Connect to a host", reconnecting when the network changes, and
   a clear "can't reach your Mac" state.
4. **Notifications through CloudKit.** The container and provisioning profile, the records and
   subscription, and notification actions for Allow and Deny.
5. **Later, if wanted.** The relay, Live Activities and the Dynamic Island, a Watch app.

## To decide first

- **App Store or TestFlight.** TestFlight for yourself is quick. The App Store accepts companion
  apps that need a Mac app, but wants a privacy policy page (the website can host it) and review
  of each update.
- **Live view or notifications first.** The live view is steps 1–3. If "needs you" notifications
  matter more, CloudKit (step 4) can come straight after pairing.
- **Minimum macOS for the companion.** macOS 15 with `NWListener`, or 26 for the newer API.

## References

- [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Local Push Connectivity](https://developer.apple.com/documentation/networkextension/local-push-connectivity)
- [Use structured concurrency with Network framework (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/250)
