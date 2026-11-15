import SwiftUI

// Shared with the iPhone companion, whose cards show the same clocks.
enum AgentClockText {
    /// ["turn 4m", "session 1h 12m"]: how long the turn under way, or the last one, and the session
    /// have run. The timer pill restarts at each step; these do not. `sessionEndedAt` stops the
    /// session's clock once it has ended.
    static func parts(turnStartedAt: Date?, turnEndedAt: Date?, turnUnderway: Bool,
                      sessionStartedAt: Date?, sessionEndedAt: Date?, now: Date) -> [String] {
        var parts: [String] = []
        if let start = turnStartedAt {
            if turnUnderway {
                parts.append("turn \(Format.duration(since: start, to: now))")
            } else if let end = turnEndedAt, end >= start {
                parts.append("last turn \(Format.duration(since: start, to: end))")
            }
        }
        if let start = sessionStartedAt {
            parts.append("session \(Format.duration(since: start, to: sessionEndedAt ?? now))")
        }
        return parts
    }

    static let help = "Turn: since the prompt the agent is working on, or how long the last one took. Session: since the session started; for one that started before Mimamori, since its process started or Mimamori first heard from it."
}

/// "turn 4m · session 1h 12m", for an agent's card. Short of room, the session's clock goes, then both.
struct AgentClocks: View {
    let parts: [String]

    var body: some View {
        if let first = parts.first {
            ViewThatFits(in: .horizontal) {
                label(parts)
                label([first])
                EmptyView()
            }
            .help(AgentClockText.help)
        }
    }

    private func label(_ parts: [String]) -> some View {
        Label(parts.joined(separator: " · "), systemImage: "clock")
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel(parts.joined(separator: ", "))
    }
}
