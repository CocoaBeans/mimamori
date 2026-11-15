import Foundation

/// A Mac that isn't there: sample agents for trying the iPhone companion without one, for App
/// Review, and for the App Store's screenshots. Two repositories and an agent in every group: two
/// waiting on you (a command to allow, a question to answer), one working, one ready, one ended.
/// Times count from `start`, so the cards look current. Answers move the agents on as real ones
/// move: the agent works for a few seconds, then finishes its turn.
public struct CompanionDemo: Sendable {
    /// Which sample Mac: the one Try the Demo shows, or the one the App Store's screenshots are
    /// taken from. That one tells another story on a Mac with an everyday name, so trying the demo
    /// doesn't replay the screenshots.
    public enum Sample: Sendable, Hashable {
        case tryIt, screenshots
    }

    /// How long an agent works after you answer it, before it finishes its turn.
    public static let workDuration: TimeInterval = 6
    public static let commandRequest = "demo-command"
    public static let questionRequest = "demo-question"

    /// What you answered, and when.
    struct Answer: Sendable, Hashable {
        var allow: Bool
        var at: Date
    }

    public let start: Date
    public let sample: Sample
    let script: Script
    private var answered: [String: Answer] = [:]

    public init(start: Date = Date(), sample: Sample = .tryIt) {
        self.start = start
        self.sample = sample
        script = sample == .tryIt ? .tryIt : .screenshots
    }

    public var macName: String { script.macName }

    /// The sample Mac's agents as they stand at `now`.
    public func snapshot(at now: Date = Date()) -> AgentWidgetSnapshot {
        AgentWidgetSnapshot(writtenAt: now, agents: [commandAgent(at: now), questionAgent(at: now), worker(), finished(), ended()])
    }

    /// The list of actions for the agent in `worktreePath`, as the Mac sends it: its turns newest
    /// first, each with its calls newest first.
    public func actions(for worktreePath: String, at now: Date = Date()) -> AgentActions? {
        guard let agent = snapshot(at: now).agents.first(where: { $0.worktreePath == worktreePath }) else { return nil }
        let (calls, starts) = history(for: worktreePath, at: now)
        return AgentActions(worktreePath: worktreePath, agent: agent.agent,
                            turns: AgentActions.turns(calls: calls, starts: starts),
                            waitingCallID: agent.card?.waitingCallID)
    }

    /// Answers a request as the Mac would take it. Nil once taken; otherwise why not.
    public mutating func answer(requestID: String, allow: Bool, at now: Date = Date()) -> String? {
        guard requestID == Self.commandRequest || requestID == Self.questionRequest else {
            return "\(macName) has no such request."
        }
        guard answered[requestID] == nil else { return "That request was already answered." }
        answered[requestID] = Answer(allow: allow, at: now)
        return nil
    }

    // MARK: Building the agents

    private func t(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func call(_ id: String, _ tool: String, _ summary: String, from: TimeInterval, to: TimeInterval?,
                      failed: Bool = false) -> AgentToolCall {
        AgentToolCall(id: id, toolName: tool, summary: summary, filePath: nil, startedAt: t(from),
                      finishedAt: to.map { t($0) }, failed: failed)
    }

    /// A script's calls as tool calls, with ids from `prefix`.
    private func calls(_ script: [Script.Call], _ prefix: String) -> [AgentToolCall] {
        script.enumerated().map { index, step in
            call("\(prefix)\(index)", step.tool, step.summary, from: step.from, to: step.to, failed: step.failed)
        }
    }

    /// The latest three calls, newest first, as the widgets' steps.
    private static func steps(_ calls: [AgentToolCall]) -> [AgentWidgetSnapshot.Step] {
        calls.suffix(3).reversed().map { .init(tool: $0.toolName, target: $0.summary, running: $0.finishedAt == nil) }
    }

    private func agent(_ role: Script.Agent, state: AgentWidgetSnapshot.State, status: String, since: Date,
                       calls: [AgentToolCall], underway: Bool) -> AgentWidgetSnapshot.Agent {
        let changes = AgentWidgetSnapshot.Card.Changes(
            files: role.files.count, toReview: role.toReview, flagged: role.files.filter(\.flagged).count,
            additions: role.files.compactMap(\.additions).reduce(0, +),
            deletions: role.files.compactMap(\.deletions).reduce(0, +))
        let card = AgentWidgetSnapshot.Card(
            reportsSteps: true, turnUnderway: underway, turnStartedAt: t(role.turnStart), calls: calls,
            callsThisTurn: calls.count, lastCall: underway ? nil : calls.last, files: role.files, changes: changes,
            subagents: [], commands: [])
        return AgentWidgetSnapshot.Agent(
            worktreePath: role.path, repository: role.repository, repositoryColor: role.color, worktree: role.worktree,
            agent: role.agent, symbol: role.symbol, state: state, status: status, since: since, task: role.task,
            steps: Self.steps(calls), card: card)
    }

    /// Where an answered request's agent stands: still waiting, working on it, or done.
    private enum Progress {
        case waiting
        case working(since: Date)
        case done(at: Date, allowed: Bool)
    }

    private func progress(of requestID: String, at now: Date) -> Progress {
        guard let answer = answered[requestID] else { return .waiting }
        guard answer.allow else { return .done(at: answer.at, allowed: false) }
        let done = answer.at.addingTimeInterval(Self.workDuration)
        return now < done ? .working(since: answer.at) : .done(at: done, allowed: true)
    }

    /// The agent waiting for you to allow a command; allowed, it runs it, then finishes its turn.
    private func commandCalls(at now: Date) -> [AgentToolCall] {
        let role = script.command
        var all = calls(role.calls, "c")
        let id = "c\(role.calls.count)"
        switch progress(of: Self.commandRequest, at: now) {
        case .waiting, .working:
            all.append(call(id, "Bash", script.commandLine, from: script.commandAt, to: nil))
        case .done(let at, let allowed):
            all.append(call(id, "Bash", script.commandLine, from: script.commandAt, to: at.timeIntervalSince(start), failed: !allowed))
        }
        return all
    }

    private func commandAgent(at now: Date) -> AgentWidgetSnapshot.Agent {
        let calls = commandCalls(at: now)
        var agent: AgentWidgetSnapshot.Agent
        switch progress(of: Self.commandRequest, at: now) {
        case .waiting:
            agent = self.agent(script.command, state: .needsYou, status: "needs permission · Bash \(script.commandLine)",
                               since: t(script.commandAt + 3), calls: calls, underway: true)
            agent.card?.waitingCallID = calls.last?.id
            agent.permissionRequest = .init(id: Self.commandRequest, tool: "Bash", detail: script.commandLine,
                                            since: t(script.commandAt + 3))
        case .working(let since):
            agent = self.agent(script.command, state: .working, status: "working · Bash \(script.commandLine)",
                               since: since, calls: calls, underway: true)
        case .done(let at, _):
            agent = self.agent(script.command, state: .ready, status: "ready for your next prompt",
                               since: at, calls: calls, underway: false)
        }
        agent.card?.subagents = [script.subagent.map { sub in
            AgentWidgetSnapshot.Card.Subagent(id: "sub", title: sub.title, description: sub.description, background: true,
                                              steps: sub.steps, startedAt: t(sub.from), finishedAt: t(sub.to), lastStep: sub.lastStep)
        }].compactMap { $0 }
        return agent
    }

    /// The agent asking you a question; answered, it edits a file, then finishes its turn.
    private func questionCalls(at now: Date) -> [AgentToolCall] {
        let role = script.asker
        var all = calls(role.calls, "q")
        let asked = "q\(role.calls.count)"
        let edit = "q\(role.calls.count + 1)"
        let question = script.question.question
        switch progress(of: Self.questionRequest, at: now) {
        case .waiting:
            all.append(call(asked, "AskUserQuestion", question, from: script.askedAt, to: nil))
        case .working(let since):
            let answered = since.timeIntervalSince(start)
            all.append(call(asked, "AskUserQuestion", question, from: script.askedAt, to: answered))
            all.append(call(edit, "Edit", script.followUp, from: answered, to: nil))
        case .done(let at, let allowed):
            let answered = self.answered[Self.questionRequest]?.at.timeIntervalSince(start) ?? at.timeIntervalSince(start)
            all.append(call(asked, "AskUserQuestion", question, from: script.askedAt, to: answered, failed: !allowed))
            if allowed { all.append(call(edit, "Edit", script.followUp, from: answered, to: at.timeIntervalSince(start))) }
        }
        return all
    }

    private func questionAgent(at now: Date) -> AgentWidgetSnapshot.Agent {
        let calls = questionCalls(at: now)
        switch progress(of: Self.questionRequest, at: now) {
        case .waiting:
            var agent = self.agent(script.asker, state: .needsYou, status: "asks: \(script.question.question)",
                                   since: t(script.askedAt), calls: calls, underway: true)
            agent.card?.waitingCallID = calls.last?.id
            agent.permissionRequest = .init(id: Self.questionRequest, tool: "AskUserQuestion", since: t(script.askedAt),
                                            questions: [script.question])
            return agent
        case .working(let since):
            return self.agent(script.asker, state: .working, status: "working · Edit \(script.followUp)",
                              since: since, calls: calls, underway: true)
        case .done(let at, _):
            return self.agent(script.asker, state: .ready, status: "ready for your next prompt",
                              since: at, calls: calls, underway: false)
        }
    }

    /// The agent at work, its last call still running.
    private var workerCalls: [AgentToolCall] {
        let role = script.worker
        let running = script.running
        return calls(role.calls, "w") + [call("w\(role.calls.count)", running.tool, running.summary, from: running.from, to: nil)]
    }

    private func worker() -> AgentWidgetSnapshot.Agent {
        let running = script.running
        return agent(script.worker, state: .working, status: "working · \(running.tool) \(running.summary)",
                     since: t(running.from), calls: workerCalls, underway: true)
    }

    private func finished() -> AgentWidgetSnapshot.Agent {
        agent(script.finished, state: .ready, status: "ready for your next prompt", since: t(script.readySince),
              calls: calls(script.finished.calls, "r"), underway: false)
    }

    private func ended() -> AgentWidgetSnapshot.Agent {
        agent(script.ended, state: .ended, status: "session ended", since: t(script.endedAt),
              calls: calls(script.ended.calls, "e"), underway: false)
    }

    /// Every call the agent in `worktreePath` made, with when its turns started, for its list of
    /// actions: the turn on the card, and the one before it if there was one.
    private func history(for worktreePath: String, at now: Date) -> ([AgentToolCall], [AgentActions.TurnStart]) {
        let roles: [(Script.Agent, [AgentToolCall])] = [
            (script.command, commandCalls(at: now)), (script.asker, questionCalls(at: now)),
            (script.worker, workerCalls), (script.finished, calls(script.finished.calls, "r")),
            (script.ended, calls(script.ended.calls, "e")),
        ]
        guard let match = roles.first(where: { $0.0.path == worktreePath }) else { return ([], []) }
        let (role, current) = match
        var all = current
        var starts = [AgentActions.TurnStart(at: t(role.turnStart), prompt: role.task)]
        if let earlier = role.earlier {
            all = calls(earlier.calls, "x") + all
            starts.insert(.init(at: t(earlier.start), prompt: earlier.prompt), at: 0)
        }
        return (all, starts)
    }
}

/// The story a sample Mac tells: who works where, on what, and what they ask you.
struct Script: Sendable {
    struct Call: Sendable {
        var tool: String
        var summary: String
        var from: TimeInterval
        var to: TimeInterval?
        var failed = false
    }

    struct Turn: Sendable {
        var prompt: String
        var start: TimeInterval
        var calls: [Call]
    }

    struct Agent: Sendable {
        var path: String
        var repository: String
        var color: RepositoryColor
        var worktree: String
        var agent: String
        var symbol: String
        var task: String
        var turnStart: TimeInterval
        /// The turn's calls so far, oldest first.
        var calls: [Call]
        var files: [AgentWidgetSnapshot.Card.File]
        var toReview: Int
        var earlier: Turn?
    }

    struct Subagent: Sendable {
        var title: String
        var description: String
        var lastStep: String
        var steps: Int
        var from: TimeInterval
        var to: TimeInterval
    }

    var macName: String
    /// Waits for you to allow `commandLine`, which it asked to run at `commandAt`.
    var command: Agent
    var commandLine: String
    var commandAt: TimeInterval
    var subagent: Subagent?
    /// Waits for your answer to `question`; answered, it edits `followUp`.
    var asker: Agent
    var question: AgentQuestion
    var askedAt: TimeInterval
    var followUp: String
    /// At work, `running` still running.
    var worker: Agent
    var running: Call
    var finished: Agent
    var readySince: TimeInterval
    var ended: Agent
    var endedAt: TimeInterval
}

private typealias File = AgentWidgetSnapshot.Card.File

extension Script {
    /// What Try the Demo shows: a web shop and its API.
    static let tryIt: Script = {
        let command = Agent(
            path: "/Users/you/Code/web-shop/.claude/worktrees/apple-pay", repository: "web-shop", color: .orange,
            worktree: "apple-pay", agent: "Claude Code", symbol: "sparkle",
            task: "Add Apple Pay to the checkout page, and make the checkout tests pass", turnStart: -270,
            calls: [
                Call(tool: "Read", summary: "src/checkout/CheckoutPage.tsx", from: -262, to: -260),
                Call(tool: "Grep", summary: "\"PaymentRequest\" src/", from: -255, to: -254),
                Call(tool: "Write", summary: "src/checkout/ApplePayButton.tsx", from: -238, to: -233),
                Call(tool: "Edit", summary: "src/checkout/CheckoutPage.tsx", from: -196, to: -193),
                Call(tool: "Edit", summary: "src/checkout/payments.ts", from: -150, to: -146),
                Call(tool: "Write", summary: "src/checkout/ApplePayButton.test.tsx", from: -92, to: -87),
            ],
            files: [
                File(path: "src/checkout/ApplePayButton.test.tsx", additions: 58, deletions: 0),
                File(path: "src/checkout/payments.ts", additions: 41, deletions: 3, flagged: true),
                File(path: "src/checkout/CheckoutPage.tsx", additions: 24, deletions: 6),
                File(path: "src/checkout/ApplePayButton.tsx", additions: 86, deletions: 0),
            ],
            toReview: 4,
            earlier: Turn(prompt: "Split the checkout page's payment step into its own component", start: -1840, calls: [
                Call(tool: "Read", summary: "src/checkout/CheckoutPage.tsx", from: -1830, to: -1828),
                Call(tool: "Edit", summary: "src/checkout/CheckoutPage.tsx", from: -1790, to: -1785),
            ]))
        let asker = Agent(
            path: "/Users/you/Code/api/.claude/worktrees/rate-limits", repository: "api", color: .indigo,
            worktree: "rate-limits", agent: "Claude Code", symbol: "sparkle",
            task: "Rate-limit the public API, with a gentler limit for signed-in users", turnStart: -135,
            calls: [
                Call(tool: "Read", summary: "src/server.ts", from: -128, to: -127),
                Call(tool: "Grep", summary: "\"rateLimit\" src/", from: -121, to: -120),
                Call(tool: "Read", summary: "src/middleware/auth.ts", from: -110, to: -108),
                Call(tool: "Write", summary: "src/middleware/rateLimit.ts", from: -84, to: -79),
            ],
            files: [File(path: "src/middleware/rateLimit.ts", additions: 63, deletions: 0)], toReview: 1)
        let question = AgentQuestion(
            question: "Which limit should signed-out visitors get?", header: "Rate limit",
            options: [
                .init(label: "60 a minute", description: "The same as the public API has today"),
                .init(label: "30 a minute", description: "Stricter, for the busiest endpoints"),
                .init(label: "No limit", description: "Leave signed-out traffic as it is"),
            ])
        let worker = Agent(
            path: "/Users/you/Code/web-shop/.codex/worktrees/infinite-scroll", repository: "web-shop", color: .orange,
            worktree: "infinite-scroll", agent: "Codex", symbol: "curlybraces",
            task: "Load more search results as you scroll, instead of the Next button", turnStart: -512,
            calls: [
                Call(tool: "Read", summary: "src/search/SearchResults.tsx", from: -505, to: -503),
                Call(tool: "Grep", summary: "\"useSearchQuery\" src/", from: -497, to: -496),
                Call(tool: "Read", summary: "src/search/useSearchQuery.ts", from: -490, to: -488),
                Call(tool: "Edit", summary: "src/search/useSearchQuery.ts", from: -402, to: -396),
                Call(tool: "Write", summary: "src/search/useInfiniteScroll.ts", from: -310, to: -303),
                Call(tool: "Bash", summary: "npm run lint -- src/search", from: -220, to: -205),
            ],
            files: [
                File(path: "src/search/useInfiniteScroll.ts", additions: 47, deletions: 0),
                File(path: "src/search/useSearchQuery.ts", additions: 19, deletions: 12),
            ],
            toReview: 2,
            earlier: Turn(prompt: "Why do the search tests fail on main?", start: -2210, calls: [
                Call(tool: "Bash", summary: "npm run test -- search", from: -2200, to: -2170, failed: true),
            ]))
        let finished = Agent(
            path: "/Users/you/Code/api/.worktrees/orders-docs", repository: "api", color: .indigo,
            worktree: "orders-docs", agent: "Gemini CLI", symbol: "diamond",
            task: "Document the orders endpoints in docs/api", turnStart: -1250,
            calls: [
                Call(tool: "read_file", summary: "src/routes/orders.ts", from: -1240, to: -1238),
                Call(tool: "search_file_content", summary: "\"router.get\" src/routes", from: -1230, to: -1229),
                Call(tool: "write_file", summary: "docs/api/orders.md", from: -1100, to: -1091),
                Call(tool: "replace", summary: "docs/api/README.md", from: -1070, to: -1068),
            ],
            files: [
                File(path: "docs/api/README.md", additions: 3, deletions: 1),
                File(path: "docs/api/orders.md", additions: 142, deletions: 0),
            ],
            toReview: 1)
        let ended = Agent(
            path: "/Users/you/Code/web-shop/.worktrees/footer-links", repository: "web-shop", color: .orange,
            worktree: "footer-links", agent: "Cursor", symbol: "cursorarrow.rays",
            task: "Fix the footer links on small screens", turnStart: -2660,
            calls: [
                Call(tool: "Read", summary: "src/components/Footer.tsx", from: -2650, to: -2648),
                Call(tool: "Edit", summary: "src/components/Footer.css", from: -2600, to: -2596),
            ],
            files: [File(path: "src/components/Footer.css", additions: 12, deletions: 4)], toReview: 0)
        return Script(
            macName: "Demo Mac",
            command: command, commandLine: "npm test -- checkout", commandAt: -41,
            subagent: Subagent(title: "general-purpose", description: "Check the other payment buttons still render",
                               lastStep: "Read src/checkout/PayPalButton.tsx", steps: 5, from: -64, to: -20),
            asker: asker, question: question, askedAt: -24, followUp: "src/middleware/rateLimit.ts",
            worker: worker, running: Call(tool: "Edit", summary: "src/search/SearchResults.tsx", from: -14, to: nil),
            finished: finished, readySince: -1060,
            ended: ended, endedAt: -2400)
    }()

    /// What the App Store's screenshots show: a notes app and its sync server, on an everyday Mac.
    static let screenshots: Script = {
        let command = Agent(
            path: "/Users/you/Code/notes-app/.claude/worktrees/offline-mode", repository: "notes-app", color: .teal,
            worktree: "offline-mode", agent: "Claude Code", symbol: "sparkle",
            task: "Keep notes editable offline, and sync them when the connection comes back", turnStart: -300,
            calls: [
                Call(tool: "Read", summary: "Sources/Notes/NoteStore.swift", from: -292, to: -290),
                Call(tool: "Grep", summary: "\"func save(\" Sources/", from: -284, to: -283),
                Call(tool: "Write", summary: "Sources/Notes/OfflineQueue.swift", from: -251, to: -245),
                Call(tool: "Edit", summary: "Sources/Notes/SyncEngine.swift", from: -203, to: -198),
                Call(tool: "Edit", summary: "Sources/Notes/NoteStore.swift", from: -160, to: -156),
                Call(tool: "Write", summary: "Tests/NotesTests/OfflineQueueTests.swift", from: -101, to: -95),
            ],
            files: [
                File(path: "Tests/NotesTests/OfflineQueueTests.swift", additions: 74, deletions: 0),
                File(path: "Sources/Notes/NoteStore.swift", additions: 18, deletions: 5),
                File(path: "Sources/Notes/SyncEngine.swift", additions: 38, deletions: 9, flagged: true),
                File(path: "Sources/Notes/OfflineQueue.swift", additions: 112, deletions: 0),
            ],
            toReview: 4,
            earlier: Turn(prompt: "Show when a note last synced, under its title", start: -1500, calls: [
                Call(tool: "Read", summary: "Sources/Notes/NoteRow.swift", from: -1490, to: -1488),
                Call(tool: "Edit", summary: "Sources/Notes/NoteRow.swift", from: -1460, to: -1455),
            ]))
        let asker = Agent(
            path: "/Users/you/Code/sync-server/.claude/worktrees/conflicts", repository: "sync-server", color: .purple,
            worktree: "conflicts", agent: "Claude Code", symbol: "sparkle",
            task: "Settle sync conflicts when two devices change the same note", turnStart: -150,
            calls: [
                Call(tool: "Read", summary: "src/sync/merge.ts", from: -143, to: -142),
                Call(tool: "Grep", summary: "\"updatedAt\" src/", from: -137, to: -136),
                Call(tool: "Read", summary: "src/db/notes.ts", from: -129, to: -127),
                Call(tool: "Write", summary: "src/sync/conflicts.ts", from: -96, to: -90),
            ],
            files: [File(path: "src/sync/conflicts.ts", additions: 57, deletions: 0)], toReview: 1)
        let question = AgentQuestion(
            question: "Two devices changed the same note. Which change should win?", header: "Conflicts",
            options: [
                .init(label: "Keep both", description: "Save the other change as a copy of the note"),
                .init(label: "Newest wins", description: "The later change replaces the earlier one"),
                .init(label: "Merge them", description: "Combine both changes, line by line"),
            ])
        let worker = Agent(
            path: "/Users/you/Code/notes-app/.codex/worktrees/pinned-widget", repository: "notes-app", color: .teal,
            worktree: "pinned-widget", agent: "Codex", symbol: "curlybraces",
            task: "Add a Home Screen widget with your pinned notes", turnStart: -430,
            calls: [
                Call(tool: "Read", summary: "Sources/Notes/Note.swift", from: -424, to: -423),
                Call(tool: "Grep", summary: "\"isPinned\" Sources/", from: -418, to: -417),
                Call(tool: "Write", summary: "Widgets/PinnedNotesWidget.swift", from: -350, to: -341),
                Call(tool: "Edit", summary: "Widgets/WidgetBundle.swift", from: -300, to: -298),
                Call(tool: "Bash", summary: "xcodebuild -scheme NotesWidgets build", from: -190, to: -142),
            ],
            files: [
                File(path: "Widgets/PinnedNotesWidget.swift", additions: 88, deletions: 0),
                File(path: "Widgets/WidgetBundle.swift", additions: 3, deletions: 1),
            ],
            toReview: 2)
        let finished = Agent(
            path: "/Users/you/Code/sync-server/.worktrees/metrics", repository: "sync-server", color: .purple,
            worktree: "metrics", agent: "Gemini CLI", symbol: "diamond",
            task: "Time every endpoint, and export the timings for the dashboard", turnStart: -980,
            calls: [
                Call(tool: "read_file", summary: "src/server.ts", from: -972, to: -971),
                Call(tool: "write_file", summary: "src/metrics/timing.ts", from: -900, to: -893),
                Call(tool: "replace", summary: "src/server.ts", from: -861, to: -859),
                Call(tool: "run_shell_command", summary: "npm test", from: -820, to: -790),
            ],
            files: [
                File(path: "src/metrics/timing.ts", additions: 46, deletions: 0),
                File(path: "src/server.ts", additions: 7, deletions: 2),
            ],
            toReview: 2)
        let ended = Agent(
            path: "/Users/you/Code/notes-app/.worktrees/onboarding", repository: "notes-app", color: .teal,
            worktree: "onboarding", agent: "Aider", symbol: "wrench.adjustable",
            task: "Tighten the wording on the welcome screens", turnStart: -2400,
            calls: [
                Call(tool: "Read", summary: "Sources/Onboarding/WelcomeView.swift", from: -2390, to: -2388),
                Call(tool: "Edit", summary: "Sources/Onboarding/WelcomeView.swift", from: -2330, to: -2324),
            ],
            files: [File(path: "Sources/Onboarding/WelcomeView.swift", additions: 9, deletions: 14)], toReview: 0)
        return Script(
            macName: "MacBook Pro",
            command: command, commandLine: "swift test --filter OfflineQueueTests", commandAt: -46,
            subagent: Subagent(title: "Explore", description: "Find every place that saves a note",
                               lastStep: "Grep \"context.save()\"", steps: 6, from: -280, to: -262),
            asker: asker, question: question, askedAt: -31, followUp: "src/sync/conflicts.ts",
            worker: worker, running: Call(tool: "Edit", summary: "Widgets/PinnedNotesWidget.swift", from: -9, to: nil),
            finished: finished, readySince: -780,
            ended: ended, endedAt: -2100)
    }()
}
