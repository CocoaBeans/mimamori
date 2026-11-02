import Foundation
import Observation
#if canImport(Sparkle)
import Sparkle
#endif

/// New versions, through Sparkle, in release builds only: `Scripts/release.sh` marks them
/// (Info.plist's `MimamoriReleaseBuild`), so a build of your own never offers to replace itself
/// with a release. Sparkle asks before it first checks by itself; until you say yes, it checks
/// only when you choose Check for Updates.
///
/// `swift run` builds have no Sparkle (the package leaves it out), and no updates.
@MainActor
@Observable
final class Updates {
    /// Whether this build updates itself.
    let isEnabled: Bool
    /// False while a check is under way.
    private(set) var canCheck = false

    /// Whether Sparkle looks for a new version once a day by itself.
    var checksAutomatically = false {
        didSet {
            #if canImport(Sparkle)
            if controller?.updater.automaticallyChecksForUpdates != checksAutomatically {
                controller?.updater.automaticallyChecksForUpdates = checksAutomatically
            }
            #endif
        }
    }

    /// Whether a version found by itself is downloaded and installed when Mimamori quits,
    /// rather than offered first.
    var installsAutomatically = false {
        didSet {
            #if canImport(Sparkle)
            if controller?.updater.automaticallyDownloadsUpdates != installsAutomatically {
                controller?.updater.automaticallyDownloadsUpdates = installsAutomatically
            }
            #endif
        }
    }

    #if canImport(Sparkle)
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    #endif

    init() {
        isEnabled = Bundle.main.object(forInfoDictionaryKey: "MimamoriReleaseBuild") as? String == "YES"
        #if canImport(Sparkle)
        guard isEnabled else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        // Sparkle changes these itself too: when a check starts or ends, and when you answer
        // its question about checking by itself. Each value comes with the change, since the
        // updater's own properties belong to the main actor and these closures don't.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in self?.canCheck = value }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in if self?.checksAutomatically != value { self?.checksAutomatically = value } }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in if self?.installsAutomatically != value { self?.installsAutomatically = value } }
            },
        ]
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
        controller?.checkForUpdates(nil)
        #endif
    }

    /// When Sparkle last looked, if it has.
    var lastCheck: Date? {
        #if canImport(Sparkle)
        controller?.updater.lastUpdateCheckDate
        #else
        nil
        #endif
    }
}
