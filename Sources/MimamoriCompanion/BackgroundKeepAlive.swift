import AVFoundation
import os

/// Keeps the app running in the background by playing silence, so it stays connected to the Mac
/// and can tell you when an agent needs you. iOS doesn't suspend an app that is playing audio.
///
/// For builds of your own only: App Review allows background audio only for audio you can hear
/// (guideline 2.5.4), so an App Store build leaves the `audio` background mode and this out. It
/// mixes with other audio, so your own music keeps playing, and stops when the app comes back to
/// the front, where it isn't needed.
@MainActor
final class BackgroundKeepAlive {
    private static let log = Logger(subsystem: "com.kevinross.Mimamori.Companion", category: "keep-alive")

    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []

    var isRunning: Bool { player != nil }

    func start() {
        guard player == nil else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        // A call or Siri stops the audio; play again once it's over.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            guard type == .ended else { return }
            MainActor.assumeIsolated { self?.play() }
        })
        // The audio system restarted: everything set up before is gone.
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.play() }
        })
        play()
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func play() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silence)
            player.numberOfLoops = -1
            player.volume = 0.0001
            player.play()
            self.player = player
            Self.log.notice("Playing silence to stay connected in the background")
        } catch {
            Self.log.error("Couldn't keep running in the background: \(error.localizedDescription, privacy: .public)")
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
