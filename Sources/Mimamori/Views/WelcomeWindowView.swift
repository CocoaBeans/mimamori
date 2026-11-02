import AppKit
import SwiftUI
import MimamoriCore

/// The first launch: what Mimamori watches and writes, what hooks are and which files connecting
/// an agent changes, before anything is installed. Help › Welcome to Mimamori brings it back.
struct WelcomeWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @State private var claudeConnected = HookInstaller.isInstalled()
    @State private var hermesState = HermesHookInstaller.state()
    @State private var claudeMessage: String?
    @State private var hermesMessage: String?

    private var claudePresent: Bool {
        FileManager.default.fileExists(atPath: HookInstaller.settingsURL.deletingLastPathComponent().path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Mimamori")
                        .font(.title.weight(.semibold))
                    Text("It keeps watch over your git worktrees while coding agents work in them: what they are doing right now, and whether you should worry.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            step(1, "Watch a repository") {
                Text("Mimamori reads the files and runs git in the repositories you add, and follows every worktree in them. It never changes your code, branches or index. It does save snapshots of the working tree, as commits under refs/monitor/ in the repository, so you can compare against earlier moments.")
                HStack(spacing: 10) {
                    Button("Add Repository…") { model.promptForRepository() }
                    if !model.repositories.isEmpty {
                        Label(watching, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Text("Or drop a folder on Mimamori's Dock icon, or run open -a Mimamori <folder>.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            step(2, "Connect your agents (optional)") {
                Text("Mimamori spots agents by their processes with no setup at all. Hooks tell it exactly what each one is doing: every prompt and tool call, and when one needs your permission. A hook is a command the agent runs at each step; Mimamori's passes the step to Mimamori through a socket only you can reach, so nothing leaves your Mac.")
                if claudePresent {
                    connectRow(name: "Claude Code", connected: claudeConnected, action: connectClaude,
                               detail: "Adds Mimamori's entries to \(Format.abbreviate(path: HookInstaller.settingsURL.path)). The file as it was is saved beside it first, and your own hooks stay as they are.",
                               message: claudeMessage)
                }
                if hermesState != .notPresent {
                    connectRow(name: "Hermes", connected: hermesState == .installed, action: connectHermes,
                               detail: "Writes a small script to \(Format.abbreviate(path: HermesHookInstaller.scriptURL.path)) and a marked block in \(Format.abbreviate(path: HermesHookInstaller.configURL.path)), after a backup. Hermes asks you to approve them once.",
                               message: hermesMessage)
                }
                HStack(spacing: 4) {
                    Text("Codex, Gemini CLI, Cursor and others take a setup you paste in.")
                    Button("Other Agents…") {
                        model.settingsTab = .agents
                        openSettings()
                    }
                    .buttonStyle(.link)
                }
                .font(.callout)
                Text("Remove them any time in Settings › Agents › Hooks. Mimamori › Uninstall Mimamori… takes away everything Mimamori added.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Agents at work show in the menu bar and the Agents window (⇧⌘A).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismissWindow(id: "welcome") }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { model.finishWelcome() }
    }

    private var watching: String {
        let names = model.repositories.map(\.displayName)
        return "Watching " + (names.count <= 2 ? names.joined(separator: " and ") : "\(names[0]) and \(names.count - 1) more")
    }

    private func step(_ number: Int, _ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connectRow(name: String, connected: Bool, action: @escaping () -> Void, detail: String, message: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(name).fontWeight(.medium)
                Spacer()
                if connected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Connect \(name)", action: action)
                }
            }
            Text(message ?? detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func connectClaude() {
        do {
            let backup = try HookInstaller.install(socketPath: model.agentHub.socketPath)
            claudeConnected = HookInstaller.isInstalled()
            claudeMessage = "Connected. New Claude Code sessions report to Mimamori. The file as it was is saved as \(backup.lastPathComponent)."
            Log.hooks.notice("Installed Claude Code's hooks from the welcome window; previous settings saved to \(backup.path)")
        } catch {
            claudeMessage = "Could not connect: \(error.localizedDescription)"
        }
    }

    private func connectHermes() {
        do {
            if let backup = try HermesHookInstaller.install(socketPath: model.agentHub.socketPath) {
                hermesMessage = "Installed, with config.yaml saved as \(backup.lastPathComponent). Approve the hooks in Hermes next: Settings › Agents › Hooks shows how."
                Log.hooks.notice("Installed Hermes's hooks from the welcome window; previous config saved to \(backup.path)")
            } else {
                Workspace.copy(HermesHookInstaller.snippet)
                hermesMessage = "Your config.yaml has hooks of its own, so Mimamori left it alone and copied its entries: paste them under hooks:. Settings › Agents › Hooks has the details."
            }
            hermesState = HermesHookInstaller.state()
        } catch {
            hermesMessage = "Could not connect: \(error.localizedDescription)"
        }
    }
}
