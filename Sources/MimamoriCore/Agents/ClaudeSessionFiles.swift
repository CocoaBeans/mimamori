import Foundation

/// What Claude Code records about one of its running sessions in `~/.claude/sessions/<pid>.json`.
public struct ClaudeSessionRecord: Sendable, Hashable {
    public var pid: Int32
    public var sessionID: String
    /// "busy", "idle" or "waiting"; nil from a Claude Code that does not record it.
    public var status: String?
    /// Why a waiting session waits: "permission prompt" or "input needed".
    public var waitingFor: String?
    public var statusUpdatedAt: Date?
    public var startedAt: Date?

    public init(pid: Int32, sessionID: String, status: String?, waitingFor: String? = nil, statusUpdatedAt: Date? = nil,
                startedAt: Date? = nil) {
        self.pid = pid
        self.sessionID = sessionID
        self.status = status
        self.waitingFor = waitingFor
        self.statusUpdatedAt = statusUpdatedAt
        self.startedAt = startedAt
    }

    /// The recorded status as an activity, or nil for one Mimamori does not know. It names no tool.
    public var activity: AgentActivity? {
        switch status {
        case "busy": .working(tool: nil, detail: nil)
        case "idle": .ready
        case "waiting": waitingFor == "permission prompt" ? .needsPermission(tool: "", detail: nil) : .askedQuestion(detail: nil)
        default: nil
        }
    }
}

/// Claude Code keeps a file for each running session, named after its process: the session's id
/// and whether it is busy, idle or waiting on you. That ties a process to the session its hooks
/// report, which can be working in another worktree than the folder the process started in. It
/// also gives a status before any hook arrives: once Mimamori starts, a session sitting idle sends
/// nothing until you next use it, and one started before the hooks were installed never does.
public enum ClaudeSessionFiles {
    /// Claude Code's own folder: `$CLAUDE_CONFIG_DIR`, or `~/.claude`.
    public static var configDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    public static var directory: URL { configDirectory.appendingPathComponent("sessions") }

    public static func parse(_ data: Data) -> ClaudeSessionRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value,
              let session = object["sessionId"] as? String, !session.isEmpty else { return nil }
        func date(_ key: String) -> Date? {
            (object[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        return ClaudeSessionRecord(pid: pid, sessionID: session, status: object["status"] as? String,
                                   waitingFor: object["waitingFor"] as? String,
                                   statusUpdatedAt: date("statusUpdatedAt") ?? date("updatedAt"), startedAt: date("startedAt"))
    }

    /// The record for the Claude Code process `pid`, unless the file is an earlier process's with the same pid.
    public static func record(for pid: Int32, startedAt: Date?, in directory: URL = directory) -> ClaudeSessionRecord? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(pid).json")),
              let record = parse(data), record.pid == pid else { return nil }
        if let startedAt, let recorded = record.startedAt, recorded < startedAt.addingTimeInterval(-60) { return nil }
        return record
    }
}
