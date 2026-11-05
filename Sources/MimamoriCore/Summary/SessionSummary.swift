import Foundation

/// What a session summary covers for one worktree. The app gathers it; `markdown(options:)`
/// writes it up for a pull request description or a handoff note.
public struct SessionSummary: Sendable {
    public struct File: Sendable, Hashable {
        public var change: FileChange
        public var review: ReviewStatus
        public var attribution: ChangeAttribution?

        public init(change: FileChange, review: ReviewStatus = .unreviewed, attribution: ChangeAttribution? = nil) {
            self.change = change
            self.review = review
            self.attribution = attribution
        }
    }

    public struct Agent: Sendable, Hashable {
        public var names: [String]
        /// What the agent is doing now, in words: "ready for your next prompt".
        public var state: String?
        /// The feed records tool calls according to a setting; this names what it counted
        /// ("edits and commands", "tool calls"), or nil when it records none.
        public var toolCallNoun: String?

        public init(names: [String], state: String? = nil, toolCallNoun: String? = "tool calls") {
            self.names = names
            self.state = state
            self.toolCallNoun = toolCallNoun
        }
    }

    public var title: String
    public var repository: String
    public var worktreePath: String
    public var baselineLabel: String
    public var generatedAt: Date
    public var files: [File]
    public var commits: [CommitSummary]
    /// This worktree's feed entries in the session, oldest first.
    public var activity: [ActivityEntry]
    /// Where Mimamori's record of the session begins.
    public var activitySince: Date?
    public var agent: Agent?
    /// Unified patches by path, when diffs were asked for.
    public var diffs: [String: String]
    public var excludedLargeFiles: [String]

    public init(title: String, repository: String, worktreePath: String, baselineLabel: String,
                generatedAt: Date = Date(), files: [File], commits: [CommitSummary] = [],
                activity: [ActivityEntry] = [], activitySince: Date? = nil, agent: Agent? = nil,
                diffs: [String: String] = [:], excludedLargeFiles: [String] = []) {
        self.title = title
        self.repository = repository
        self.worktreePath = worktreePath
        self.baselineLabel = baselineLabel
        self.generatedAt = generatedAt
        self.files = files
        self.commits = commits
        self.activity = activity
        self.activitySince = activitySince
        self.agent = agent
        self.diffs = diffs
        self.excludedLargeFiles = excludedLargeFiles
    }
}

public struct SessionSummaryOptions: Sendable, Hashable, Codable {
    public var attention = true
    public var files = true
    public var unreviewed = true
    public var commits = true
    public var activity = true
    public var diffs = false
    /// Diff lines included in all, so a summary stays pasteable.
    public var maxDiffLines = 3000
    /// Most recent agent activity entries listed.
    public var maxActivityEntries = 150

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SessionSummaryOptions()
        attention = c.decode(.attention, or: defaults.attention)
        files = c.decode(.files, or: defaults.files)
        unreviewed = c.decode(.unreviewed, or: defaults.unreviewed)
        commits = c.decode(.commits, or: defaults.commits)
        activity = c.decode(.activity, or: defaults.activity)
        diffs = c.decode(.diffs, or: defaults.diffs)
        maxDiffLines = c.decode(.maxDiffLines, or: defaults.maxDiffLines)
        maxActivityEntries = c.decode(.maxActivityEntries, or: defaults.maxActivityEntries)
    }
}

// MARK: Counting

extension SessionSummary {
    public struct AgentCounts: Sendable, Hashable {
        public var turns = 0
        public var toolCalls = 0
        public var permissionRequests = 0
        public var questions = 0
    }

    /// Agent work recorded in the feed during the session.
    public var agentCounts: AgentCounts {
        var counts = AgentCounts()
        for entry in activity {
            switch entry.kind {
            case .agentTurn where entry.title.hasSuffix("started a turn"): counts.turns += 1
            case .agentTool: counts.toolCalls += 1
            case .agentAttention where entry.title.contains("needs permission"): counts.permissionRequests += 1
            case .agentAttention where entry.title.contains("question"): counts.questions += 1
            default: break
            }
        }
        return counts
    }

    /// The feed entries a summary lists: agent work and repository events, not the
    /// file-by-file churn the Files section already covers.
    public var notableActivity: [ActivityEntry] {
        activity.filter { entry in
            switch entry.kind {
            case .agentSession, .agentTurn, .agentTool, .agentAttention,
                 .committed, .branchChanged, .headMoved, .started: true
            default: false
            }
        }
    }
}

// MARK: Markdown

extension SessionSummary {
    public func markdown(options: SessionSummaryOptions = SessionSummaryOptions(),
                         timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        var writer = MarkdownWriter(timeZone: timeZone, locale: locale)
        let changes = files.map(\.change)
        let flagged = files.filter { $0.change.isFlagged }
            .sorted { ($0.change.maxSeverity?.rawValue ?? 0, $1.change.path) > ($1.change.maxSeverity?.rawValue ?? 0, $0.change.path) }
        let reviewed = files.filter { $0.review.isReviewed }.count
        let unreviewed = files.filter { !$0.review.isReviewed }

        writer.line("# Session summary: \(title)")
        writer.blank()
        var context = ["**\(repository)**", code(abbreviated(worktreePath)), "changes \(baselinePhrase)"]
        context.append("generated \(writer.dateTime(generatedAt))")
        writer.line(context.joined(separator: " · "))
        writer.blank()

        writer.heading("Overview")
        if changes.isEmpty {
            writer.line("- **No changes** \(baselinePhrase).")
        } else {
            writer.line("- **\(plural(changes.count, "file")) changed** (+\(changes.totalAdditions) −\(changes.totalDeletions)): \(kindBreakdown(changes))")
        }
        if !flagged.isEmpty {
            let critical = flagged.filter { $0.change.maxSeverity == .critical }.count
            writer.line("- **\(flagged.count) need\(flagged.count == 1 ? "s" : "") attention**" + (critical > 0 ? " (\(critical) critical)" : ""))
        }
        if reviewed > 0 {
            let changedSince = files.filter { if case .changedSinceReview = $0.review { true } else { false } }.count
            writer.line("- **Reviewed \(reviewed) of \(files.count)**" + (changedSince > 0 ? "; \(changedSince) changed since your review" : ""))
        }
        if let agent, !agent.names.isEmpty {
            let counts = agentCounts
            var parts: [String] = []
            if counts.turns > 0 { parts.append(plural(counts.turns, "turn")) }
            if let noun = agent.toolCallNoun, counts.toolCalls > 0 { parts.append("\(counts.toolCalls) \(noun)") }
            if counts.permissionRequests > 0 { parts.append(plural(counts.permissionRequests, "permission request")) }
            if counts.questions > 0 { parts.append(plural(counts.questions, "question")) }
            var line = "- **Agent:** \(agent.names.joined(separator: ", "))"
            if !parts.isEmpty { line += " · " + parts.joined(separator: ", ") }
            if let state = agent.state { line += " · now \(state)" }
            writer.line(line)
        }
        if !commits.isEmpty {
            writer.line("- **\(plural(commits.count, "commit"))** \(baselineLabel.hasPrefix("since ") ? baselineLabel : "since \(baselineLabel)")")
        }
        if !excludedLargeFiles.isEmpty {
            writer.line("- \(plural(excludedLargeFiles.count, "large untracked file")) not diffed")
        }

        if options.attention, !flagged.isEmpty {
            writer.heading("Needs attention")
            for file in flagged {
                let messages = file.change.flags.filter { $0.severity >= .warning }.sorted { $0.severity > $1.severity }
                    .map { flag in flag.line.map { "\(flag.message) (line \($0))" } ?? flag.message }
                let severity = file.change.maxSeverity == .critical ? "**Critical**" : "**Warning**"
                writer.line("- \(severity) \(code(file.change.path)): \(messages.joined(separator: "; "))")
            }
        }

        if options.files, !files.isEmpty {
            writer.heading("Files")
            for file in files.sorted(by: { $0.change.path < $1.change.path }) {
                writer.line("- " + fileLine(file))
            }
        }

        if options.unreviewed, reviewed > 0, !unreviewed.isEmpty {
            writer.heading("Not yet reviewed")
            for file in unreviewed.sorted(by: { $0.change.path < $1.change.path }) {
                let note = if case .changedSinceReview = file.review { " (changed since your review)" } else { "" }
                writer.line("- \(code(file.change.path))\(note)")
            }
        }

        if options.commits, !commits.isEmpty {
            writer.heading("Commits")
            for commit in commits {
                writer.line("- \(code(String(commit.oid.prefix(7)))) \(commit.subject)")
            }
        }

        let notable = notableActivity
        if options.activity, !notable.isEmpty {
            writer.heading("Agent activity")
            if let activitySince {
                writer.line("_What Mimamori saw since \(writer.dateTime(activitySince)), while it was running._")
                writer.blank()
            }
            let shown = notable.suffix(options.maxActivityEntries)
            if shown.count < notable.count {
                writer.line("_\(plural(notable.count - shown.count, "earlier entry", "earlier entries")) not shown._")
                writer.blank()
            }
            for entry in shown {
                var line = "- \(writer.time(entry.date)) · \(entry.title)"
                if let detail = entry.detail, !detail.isEmpty { line += ": \(shortenedPaths(detail))" }
                writer.line(line)
            }
        }

        if options.diffs, !diffs.isEmpty {
            writer.heading("Diffs")
            var budget = options.maxDiffLines
            var omitted: [String] = []
            for file in files.sorted(by: { $0.change.path < $1.change.path }) {
                guard let patch = diffs[file.change.path] else { continue }
                let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
                guard lines.count <= budget else {
                    omitted.append(file.change.path)
                    continue
                }
                budget -= lines.count
                writer.line("### \(code(file.change.path))")
                writer.blank()
                writer.line(fence(for: patch) + "diff")
                writer.line(patch.hasSuffix("\n") ? String(patch.dropLast()) : patch)
                writer.line(fence(for: patch))
                writer.blank()
            }
            if !omitted.isEmpty {
                writer.line("_Diffs left out to keep this summary short: \(omitted.map(code).joined(separator: ", "))._")
            }
        }

        return writer.text
    }

    /// Baseline labels read either "since start at 9:00 AM" or "HEAD abc1234".
    private var baselinePhrase: String {
        baselineLabel.hasPrefix("since ") ? baselineLabel : "against \(baselineLabel)"
    }

    private func fileLine(_ file: File) -> String {
        let change = file.change
        var parts: [String] = []
        if let old = change.oldPath {
            parts.append("\(code(old)) → \(code(change.path))")
        } else {
            parts.append(code(change.path))
        }
        var facts = [change.kind == .renamed ? "renamed" : change.kind.title.lowercased()]
        if change.isBinary {
            facts.append("binary")
        } else if let additions = change.additions, let deletions = change.deletions {
            facts.append("+\(additions) −\(deletions)")
        }
        switch file.review {
        case .reviewed: facts.append("reviewed")
        case .changedSinceReview: facts.append("changed since your review")
        case .unreviewed: break
        }
        if let attribution = file.attribution { facts.append(attribution.label) }
        return parts[0] + ": " + facts.joined(separator: " · ")
    }

    private func kindBreakdown(_ changes: [FileChange]) -> String {
        let order: [(ChangeKind, String)] = [(.added, "added"), (.modified, "modified"), (.deleted, "deleted"),
                                             (.renamed, "renamed"), (.copied, "copied"), (.typeChanged, "type changed"),
                                             (.unmerged, "conflicted"), (.unknown, "other")]
        return order.compactMap { kind, word in
            let count = changes.filter { $0.kind == kind }.count
            return count > 0 ? "\(count) \(word)" : nil
        }.joined(separator: ", ")
    }

    /// Paths inside the worktree relative to it, others from ~.
    private func shortenedPaths(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return text.replacingOccurrences(of: worktreePath + "/", with: "")
            .replacingOccurrences(of: home + "/", with: "~/")
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: Helpers

/// Inline code that survives backticks in the text.
private func code(_ text: String) -> String {
    var ticks = "`"
    while text.contains(ticks) { ticks += "`" }
    let pad = text.hasPrefix("`") || text.hasSuffix("`") ? " " : ""
    return ticks + pad + text + pad + ticks
}

/// A code fence longer than any run of backticks inside the block.
private func fence(for text: String) -> String {
    var fence = "```"
    while text.contains(fence) { fence += "`" }
    return fence
}

private func plural(_ count: Int, _ singular: String, _ pluralForm: String? = nil) -> String {
    "\(count) \(count == 1 ? singular : (pluralForm ?? singular + "s"))"
}

private struct MarkdownWriter {
    private(set) var text = ""
    private let dateTimeFormatter: DateFormatter
    private let timeFormatter: DateFormatter

    init(timeZone: TimeZone, locale: Locale) {
        dateTimeFormatter = DateFormatter()
        dateTimeFormatter.dateStyle = .medium
        dateTimeFormatter.timeStyle = .short
        dateTimeFormatter.timeZone = timeZone
        dateTimeFormatter.locale = locale
        timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        timeFormatter.timeZone = timeZone
        timeFormatter.locale = locale
    }

    mutating func line(_ string: String) { text += string + "\n" }
    mutating func blank() { if !text.hasSuffix("\n\n") { text += "\n" } }
    mutating func heading(_ title: String) {
        blank()
        line("## \(title)")
        blank()
    }

    func dateTime(_ date: Date) -> String { dateTimeFormatter.string(from: date) }
    func time(_ date: Date) -> String { timeFormatter.string(from: date) }
}
