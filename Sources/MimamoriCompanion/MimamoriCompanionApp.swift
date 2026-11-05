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

/// The agents on the connected Mac in the Agents window's groups, as its cards: detailed, or
/// compact, as the toolbar's switch says.
struct AgentsScreen: View {
    let model: CompanionModel
    @AppStorage("showsDetails") private var detailed = true
    @AppStorage("collapsedGroups") private var collapsedGroups = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    StatusRow(model: model)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if let snapshot = model.snapshot, model.connectedMac != nil {
                        if snapshot.agents.isEmpty {
                            Text("No agents at work.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        // Steps' ages and the timeline's end move with the clock.
                        TimelineView(.periodic(from: .now, by: 5)) { context in
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(AgentGroup.group(snapshot.agents), id: \.group) { entry in
                                    let collapsed = isCollapsed(entry.group)
                                    AgentGroupHeader(group: entry.group, agents: entry.agents, collapsed: collapsed) {
                                        toggle(entry.group)
                                    }
                                    .padding(.top, 6)
                                    if !collapsed {
                                        ForEach(entry.agents) { agent in
                                            AgentCardView(agent: agent, detailed: detailed, now: context.date)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .animation(.easeOut(duration: 0.2), value: model.snapshot?.agents.map(\.id))
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Agents")
            .refreshable { model.refresh() }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Toggle(isOn: $detailed) {
                        Label("Details", systemImage: "rectangle.grid.1x2")
                    }
                    .help(detailed ? "Showing each agent's task, steps and files. Tap for one line per agent." : "Show each agent's task, recent steps and files")
                    .accessibilityLabel("Details")
                    MacPicker(model: model)
                }
            }
        }
    }

    private func isCollapsed(_ group: AgentGroup) -> Bool {
        collapsedGroups.split(separator: ",").contains(Substring(String(group.rawValue)))
    }

    /// Folds a group to its header, or opens it; remembered across launches.
    private func toggle(_ group: AgentGroup) {
        var keys = Set(collapsedGroups.split(separator: ",").map(String.init))
        let key = String(group.rawValue)
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        withAnimation(.easeOut(duration: 0.2)) { collapsedGroups = keys.sorted().joined(separator: ",") }
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
