import Foundation
import VigilCore
import WidgetKit

/// Keeps the desktop widgets' snapshot current: writes it to the App Group container the widget
/// extension reads, and asks WidgetKit to reload. WidgetKit limits reloads, so it writes at once
/// only when who needs you changes, otherwise at most every 10 s, and only when what the widgets
/// show has changed; a heartbeat every 15 minutes lets them tell a quiet Vigil from a gone one.
@MainActor
final class WidgetPublisher {
    private static let minimumInterval: TimeInterval = 10
    private static let heartbeat: TimeInterval = 15 * 60

    private var shown: [AgentWidgetSnapshot.Agent]?
    private var needingYou: Set<String> = []
    private var lastWriteAt = Date.distantPast
    private var pending: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var latest: [AgentWidgetSnapshot.Agent] = []

    init() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeat))
                guard let self, !Task.isCancelled else { return }
                self.write(self.latest)
            }
        }
    }

    /// The agents as they are now, the most pressing first.
    func update(_ agents: [AgentWidgetSnapshot.Agent]) {
        latest = agents
        guard agents != shown else { return }
        let waiting = Set(agents.filter { $0.state == .needsYou || $0.collision != nil }.map(\.id))
        if waiting != needingYou || shown == nil {
            write(agents)
            return
        }
        guard pending == nil else { return }
        let wait = max(0, Self.minimumInterval - Date().timeIntervalSince(lastWriteAt))
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.write(self.latest)
        }
    }

    /// Vigil is quitting: the widgets say so instead of showing states nobody keeps current.
    func vigilQuitting() {
        write(latest, running: false)
    }

    private func write(_ agents: [AgentWidgetSnapshot.Agent], running: Bool = true) {
        pending?.cancel()
        pending = nil
        guard let url = AgentWidgetSnapshot.fileURL else { return }
        let snapshot = AgentWidgetSnapshot(writtenAt: Date(), vigilRunning: running, agents: agents)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try snapshot.encoded().write(to: url, options: .atomic)
        } catch {
            NSLog("Vigil: could not write the widget snapshot: \(error)")
            return
        }
        shown = agents
        needingYou = Set(agents.filter { $0.state == .needsYou || $0.collision != nil }.map(\.id))
        lastWriteAt = snapshot.writtenAt
        WidgetCenter.shared.reloadTimelines(ofKind: AgentWidgetSnapshot.widgetKind)
    }
}
