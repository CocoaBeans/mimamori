@preconcurrency import ActivityKit
import Foundation
import MimamoriShared
import os

/// The Live Activity's switch in the phone's settings.
enum LiveActivitySetting {
    static let shows = "showsLiveActivity"

    static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [shows: true])
    }
}

/// Shows the connected Mac's agents as a Live Activity: on the Lock Screen, in the Dynamic Island
/// and in an Apple Watch's Smart Stack.
///
/// Only in builds that keep running in the background. iOS suspends any other app soon after you
/// leave it, and a Live Activity it left up would go on showing old states as current. It starts
/// while the app is in front, the only time iOS allows, follows each snapshot, and ends when the
/// app lets go of the Mac.
@MainActor
final class LiveActivityController {
    private static let log = Logger(subsystem: "com.kevinross.Mimamori.Companion", category: "live-activity")
    /// A change in who needs you goes out after this pause, so a burst of them goes as one.
    private static let coalesce: TimeInterval = 1
    /// Other changes, a step or a task moving on, go out at most this often. An agent at work
    /// changes every few seconds, and iOS limits how often an app may update a Live Activity:
    /// sending each change, it stopped taking any, and the Live Activity went stale (2026-11-15).
    private static let routineEvery: TimeInterval = 30
    /// Unupdated this long, the Live Activity says so, in case iOS ended the app.
    private static let staleAfter: TimeInterval = 15 * 60
    /// While nothing changes, it's sent again this often so it doesn't go stale.
    private static let refreshEvery: Duration = .seconds(5 * 60)
    /// iOS ends a Live Activity after 8 hours. One older than this is started afresh when the app
    /// comes to the front, where it can be.
    private static let renewAfter: TimeInterval = 6 * 60 * 60

    private let defaults: UserDefaults
    private var activity: Activity<AgentsActivityAttributes>?
    private var startedAt: Date?
    private var latest: AgentsActivityState?
    private var sent: AgentsActivityState?
    private var sending: Task<Void, Never>?
    /// Whether the update waiting in `sending` is an urgent one.
    private var sendingUrgent = false
    private var lastSentAt = Date.distantPast
    /// Updates sent since the app last left the front, and how many iOS didn't take.
    private var backgroundUpdates = 0
    private var notTaken = 0
    /// Updates iOS hasn't taken in a row; the log says when this starts and ends.
    private var droppedInARow = 0
    private var refresher: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    /// The background log already says Live Activities are off.
    private var loggedDisabled = false
    /// Whether the app is in front. Leaving it, the latest goes out at once, as nothing else shows
    /// it now; coming back, the log says how the updates went meanwhile.
    var appIsActive = true {
        didSet {
            guard appIsActive != oldValue else { return }
            if appIsActive {
                if backgroundUpdates > 0 {
                    let updates = backgroundUpdates == 1 ? "1 Live Activity update" : "\(backgroundUpdates) Live Activity updates"
                    BackgroundLog.shared.add(.liveActivity, notTaken == 0
                        ? "In the background: \(updates), \(backgroundUpdates == 1 ? "taken" : "all taken")"
                        : "In the background: \(updates), \(notTaken) not taken by iOS")
                }
                backgroundUpdates = 0
                notTaken = 0
            } else if activity != nil, latest != sent {
                schedule(after: 0, urgent: true)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        LiveActivitySetting.register(in: defaults)
        // One left from before the app last quit shows states nothing updates any more.
        for leftover in Activity<AgentsActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Whether this build and the settings want one: staying connected in the background, and the
    /// Live Activity's own switch.
    var isWanted: Bool {
        BackgroundKeepAlive.isAvailable
            && defaults.bool(forKey: CompanionNotificationSetting.staysConnected)
            && defaults.bool(forKey: LiveActivitySetting.shows)
    }

    /// Shows `snapshot`, the agents on `macName`; a nil `macName` (no Mac) ends it. `connected`
    /// false says the phone has lost touch, so what's shown is the last it heard.
    func show(macName: String?, snapshot: AgentWidgetSnapshot?, connected: Bool) {
        guard isWanted, let macName else {
            end()
            return
        }
        let state = AgentsActivityState(snapshot: snapshot, connected: connected)
        if let activity, activity.attributes.macName != macName || isDueForRenewal {
            BackgroundLog.shared.add(.liveActivity, isDueForRenewal ? "Renewing the Live Activity before iOS's 8 hours run out"
                                                                   : "Another Mac: starting its own Live Activity")
            end()
        }
        latest = state
        if activity == nil {
            // Starting needs the app in front, and something from the Mac to show.
            guard appIsActive, connected, snapshot != nil else { return }
            start(macName: macName, state: state)
        } else if state != sent {
            let urgent = state.isUrgent(comparedTo: sent)
            // An urgent change overtakes a routine update still waiting.
            guard sending == nil || (urgent && !sendingUrgent) else { return }
            let routineWait = Self.routineEvery - Date().timeIntervalSince(lastSentAt)
            schedule(after: urgent ? Self.coalesce : max(Self.coalesce, routineWait), urgent: urgent)
        }
    }

    /// Sends the latest state after `delay` seconds, unless a newer schedule replaces this one.
    private func schedule(after delay: TimeInterval, urgent: Bool) {
        sending?.cancel()
        sendingUrgent = urgent
        sending = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.sending = nil
            await self.send(force: false)
        }
    }

    /// Takes the Live Activity down at once.
    func end() {
        guard let activity else { return }
        BackgroundLog.shared.add(.liveActivity, "Took the Live Activity down")
        clear()
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private var isDueForRenewal: Bool {
        guard appIsActive, let startedAt else { return false }
        return Date().timeIntervalSince(startedAt) > Self.renewAfter
    }

    private func start(macName: String, state: AgentsActivityState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            if !loggedDisabled { BackgroundLog.shared.add(.liveActivity, "Live Activities are off for Mimamori in Settings") }
            loggedDisabled = true
            return
        }
        loggedDisabled = false
        do {
            let activity = try Activity.request(attributes: AgentsActivityAttributes(macName: macName),
                                                content: Self.content(state), pushType: nil)
            self.activity = activity
            startedAt = Date()
            sent = state
            watch(activity)
            keepFresh()
            BackgroundLog.shared.add(.liveActivity, "Started the Live Activity for \(macName)")
        } catch {
            Self.log.error("Couldn't start the Live Activity: \(error.localizedDescription, privacy: .public)")
            BackgroundLog.shared.add(.liveActivity, "Couldn't start the Live Activity: \(error.localizedDescription)")
        }
    }

    private func send(force: Bool) async {
        guard let activity, let latest, force || latest != sent else { return }
        sent = latest
        lastSentAt = Date()
        let content = Self.content(latest)
        #if DEBUG
        // For scripted runs: `-debugLiveActivityAlert YES` alerts with each update, and sends one
        // every 10 s, which shows the expanded Dynamic Island without a long press.
        if UserDefaults.standard.bool(forKey: "debugLiveActivityAlert") {
            let alert = AlertConfiguration(title: "Agents changed", body: "\(latest.summary)", sound: .default)
            await activity.update(content, alertConfiguration: alert)
            await check(activity, took: content, refresh: force)
            return
        }
        #endif
        await activity.update(content)
        await check(activity, took: content, refresh: force)
    }

    /// Whether iOS took `content`: an update it took moves the Live Activity's stale date on. The
    /// log says when updates stop being taken and when they start again, not each one.
    private func check(_ activity: Activity<AgentsActivityAttributes>, took content: ActivityContent<AgentsActivityState>,
                       refresh: Bool) async {
        // The activity's content follows the update a moment later. A newer update sent meanwhile
        // moves the stale date further on, which counts as this one taken too.
        try? await Task.sleep(for: .seconds(2))
        let sentStale = content.staleDate ?? .distantFuture
        let taken = (activity.content.staleDate ?? .distantPast) >= sentStale.addingTimeInterval(-1)
        if !appIsActive {
            backgroundUpdates += 1
            if !taken { notTaken += 1 }
        }
        if taken {
            if droppedInARow > 0 {
                BackgroundLog.shared.add(.liveActivity, "iOS is taking Live Activity updates again, after \(droppedInARow) it didn't take")
            }
            droppedInARow = 0
        } else {
            if droppedInARow == 0 {
                BackgroundLog.shared.add(.liveActivity, "iOS didn't take a Live Activity \(refresh ? "refresh" : "update")\(appIsActive ? "" : " sent in the background")")
            }
            droppedInARow += 1
        }
    }

    /// Who needs you ranks it above other apps' Live Activities.
    private static func content(_ state: AgentsActivityState) -> ActivityContent<AgentsActivityState> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfter),
                        relevanceScore: state.needingYou > 0 ? 100 : 50)
    }

    private func keepFresh() {
        refresher?.cancel()
        var every = Self.refreshEvery
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugLiveActivityAlert") { every = .seconds(10) }
        #endif
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled else { return }
                await self?.send(force: true)
            }
        }
    }

    /// You swiped it away, or iOS ended it after its 8 hours: let it go. The app starts another
    /// the next time it's in front.
    private func watch(_ activity: Activity<AgentsActivityAttributes>) {
        watcher?.cancel()
        watcher = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self, self.activity?.id == activity.id else { return }
                switch state {
                case .dismissed, .ended:
                    BackgroundLog.shared.add(.liveActivity, state == .dismissed ? "The Live Activity was swiped away" : "iOS ended the Live Activity")
                    self.clear()
                    return
                case .stale:
                    BackgroundLog.shared.add(.liveActivity, "The Live Activity went stale: not updated for \(CompanionEventLog.duration(Self.staleAfter))")
                default:
                    break
                }
            }
        }
    }

    private func clear() {
        sending?.cancel()
        sending = nil
        sendingUrgent = false
        droppedInARow = 0
        refresher?.cancel()
        refresher = nil
        watcher?.cancel()
        watcher = nil
        activity = nil
        startedAt = nil
        sent = nil
    }
}
