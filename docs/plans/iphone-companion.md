# Plan: an iPhone companion

> **Under way.** Step 1 is done, and so is step 2's pairing: QR pairing, TLS with each phone's own
> key, and Settings › iPhone, in release builds. From step 3, the keep-alive and local
> notifications came next, ahead of the rest of step 2. Then Allow and Deny, on the cards and on
> the notifications, with Face ID before Allow and the auto-answer countdown: the snapshot's
> `permissionRequest`, and the phone's `answer`, which the Mac acts on only from a paired phone for
> a request still waiting (`CompanionAnswerCheck`). Next: an agent's list of actions. Builds of
> your own come first: same network, then the silent-audio keep-alive with "needs you"
> notifications, then Tailscale. CloudKit and a relay wait for an App Store build.
> The Mac side stays on macOS 15 with `NWListener` (see "Decided").

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
- **Answering by itself.** With auto-answer on, Mimamori answers a request after a wait
  (`PermissionRequest.autoAnswer`). The phone shows the same countdown, and an answer from the
  phone settles the request the way the Mac's buttons do, which stops the countdown.

What the snapshot lacks:
- **The request to answer.** It has one entry per worktree and a status line, but Allow and Deny
  need the request's id, the tool and its detail (the exact command or file), and any auto-answer
  due. Those live in `AgentHub.pendingPermissions`, on the Mac only. They become an optional
  pending-request field on the agent, sent to the phone only. Not to the widget, which can't
  answer anyway, and only while "Answer permission requests in Mimamori" is on.
- **What the Agents window adds to the widget:** the turn timeline strip (`TurnTimeline`), the
  files touched this turn with their diff bars, and how much is left to review.

All of these are optional fields, so older widgets keep decoding the snapshot.

## The constraint: an iPhone app in your pocket

iOS suspends an app soon after it leaves the screen, and a suspended app keeps no connection open.
So there are two separate jobs:

1. **The live view while the app is open.** A direct connection to the Mac. Easy.
2. **A tap on the shoulder when it isn't.** In an App Store build, only a push notification
   reaches a phone in your pocket, and which kind of push is the real choice. A build of your own
   can instead keep itself running (see "Staying connected in the background").

## On the same network

- **Finding the Mac.** Mimamori advertises `_mimamori._tcp` with Bonjour and listens on a port of
  its own. The phone browses for it, so there is no address to type. Network.framework does both,
  with `NWListener` on the Mac and `NWBrowser` and `NWConnection` on the phone. The newer
  `NetworkListener` and `NetworkConnection` need macOS and iOS 26, and CI's Xcode 16.4 build
  can't compile them, so they wait until the oldest Xcode CI builds with is 26.
- **Not adding to the Mac's energy use.** The connection carries what `WidgetPublisher` would
  write anyway, on the same rules. "Send me a fresh snapshot" answers once with what's current
  and starts no polling.
- **What goes over it.**
  - Mac to phone: a snapshot when one is due, as above, and an agent's actions when asked.
  - Phone to Mac: Allow or Deny for a request id, "send me a fresh snapshot", and "send me this
    agent's actions" while its detail is open.
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

## Staying connected in the background (builds of your own)

An app that is playing audio isn't suspended. So a build that plays silence while it's in the
background keeps its connection to the Mac open, and everything else follows from the app itself
rather than from a push service:

- **Notifications** are local ones the app posts (`UNUserNotificationCenter`) when an agent starts
  needing you, with Allow and Deny as actions. Allow is marked `.authenticationRequired`, so the
  phone must be unlocked to use it. The answer goes back over the open connection.
- **A Live Activity**, "Claude Code · working · 4m · Edit" on the Lock Screen and in the Dynamic
  Island, is started and updated by the app as snapshots arrive, with no APNs.
- **Over cellular** it rides on Tailscale, below, reconnecting when the phone moves between Wi-Fi
  and cellular.

**How it works.** An existing prototype to port does this:
- it sets the audio session to `.playback` with `.mixWithOthers`, so your own music keeps playing;
- when the app goes to the background, it loops a one-sample silent WAV, built from bytes in code,
  at almost no volume;
- it stops when the app comes back to the front, since the open connection needs no help then.

Porting it needs:
- **The background mode.** `UIBackgroundModes` with `audio` in the iOS app's Info.plist; the
  prototype's app no longer declares it.
- **Interruptions handled at their end.** A phone call or Siri stops the audio. The prototype
  restarts playback when an interruption *begins*. It should restart when it *ends*, and after
  `mediaServicesWereResetNotification`. If iOS suspends the app before then, opening it again
  starts over, and the app says it was disconnected.
- **A switch.** "Stay connected in the background" in the phone's settings, off by default, with
  a line about battery.

**Limits.**
- **Not for the App Store.** App Review allows background audio only for audio you can hear
  (guideline 2.5.4). So the audio mode and the keep-alive are built only in a configuration of
  their own, for running from Xcode or for TestFlight's internal testers, who need no beta
  review. An App Store build leaves both out and uses the pushes below.
- **TestFlight builds expire after 90 days**, so a build of your own installed from TestFlight
  needs a fresh upload at least that often. One installed from Xcode lasts as long as its
  provisioning profile.
- **Battery.** Silence still keeps the audio hardware awake, and the connection keeps the radio
  busy. Measure it during the spike. If it hurts, stop the audio when no agent is working and
  nothing has needed you for a while.
- **iOS can still end it**, under memory pressure or after a restart. The app then says it's
  disconnected the next time you look, rather than showing old states as current.

## Over cellular

Cheapest first:

1. **Bring your own VPN: Tailscale.** With both devices on a tailnet, the same-network design
   works unchanged, since the listener accepts connections on every interface. Bonjour doesn't
   cross Tailscale, so the phone also offers "Connect to a host" (a MagicDNS name or address),
   kept beside paired Macs it found itself. No server, no account of Mimamori's. This is the
   cellular route for the first version. With the keep-alive above, it also carries notifications
   and the Live Activity, so a build of your own needs nothing else.

The next two are for an App Store build, which can't keep itself running:

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

## An agent's actions

Tapping an agent's card on the phone opens its list of actions: every step of the turn under way,
newest first, then the turns before it under their prompts, as the activity feed on the Mac
shows an agent's runs. Each action shows:
- the tool and what it acted on (the command, the file);
- when it ran and for how long;
- whether it failed, is running, or is waiting on you.

The snapshot carries only the current turn's steps, which a card needs, so it stays small.
- **On demand.** The list comes from the Mac when the detail opens: "send me this agent's actions",
  answered with its recent calls across turns.
- **While open.** It updates while the detail is open, on the snapshot's rules.
- **Privacy.** With "Show tasks and steps in widgets" off, the list keeps each action's kind and
  times but not what it acted on, as the cards do.

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
  - It exists twice, like MimamoriCore: a target in `Package.swift`, which adds iOS to its
    platforms, and a framework target in `Mimamori.xcodeproj` that builds for macOS and iOS. The
    project's MimamoriCore framework is macOS-only (`SDKROOT = macosx`).
  - Its tests run with `swift test` on the Mac, like the rest.
- **WidgetUI on iOS.** A platform image typealias in `RepositoryTag.swift`, and repository icons
  sent once per repository as PNG data rather than in every snapshot.
- **On the Mac.** A `CompanionPublisher` beside `WidgetPublisher`, fed from
  `AppModel.publishWidgets()`, owning the listener, the pairings and the connections.
- **On the phone.** An iOS app target in `Mimamori.xcodeproj`: a paired-Macs screen, the agents
  list, an agent's detail with its list of actions, timeline and files, and Allow and Deny. The
  keep-alive and its `audio` background mode only in the configuration for builds of your own.
  iOS 18 or later.
  Later, an iOS widget from the same views.
- **Signing.** The Mac app needs no provisioning profile, but an iOS app always does: a
  registered bundle ID and automatic signing with the team. An iOS App Group must start with
  `group.`, so a later iOS widget can't reuse `AgentWidgetSnapshot.appGroup`, the Mac's
  team-prefixed one.
- **CI.** `ci.yml` builds the iOS target for `generic/platform=iOS` without signing, on both
  Xcodes.
- **Alongside the 1.2.0 work.** The project, `Package.swift` and CI belong to the T lane, and
  `AppModel` to the P lane, of the maintainability fixes. The companion keeps to files of its own
  plus one call from `AppModel.publishWidgets()`, and lands its project and package changes
  while the T lane has nothing open.

## Steps

1. **Spike, about an afternoon.** The Mac advertises over Bonjour and streams unencrypted snapshot
   JSON; a bare iPhone app lists agents with the widget's views. This settles:
   - the shared target in both the package and the project, and WidgetUI building for iOS;
   - the iOS target building in CI on both Xcodes, and signing on a phone;
   - the local network prompts on both ends;
   - how quickly changes arrive.
2. **Same-network companion.**
   - QR pairing and TLS with the pre-shared key; the paired phones list.
   - The richer snapshot fields, including the request to answer.
   - Tapping an agent's card opens its detail, with its list of actions (see "An agent's actions").
   - Allow and Deny with Face ID, and the auto-answer countdown.
   - The Settings tab, Help and README text, and Uninstall.
3. **Staying connected, in builds of your own.** Port the silent-audio keep-alive into its own
   build configuration, then local notifications with Allow and Deny, then the Live Activity.
   Measure the battery cost over an afternoon of agents.
4. **Cellular through Tailscale.** "Connect to a host", reconnecting when the network changes, and
   a clear "can't reach your Mac" state.
5. **For an App Store build: notifications through CloudKit.** The container and provisioning
   profile, the records and subscription, and notification actions for Allow and Deny.
6. **Later, if wanted.** The relay for an App Store build's Live Activity, and a Watch app.

## Decided

On 2026-11-05:
- **Builds of your own first.** From Xcode, or TestFlight's internal testers: steps 1–4. An App
  Store build (step 5) can come later from the same code, with the keep-alive left out. It needs a
  privacy policy page (the website can host it) and review of each update.
- **Notifications before cellular.** Who needs you while the phone is in your pocket matters more
  than the live view away from home. So the keep-alive and local notifications come straight after
  pairing, and Tailscale after them.
- **macOS 15 with `NWListener`** on the Mac side, so the companion needs nothing newer than
  Mimamori does, and builds with both of CI's Xcodes.

## References

- [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Local Push Connectivity](https://developer.apple.com/documentation/networkextension/local-push-connectivity)
- [Use structured concurrency with Network framework (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/250)
