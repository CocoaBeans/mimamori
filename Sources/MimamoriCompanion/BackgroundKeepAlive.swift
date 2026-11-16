import AVFoundation
import MimamoriShared
import os

/// Keeps the app running in the background by playing silence, so it stays connected to the Mac
/// and can tell you when an agent needs you. iOS doesn't suspend an app that is playing audio.
///
/// For builds of your own only: App Review allows background audio only for audio you can hear
/// (guideline 2.5.4), so an App Store build leaves the `audio` background mode out of its
/// Info.plist, and with it this. It mixes with other audio, so your own music keeps playing, and
/// stops when the app comes back to the front, where it isn't needed.
@MainActor
final class BackgroundKeepAlive {
    private static let log = Logger(subsystem: "com.kevinross.Mimamori.Companion", category: "keep-alive")

    /// Whether this build may keep running in the background: only with the `audio` background
    /// mode, which the App Store configuration's Info.plist leaves out. The plist is the one switch,
    /// so the setting and the keep-alive can't disagree with what the build declares.
    static let isAvailable: Bool = {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return modes.contains("audio")
    }()

    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private var heartbeat: Task<Void, Never>?
    private let log = BackgroundLog.shared

    var isRunning: Bool { player != nil }

    func start() {
        guard player == nil else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        // A call or Siri stops the audio; play again once it's over.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: .main) { [weak self] note in
            let info = note.userInfo
            let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let reason = (info?[AVAudioSessionInterruptionReasonKey] as? UInt).flatMap(AVAudioSession.InterruptionReason.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                if type == .ended {
                    self?.log.add(.audio, "Audio interruption ended\(options.contains(.shouldResume) ? "" : " (iOS didn't say to resume)"): playing silence again")
                    self?.play()
                } else {
                    self?.log.add(.audio, "Audio interruption began (\(Self.describe(reason))): the silence stopped, and the app keeps running only until iOS suspends it")
                }
            }
        })
        // The audio system restarted: everything set up before is gone.
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log.add(.audio, "The audio system restarted: playing silence again")
                self?.play()
            }
        })
        // Headphones, CarPlay or a speaker came or went.
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session,
                                            queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log.add(.audio, "Audio route changed (\(Self.describe(reason))); silence \(self.player?.isPlaying == true ? "still playing" : "NOT playing")")
            }
        })
        // Another app started or stopped audio of its own.
        observers.append(center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: session,
                                            queue: .main) { [weak self] note in
            let begins = (note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt)
                .flatMap(AVAudioSession.SilenceSecondaryAudioHintType.init) == .begin
            MainActor.assumeIsolated {
                self?.log.add(.audio, begins ? "Another app started playing audio" : "Another app stopped playing audio")
            }
        })
        log.add(.keepAlive, "Went to the background: staying connected")
        play()
        beat()
    }

    func stop() {
        guard player != nil || !observers.isEmpty else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        heartbeat?.cancel()
        heartbeat = nil
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        log.add(.keepAlive, "Stopped staying connected in the background")
    }

    /// Beats every minute while running, so a silence in the log shows when iOS suspended the app;
    /// every hour it also says it's still running, and whether the silence is still playing.
    private func beat() {
        heartbeat?.cancel()
        log.heartbeat()
        heartbeat = Task { [weak self] in
            var minutes = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(CompanionEventLog.heartbeatInterval))
                guard !Task.isCancelled, let self else { return }
                minutes += 1
                self.log.heartbeat()
                let playing = self.player?.isPlaying == true
                if !playing {
                    self.log.add(.keepAlive, "The silence isn't playing: starting it again")
                    self.play()
                } else if minutes % 60 == 0 {
                    self.log.add(.keepAlive, "Still running in the background (\(minutes / 60) h)")
                }
            }
        }
    }

    private func play() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silence)
            player.numberOfLoops = -1
            player.volume = 0.0001
            let started = player.play()
            self.player = player
            Self.log.notice("Playing silence to stay connected in the background")
            if !started { log.add(.keepAlive, "The silence didn't start playing") }
        } catch {
            Self.log.error("Couldn't keep running in the background: \(error.localizedDescription, privacy: .public)")
            log.add(.keepAlive, "Couldn't play the silence: \(error.localizedDescription)")
        }
    }

    private static func describe(_ reason: AVAudioSession.InterruptionReason?) -> String {
        switch reason {
        case .default?: "a call, an alarm, Siri or another app's audio"
        case .appWasSuspended?: "iOS had suspended the app"
        case .builtInMicMuted?: "the built-in mic was muted"
        case .routeDisconnected?: "the audio route disconnected"
        default: "no reason given"
        }
    }

    private static func describe(_ reason: AVAudioSession.RouteChangeReason?) -> String {
        switch reason {
        case .newDeviceAvailable?: "a new device"
        case .oldDeviceUnavailable?: "a device went away"
        case .categoryChange?: "category changed"
        case .override?: "override"
        case .wakeFromSleep?: "woke from sleep"
        case .noSuitableRouteForCategory?: "no route for playback"
        case .routeConfigurationChange?: "configuration changed"
        default: "other"
        }
    }

    /// A WAV file holding one silent sample: 16-bit mono at 44.1 kHz, looped.
    private static let silence: Data = {
        func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
        let rate: UInt32 = 44_100, channels: UInt16 = 1, bits: UInt16 = 16
        let samples: [UInt8] = [0, 0]
        var wav: [UInt8] = Array("RIFF".utf8) + bytes(UInt32(36 + samples.count)) + Array("WAVE".utf8)
        wav += Array("fmt ".utf8) + bytes(UInt32(16)) + bytes(UInt16(1)) + bytes(channels) + bytes(rate)
        wav += bytes(rate * UInt32(channels) * UInt32(bits / 8)) + bytes(channels * bits / 8) + bytes(bits)
        wav += Array("data".utf8) + bytes(UInt32(samples.count)) + samples
        return Data(wav)
    }()
}
