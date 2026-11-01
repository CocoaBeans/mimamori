import AppIntents
import SwiftUI
import MimamoriCore
import WidgetKit

/// The desktop widgets: Mimamori's agents at a glance. The extension runs sandboxed in its own
/// process; Mimamori hands it a snapshot through their shared App Group container and asks
/// WidgetKit to reload whenever its agents change.
@main
struct MimamoriWidgets: WidgetBundle {
    var body: some Widget {
        AgentsWidget()
    }
}

/// What each placed widget is set to show; edited with Edit Widget.
struct AgentsWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Agents"
    static let description = IntentDescription("Your coding agents: who needs you, and what each is doing.")

    @Parameter(title: "Show tasks and steps", default: true)
    var showDetails: Bool

    @Parameter(title: "Only agents that need me", default: false)
    var onlyNeedsYou: Bool

    var options: AgentsWidgetOptions {
        AgentsWidgetOptions(showDetails: showDetails, onlyNeedsYou: onlyNeedsYou)
    }
}

struct AgentsEntry: TimelineEntry {
    let date: Date
    let snapshot: AgentWidgetSnapshot?
    let options: AgentsWidgetOptions
}

struct AgentsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AgentsEntry {
        AgentsEntry(date: .now, snapshot: .sample, options: AgentsWidgetOptions())
    }

    func snapshot(for configuration: AgentsWidgetIntent, in context: Context) async -> AgentsEntry {
        // The gallery shows sample agents until Mimamori has written its own.
        AgentsEntry(date: .now, snapshot: AgentWidgetSnapshot.load() ?? (context.isPreview ? .sample : nil),
                    options: configuration.options)
    }

    func timeline(for configuration: AgentsWidgetIntent, in context: Context) async -> Timeline<AgentsEntry> {
        let entry = AgentsEntry(date: .now, snapshot: AgentWidgetSnapshot.load(), options: configuration.options)
        // Mimamori asks for a reload when its agents change. This one only notices it going quiet,
        // so the widget can say Mimamori isn't running rather than show stale states.
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60)))
    }
}

struct AgentsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: AgentWidgetSnapshot.widgetKind, intent: AgentsWidgetIntent.self, provider: AgentsProvider()) { entry in
            AgentsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Agents")
        .description("Your coding agents at a glance: who needs you, and what each is doing.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct AgentsWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AgentsEntry

    var body: some View {
        AgentsWidgetView(snapshot: entry.snapshot, family: family, options: entry.options, now: entry.date)
    }
}
