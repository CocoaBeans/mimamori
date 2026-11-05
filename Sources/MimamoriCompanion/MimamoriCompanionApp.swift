import MimamoriShared
import SwiftUI

/// Mimamori's iPhone companion: the agents at work on your Mac, and who needs you.
@main
struct MimamoriCompanionApp: App {
    @State private var model = CompanionModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AgentsScreen(model: model)
                .task { model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.resume() }
                }
        }
    }
}

/// The agents on the connected Mac, the most pressing first, drawn as the widget's rows.
struct AgentsScreen: View {
    let model: CompanionModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusRow(model: model)
                }
                if let snapshot = model.snapshot, model.connectedMac != nil {
                    Section {
                        if snapshot.agents.isEmpty {
                            Text("No agents at work.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(snapshot.agents) { agent in
                            AgentRowView(agent: agent, detailed: true)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(agent.worktree), \(agent.agent), \(agent.status)")
                        }
                    } header: {
                        Text(summary(of: snapshot))
                    }
                }
            }
            .navigationTitle("Agents")
            .refreshable { model.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    MacPicker(model: model)
                }
            }
        }
    }

    private func summary(of snapshot: AgentWidgetSnapshot) -> String {
        var parts: [String] = []
        if snapshot.needingYou > 0 { parts.append("\(snapshot.needingYou) need you") }
        if snapshot.working > 0 { parts.append("\(snapshot.working) working") }
        return parts.isEmpty ? "\(snapshot.agents.count) agents" : parts.joined(separator: " · ")
    }
}

/// Which Mac, whether it's connected, and how quickly the last change arrived.
private struct StatusRow: View {
    let model: CompanionModel

    var body: some View {
        switch model.status {
        case .searching:
            Label("Looking for a Mac running Mimamori…", systemImage: "magnifyingglass")
        case .connecting(let name):
            Label("Connecting to \(name)…", systemImage: "network")
        case .connected(let name):
            VStack(alignment: .leading, spacing: 2) {
                Label(name, systemImage: "desktopcomputer")
                if let receivedAt = model.receivedAt, let delay = model.delay {
                    Text("Updated \(receivedAt.formatted(date: .omitted, time: .standard)), \(Self.milliseconds(delay)) after the Mac sent it")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .unavailable(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private static func milliseconds(_ interval: TimeInterval) -> String {
        "\(max(0, Int((interval * 1000).rounded()))) ms"
    }
}

/// The Macs found on the network, to switch between.
private struct MacPicker: View {
    let model: CompanionModel

    var body: some View {
        Menu {
            if model.macs.isEmpty {
                Text("No Macs found")
            }
            ForEach(model.macs) { mac in
                Button {
                    model.connect(to: mac)
                } label: {
                    if mac.name == model.connectedMac {
                        Label(mac.name, systemImage: "checkmark")
                    } else {
                        Text(mac.name)
                    }
                }
            }
        } label: {
            Image(systemName: "desktopcomputer")
        }
        .help("Choose a Mac")
        .accessibilityLabel("Choose a Mac")
    }
}
