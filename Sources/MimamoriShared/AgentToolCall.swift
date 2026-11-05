import Foundation

/// One tool invocation seen through PreToolUse/PostToolUse.
public struct AgentToolCall: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var toolName: String
    public var summary: String?
    public var filePath: String?
    public var startedAt: Date
    public var finishedAt: Date?
    /// The call failed (a command exiting non-zero) or was interrupted.
    public var failed: Bool

    public init(id: String, toolName: String, summary: String?, filePath: String?, startedAt: Date, finishedAt: Date? = nil,
                failed: Bool = false) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.filePath = filePath
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.failed = failed
    }

    public var category: AgentToolCategory { AgentToolCategory(toolName: toolName) }
}

/// What kind of step a tool call is, across agents' differing tool names.
public enum AgentToolCategory: String, Sendable, Hashable, CaseIterable {
    case edit, command, read, search, web, subagent, question, other

    public init(toolName: String) {
        switch toolName {
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "Delete",
             "write_file", "patch", "apply_patch", "edit_file", "delete_file", "replace":
            self = .edit
        case "Bash", "BashOutput", "KillShell", "Shell", "terminal", "execute_code", "process", "run_shell_command":
            self = .command
        case "Read", "NotebookRead", "read_file", "view_file", "read_many_files":
            self = .read
        case "Grep", "Glob", "LS", "search_files", "list_files", "find_files", "glob", "search_file_content", "list_directory":
            self = .search
        case "WebFetch", "WebSearch", "web_search", "web_extract", "web_fetch", "google_web_search":
            self = .web
        case "Task", "Agent", "delegate_task":
            self = .subagent
        case "AskUserQuestion", "clarify":
            self = .question
        default:
            self = toolName.hasPrefix("browser") ? .web : .other
        }
    }
}
