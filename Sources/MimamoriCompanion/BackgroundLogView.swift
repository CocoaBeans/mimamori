import MimamoriShared
import SwiftUI

/// The background log, newest first: what the app did while you weren't looking, and when it
/// stopped running. Share sends it as text, to look into a Live Activity that went stale.
struct BackgroundLogView: View {
    let log: BackgroundLog
    @State private var clearing = false

    var body: some View {
        List {
            if log.log.entries.isEmpty {
                Text("Nothing yet. Entries appear as the app comes and goes, connects, and runs in the background.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sections, id: \.day) { section in
                Section(section.day) {
                    ForEach(section.entries) { entry in
                        EntryRow(entry: entry)
                    }
                }
            }
        }
        .navigationTitle("Background Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ShareLink(item: log.log.text()) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .help("Share the log as text")
                .accessibilityLabel("Share the log")
                .disabled(log.log.entries.isEmpty)
                Button("Clear", systemImage: "trash", role: .destructive) { clearing = true }
                    .help("Clear the log")
                    .accessibilityLabel("Clear the log")
                    .disabled(log.log.entries.isEmpty)
            }
        }
        .confirmationDialog("Clear the background log?", isPresented: $clearing, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { log.clear() }
        }
    }

    /// Entries by day, newest first.
    private var sections: [(day: String, entries: [CompanionEventLog.Entry])] {
        let calendar = Calendar.current
        var days: [(day: String, entries: [CompanionEventLog.Entry])] = []
        for entry in log.log.entries.reversed() {
            let day = calendar.isDateInToday(entry.date) ? "Today"
                : calendar.isDateInYesterday(entry.date) ? "Yesterday"
                : entry.date.formatted(date: .abbreviated, time: .omitted)
            if days.last?.day == day { days[days.count - 1].entries.append(entry) } else { days.append((day, [entry])) }
        }
        return days
    }
}

private struct EntryRow: View {
    let entry: CompanionEventLog.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.subheadline)
                Text(entry.date.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch entry.kind {
        case .app: "app"
        case .keepAlive: "speaker.wave.1"
        case .audio: "waveform"
        case .connection: "network"
        case .liveActivity: "platter.filled.bottom.iphone"
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .app: .primary
        case .keepAlive: .green
        case .audio: .orange
        case .connection: .blue
        case .liveActivity: .purple
        }
    }
}
