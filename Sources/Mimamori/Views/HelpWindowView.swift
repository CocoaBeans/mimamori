import AppKit
import SwiftUI
import MimamoriCore

/// Help › Mimamori Help (⌘?): a short guide, one topic at a time, beside your work. The topics
/// live in `HelpTopics.swift`.
struct HelpWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var selection: Binding<HelpTopic.ID?> {
        Binding(get: { model.helpTopic }, set: { if let id = $0 { model.helpTopic = id } })
    }

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.all, selection: selection) { topic in
                Label(topic.title, systemImage: topic.symbol)
                    .help(topic.summary)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            page(HelpTopic.topic(model.helpTopic))
        }
        .frame(minWidth: 640, minHeight: 420)
        // [text](help:<id>) in a topic goes to that topic.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "help" else { return .systemAction }
            if let id = HelpTopic.ID(rawValue: String(url.absoluteString.dropFirst("help:".count))) {
                model.helpTopic = id
            }
            return .handled
        })
    }

    private func page(_ topic: HelpTopic) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(topic.title, systemImage: topic.symbol)
                        .font(.title.weight(.semibold))
                    Text(topic.summary)
                        .foregroundStyle(.secondary)
                }
                MarkdownPreview(markdown: topic.markdown, dimsParagraphs: false)
                if !topic.actions.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(topic.actions, id: \.self) { action in
                            Button(action.title) { perform(action) }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A new topic starts at its top.
        .id(topic.id)
        .navigationTitle("Mimamori Help")
    }

    private func perform(_ action: HelpAction) {
        switch action {
        case .addRepository: model.promptForRepository()
        case .welcome: openWindow(id: "welcome")
        case .agentsWindow: openWindow(id: "agents")
        case .settings(let tab, _):
            model.settingsTab = tab
            openSettings()
        case .copyDiagnostics: model.copyDiagnostics()
        case .uninstall:
            openWindow(id: "uninstall")
            NSApplication.shared.activate()
        }
    }
}
