import MimamoriShared
import SwiftUI
import UIKit

/// Mimamori's iPhone companion: the agents at work on your Mac, and who needs you.
@main
struct MimamoriCompanionApp: App {
    @State private var model = CompanionModel()
    @State private var keepAlive = BackgroundKeepAlive()
    @AppStorage(CompanionNotificationSetting.staysConnected) private var staysConnected = false
    @State private var screen = ScreenKeeper()
    @AppStorage(ScreenKeeper.keepsScreenOn) private var keepsScreenOn = false
    @AppStorage(ScreenKeeper.onlyWhileCharging) private var onlyWhileCharging = true
    @Environment(\.scenePhase) private var scenePhase

    private var screenStaysOn: Bool {
        ScreenKeeper.staysOn(asked: keepsScreenOn, onlyWhileCharging: onlyWhileCharging,
                             active: scenePhase == .active, charging: screen.isCharging)
    }

    var body: some Scene {
        WindowGroup {
            AgentsScreen(model: model)
                .task {
                    model.start()
                    #if DEBUG
                    // For scripted runs: `-pairingLink <link>` pairs as opening the link does.
                    if let link = UserDefaults.standard.string(forKey: "pairingLink"), let url = URL(string: link) {
                        model.pair(with: url)
                    }
                    #endif
                }
                // The Mac's pairing code, opened from the Camera.
                .onOpenURL { url in model.pair(with: url) }
                .onChange(of: screenStaysOn, initial: true) { _, on in
                    UIApplication.shared.isIdleTimerDisabled = on
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        let keptAlive = keepAlive.isRunning
                        keepAlive.stop()
                        model.resume(keptAlive: keptAlive)
                    case .background:
                        // Staying connected, the app keeps running and tells you as agents change;
                        // otherwise iOS suspends it, so it lets go of the Mac first.
                        if staysConnected, model.chosen != nil {
                            keepAlive.start()
                        } else {
                            model.suspend()
                        }
                    default:
                        break
                    }
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
    @State private var showingSettings = false

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
                        // Steps' ages and the timeline's end move with the clock. A plain stack, and
                        // cards keyed by group too: a lazy stack kept showing a card in the group it
                        // had left, under that group's old count.
                        TimelineView(.periodic(from: .now, by: 5)) { context in
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(AgentGroup.group(snapshot.agents), id: \.group) { entry in
                                    let collapsed = isCollapsed(entry.group)
                                    AgentGroupHeader(group: entry.group, agents: entry.agents, collapsed: collapsed) {
                                        toggle(entry.group)
                                    }
                                    .padding(.top, 6)
                                    if !collapsed {
                                        ForEach(entry.agents) { agent in
                                            AgentCardView(agent: agent, detailed: detailed, now: context.date,
                                                          answer: agent.permissionRequest.flatMap { model.answers[$0.id] }) { allow in
                                                if let request = agent.permissionRequest {
                                                    Task { await model.answer(request, allow: allow) }
                                                }
                                            }
                                            .id("\(entry.group.rawValue) \(agent.id)")
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
            .sheet(isPresented: $showingSettings) {
                CompanionSettingsSheet(notifier: model.notifier)
            }
            .alert("Paired with \(model.justPaired?.name ?? "your Mac")", isPresented: Binding(
                get: { model.justPaired != nil }, set: { if !$0 { model.dismissJustPaired() } })) {
                Button("OK") { model.dismissJustPaired() }
            } message: {
                Text("Its agents show here whenever this iPhone is on the same network.")
            }
            .refreshable { model.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .help("Notifications, and staying connected in the background")
                    .accessibilityLabel("Settings")
                }
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
        case .unpaired:
            PairingHelp()
        case .searching:
            Label(model.pairing.map { "Finishing pairing: looking for \($0.name) on this network…" }
                  ?? "Looking for \(model.chosen?.name ?? "your Mac") on this network…",
                  systemImage: "magnifyingglass")
        case .connecting(let name):
            Label(model.pairing != nil ? "Finishing pairing with \(name)…" : "Connecting to \(name)…", systemImage: "network")
        case .connected(let name):
            VStack(alignment: .leading, spacing: 2) {
                Label(name, systemImage: "lock.desktopcomputer")
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

/// How to pair, before any Mac is.
private struct PairingHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Pair with your Mac", systemImage: "desktopcomputer.and.iphone")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. On your Mac, open Mimamori › Settings › iPhone and turn on Show agents on your iPhone.")
                Text("2. Choose Pair iPhone…")
                Text("3. Point this iPhone's Camera at the code, and tap the link to open it here.")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text("Your iPhone and Mac need to be on the same network.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// The paired Macs, to switch between or forget.
private struct MacPicker: View {
    let model: CompanionModel
    @State private var forgetting: PairedMac?

    var body: some View {
        Menu {
            ForEach(model.pairedMacs) { mac in
                Button {
                    model.choose(mac)
                } label: {
                    if mac.macID == model.chosen?.macID {
                        Label(mac.name, systemImage: "checkmark")
                    } else if model.foundMacs[mac.macID] == nil {
                        Text("\(mac.name) (not found)")
                    } else {
                        Text(mac.name)
                    }
                }
            }
            if let chosen = model.chosen {
                Divider()
                Button("Forget \(chosen.name)…", systemImage: "xmark.circle", role: .destructive) {
                    forgetting = chosen
                }
            }
        } label: {
            Image(systemName: "desktopcomputer")
        }
        .disabled(model.pairedMacs.isEmpty)
        .help("Choose a Mac")
        .accessibilityLabel("Choose a Mac")
        .confirmationDialog("Forget \(forgetting?.name ?? "this Mac")?", isPresented: Binding(
            get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                if let forgetting { model.forget(forgetting) }
                forgetting = nil
            }
        } message: {
            Text("To see its agents again, pair again from the Mac. Remove this iPhone there too, in Mimamori › Settings › iPhone.")
        }
    }
}
