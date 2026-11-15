import Foundation

/// A Mac that isn't there: sample agents for trying the iPhone companion without one, for App
/// Review and the App Store's screenshots. Two repositories and an agent in every group: two
/// waiting on you (a command to allow, a question to answer), one working, one ready, one ended.
/// Times count from `start`, so the cards look current. Answers move the agents on as real ones
/// move: the agent works for a few seconds, then finishes its turn.
public struct CompanionDemo: Sendable {
    public static let macName = "Demo Mac"
    /// How long an agent works after you answer it, before it finishes its turn.
    public static let workDuration: TimeInterval = 6

    public static let applePayRequest = "demo-apple-pay"
    public static let rateLimitRequest = "demo-rate-limit"
    static let applePayPath = "/Users/you/Code/web-shop/.claude/worktrees/apple-pay"
    static let rateLimitPath = "/Users/you/Code/api/.claude/worktrees/rate-limits"
    static let searchPath = "/Users/you/Code/web-shop/.codex/worktrees/infinite-scroll"
    static let docsPath = "/Users/you/Code/api/.worktrees/orders-docs"
    static let footerPath = "/Users/you/Code/web-shop/.worktrees/footer-links"

    /// What you answered, and when.
    struct Answer: Sendable, Hashable {
        var allow: Bool
        var at: Date
    }

    public let start: Date
    private var answered: [String: Answer] = [:]

    public init(start: Date = Date()) {
        self.start = start
    }

    /// The sample Mac's agents as they stand at `now`.
    public func snapshot(at now: Date = Date()) -> AgentWidgetSnapshot {
        AgentWidgetSnapshot(writtenAt: now, agents: [applePay(at: now), rateLimits(at: now), search(), docs(), footer()])
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
        guard requestID == Self.applePayRequest || requestID == Self.rateLimitRequest else {
            return "\(Self.macName) has no such request."
        }
        guard answered[requestID] == nil else { return "That request was already answered." }
        answered[requestID] = Answer(allow: allow, at: now)
        return nil
    }

    // MARK: The agents

    private func t(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func call(_ id: String, _ tool: String, _ summary: String, from: TimeInterval, to: TimeInterval?,
                      failed: Bool = false) -> AgentToolCall {
        AgentToolCall(id: id, toolName: tool, summary: summary, filePath: nil, startedAt: t(from),
                      finishedAt: to.map { t($0) }, failed: failed)
    }

    /// The latest three calls, newest first, as the widgets' steps.
    private static func steps(_ calls: [AgentToolCall]) -> [AgentWidgetSnapshot.Step] {
        calls.suffix(3).reversed().map { .init(tool: $0.toolName, target: $0.summary, running: $0.finishedAt == nil) }
    }

    /// Where an answered request's agent stands: still working on it, or done.
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

    /// Claude Code adding Apple Pay, waiting for you to allow its test run.
    private func applePayCalls(at now: Date) -> [AgentToolCall] {
        var calls = [
            call("ap1", "Read", "src/checkout/CheckoutPage.tsx", from: -262, to: -260),
            call("ap2", "Grep", "\"PaymentRequest\" src/", from: -255, to: -254),
            call("ap3", "Write", "src/checkout/ApplePayButton.tsx", from: -238, to: -233),
            call("ap4", "Edit", "src/checkout/CheckoutPage.tsx", from: -196, to: -193),
            call("ap5", "Edit", "src/checkout/payments.ts", from: -150, to: -146),
            call("ap6", "Write", "src/checkout/ApplePayButton.test.tsx", from: -92, to: -87),
        ]
        let test = "npm test -- checkout"
        switch progress(of: Self.applePayRequest, at: now) {
        case .waiting, .working: calls.append(call("ap7", "Bash", test, from: -41, to: nil))
        case .done(let at, let allowed):
            calls.append(call("ap7", "Bash", test, from: -41, to: at.timeIntervalSince(start), failed: !allowed))
        }
        return calls
    }

    private func applePay(at now: Date) -> AgentWidgetSnapshot.Agent {
        let calls = applePayCalls(at: now)
        let files: [AgentWidgetSnapshot.Card.File] = [
            .init(path: "src/checkout/ApplePayButton.test.tsx", additions: 58, deletions: 0),
            .init(path: "src/checkout/payments.ts", additions: 41, deletions: 3, flagged: true),
            .init(path: "src/checkout/CheckoutPage.tsx", additions: 24, deletions: 6),
            .init(path: "src/checkout/ApplePayButton.tsx", additions: 86, deletions: 0),
        ]
        let changes = AgentWidgetSnapshot.Card.Changes(files: 4, toReview: 4, flagged: 1, additions: 209, deletions: 9)
        let subagent = AgentWidgetSnapshot.Card.Subagent(
            id: "ap-sub", title: "general-purpose", description: "Check the other payment buttons still render",
            background: true, steps: 5, startedAt: t(-64), finishedAt: t(-20), lastStep: "Read src/checkout/PayPalButton.tsx")
        var agent = AgentWidgetSnapshot.Agent(
            worktreePath: Self.applePayPath, repository: "web-shop", repositoryColor: .orange, worktree: "apple-pay",
            agent: "Claude Code", symbol: "sparkle", state: .needsYou, status: "needs permission · Bash npm test -- checkout",
            since: t(-38), task: "Add Apple Pay to the checkout page, and make the checkout tests pass",
            steps: Self.steps(calls))
        var card = AgentWidgetSnapshot.Card(
            reportsSteps: true, turnUnderway: true, turnStartedAt: t(-270), calls: calls, callsThisTurn: calls.count,
            files: files, changes: changes, subagents: [subagent], commands: [])
        switch progress(of: Self.applePayRequest, at: now) {
        case .waiting:
            card.waitingCallID = "ap7"
            agent.permissionRequest = .init(id: Self.applePayRequest, tool: "Bash", detail: "npm test -- checkout", since: t(-38))
        case .working(let since):
            agent.state = .working
            agent.status = "working · Bash npm test -- checkout"
            agent.since = since
        case .done(let at, _):
            agent.state = .ready
            agent.status = "ready for your next prompt"
            agent.since = at
            card.turnUnderway = false
            card.lastCall = calls.last
        }
        agent.card = card
        return agent
    }

    /// Claude Code rate-limiting the API, asking you which limit to use.
    static let rateLimitQuestion = AgentQuestion(
        question: "Which limit should signed-out visitors get?", header: "Rate limit",
        options: [
            .init(label: "60 a minute", description: "The same as the public API has today"),
            .init(label: "30 a minute", description: "Stricter, for the busiest endpoints"),
            .init(label: "No limit", description: "Leave signed-out traffic as it is"),
        ])

    private func rateLimitCalls(at now: Date) -> [AgentToolCall] {
        var calls = [
            call("rl1", "Read", "src/server.ts", from: -128, to: -127),
            call("rl2", "Grep", "\"rateLimit\" src/", from: -121, to: -120),
            call("rl3", "Read", "src/middleware/auth.ts", from: -110, to: -108),
            call("rl4", "Write", "src/middleware/rateLimit.ts", from: -84, to: -79),
        ]
        let question = Self.rateLimitQuestion.question
        switch progress(of: Self.rateLimitRequest, at: now) {
        case .waiting:
            calls.append(call("rl5", "AskUserQuestion", question, from: -24, to: nil))
        case .working(let since):
            calls.append(call("rl5", "AskUserQuestion", question, from: -24, to: since.timeIntervalSince(start)))
            calls.append(call("rl6", "Edit", "src/middleware/rateLimit.ts", from: since.timeIntervalSince(start), to: nil))
        case .done(let at, let allowed):
            let answered = answered[Self.rateLimitRequest]?.at.timeIntervalSince(start) ?? at.timeIntervalSince(start)
            calls.append(call("rl5", "AskUserQuestion", question, from: -24, to: answered, failed: !allowed))
            if allowed { calls.append(call("rl6", "Edit", "src/middleware/rateLimit.ts", from: answered, to: at.timeIntervalSince(start))) }
        }
        return calls
    }

    private func rateLimits(at now: Date) -> AgentWidgetSnapshot.Agent {
        let calls = rateLimitCalls(at: now)
        let files: [AgentWidgetSnapshot.Card.File] = [
            .init(path: "src/middleware/rateLimit.ts", additions: 63, deletions: 0),
        ]
        var agent = AgentWidgetSnapshot.Agent(
            worktreePath: Self.rateLimitPath, repository: "api", repositoryColor: .indigo, worktree: "rate-limits",
            agent: "Claude Code", symbol: "sparkle", state: .needsYou, status: "asks: \(Self.rateLimitQuestion.question)",
            since: t(-24), task: "Rate-limit the public API, with a gentler limit for signed-in users",
            steps: Self.steps(calls))
        var card = AgentWidgetSnapshot.Card(
            reportsSteps: true, turnUnderway: true, turnStartedAt: t(-135), calls: calls, callsThisTurn: calls.count,
            files: files, changes: .init(files: 1, toReview: 1, additions: 63), subagents: [], commands: [])
        switch progress(of: Self.rateLimitRequest, at: now) {
        case .waiting:
            card.waitingCallID = "rl5"
            agent.permissionRequest = .init(id: Self.rateLimitRequest, tool: "AskUserQuestion", since: t(-24),
                                            questions: [Self.rateLimitQuestion])
        case .working(let since):
            agent.state = .working
            agent.status = "working · Edit src/middleware/rateLimit.ts"
            agent.since = since
        case .done(let at, _):
            agent.state = .ready
            agent.status = "ready for your next prompt"
            agent.since = at
            card.turnUnderway = false
            card.lastCall = calls.last
        }
        agent.card = card
        return agent
    }

    /// Codex turning paged search results into an endless list, at work.
    private var searchCalls: [AgentToolCall] {
        [
            call("se1", "Read", "src/search/SearchResults.tsx", from: -505, to: -503),
            call("se2", "Grep", "\"useSearchQuery\" src/", from: -497, to: -496),
            call("se3", "Read", "src/search/useSearchQuery.ts", from: -490, to: -488),
            call("se4", "Edit", "src/search/useSearchQuery.ts", from: -402, to: -396),
            call("se5", "Write", "src/search/useInfiniteScroll.ts", from: -310, to: -303),
            call("se6", "Bash", "npm run lint -- src/search", from: -220, to: -205),
            call("se7", "Edit", "src/search/SearchResults.tsx", from: -14, to: nil),
        ]
    }

    private func search() -> AgentWidgetSnapshot.Agent {
        let calls = searchCalls
        let files: [AgentWidgetSnapshot.Card.File] = [
            .init(path: "src/search/useInfiniteScroll.ts", additions: 47, deletions: 0),
            .init(path: "src/search/useSearchQuery.ts", additions: 19, deletions: 12),
        ]
        return AgentWidgetSnapshot.Agent(
            worktreePath: Self.searchPath, repository: "web-shop", repositoryColor: .orange, worktree: "infinite-scroll",
            agent: "Codex", symbol: "curlybraces", state: .working, status: "working · Edit src/search/SearchResults.tsx",
            since: t(-14), task: "Load more search results as you scroll, instead of the Next button",
            steps: Self.steps(calls),
            card: .init(reportsSteps: true, turnUnderway: true, turnStartedAt: t(-512), calls: calls,
                        callsThisTurn: calls.count, files: files,
                        changes: .init(files: 2, toReview: 2, additions: 66, deletions: 12), subagents: [], commands: []))
    }

    /// Gemini CLI, done documenting the orders endpoints.
    private var docsCalls: [AgentToolCall] {
        [
            call("do1", "read_file", "src/routes/orders.ts", from: -1240, to: -1238),
            call("do2", "search_file_content", "\"router.get\" src/routes", from: -1230, to: -1229),
            call("do3", "write_file", "docs/api/orders.md", from: -1100, to: -1091),
            call("do4", "replace", "docs/api/README.md", from: -1070, to: -1068),
        ]
    }

    private func docs() -> AgentWidgetSnapshot.Agent {
        let calls = docsCalls
        let files: [AgentWidgetSnapshot.Card.File] = [
            .init(path: "docs/api/README.md", additions: 3, deletions: 1),
            .init(path: "docs/api/orders.md", additions: 142, deletions: 0),
        ]
        return AgentWidgetSnapshot.Agent(
            worktreePath: Self.docsPath, repository: "api", repositoryColor: .indigo, worktree: "orders-docs",
            agent: "Gemini CLI", symbol: "diamond", state: .ready, status: "ready for your next prompt",
            since: t(-1060), task: "Document the orders endpoints in docs/api", steps: Self.steps(calls),
            card: .init(reportsSteps: true, turnUnderway: false, turnStartedAt: t(-1250), calls: calls,
                        callsThisTurn: calls.count, lastCall: calls.last, files: files,
                        changes: .init(files: 2, toReview: 1, additions: 145, deletions: 1), subagents: [], commands: []))
    }

    /// Cursor's session, over.
    private var footerCalls: [AgentToolCall] {
        [
            call("fo1", "Read", "src/components/Footer.tsx", from: -2650, to: -2648),
            call("fo2", "Edit", "src/components/Footer.css", from: -2600, to: -2596),
        ]
    }

    private func footer() -> AgentWidgetSnapshot.Agent {
        let calls = footerCalls
        return AgentWidgetSnapshot.Agent(
            worktreePath: Self.footerPath, repository: "web-shop", repositoryColor: .orange, worktree: "footer-links",
            agent: "Cursor", symbol: "cursorarrow.rays", state: .ended, status: "session ended",
            since: t(-2400), task: "Fix the footer links on small screens", steps: Self.steps(calls),
            card: .init(reportsSteps: true, turnUnderway: false, turnStartedAt: t(-2660), calls: calls,
                        callsThisTurn: calls.count, lastCall: calls.last,
                        files: [.init(path: "src/components/Footer.css", additions: 12, deletions: 4)],
                        changes: .init(files: 1, additions: 12, deletions: 4), subagents: [], commands: []))
    }

    /// Every call the agent in `worktreePath` made, with when its turns started, for its list of
    /// actions: the turn on the card, and the one before it.
    private func history(for worktreePath: String, at now: Date) -> ([AgentToolCall], [AgentActions.TurnStart]) {
        switch worktreePath {
        case Self.applePayPath:
            let before = [
                call("ap0a", "Read", "src/checkout/CheckoutPage.tsx", from: -1830, to: -1828),
                call("ap0b", "Edit", "src/checkout/CheckoutPage.tsx", from: -1790, to: -1785),
            ]
            return (before + applePayCalls(at: now), [
                .init(at: t(-1840), prompt: "Split the checkout page's payment step into its own component"),
                .init(at: t(-270), prompt: "Add Apple Pay to the checkout page, and make the checkout tests pass"),
            ])
        case Self.rateLimitPath:
            return (rateLimitCalls(at: now), [.init(at: t(-135), prompt: "Rate-limit the public API, with a gentler limit for signed-in users")])
        case Self.searchPath:
            let before = [call("se0", "Bash", "npm run test -- search", from: -2200, to: -2170, failed: true)]
            return (before + searchCalls, [
                .init(at: t(-2210), prompt: "Why do the search tests fail on main?"),
                .init(at: t(-512), prompt: "Load more search results as you scroll, instead of the Next button"),
            ])
        case Self.docsPath:
            return (docsCalls, [.init(at: t(-1250), prompt: "Document the orders endpoints in docs/api")])
        case Self.footerPath:
            return (footerCalls, [.init(at: t(-2660), prompt: "Fix the footer links on small screens")])
        default:
            return ([], [])
        }
    }
}
