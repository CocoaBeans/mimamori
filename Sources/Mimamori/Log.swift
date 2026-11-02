import os

/// Mimamori's messages in the macOS log, by area. Read them in Console.app, or with
/// `log stream --predicate 'subsystem == "com.kevinross.Mimamori"' --level info`.
/// Names, events and errors are public; folders are left private, as the log keeps them.
enum Log {
    static let subsystem = "com.kevinross.Mimamori"
    /// The socket, hook requests and the hook installers.
    static let hooks = Logger(subsystem: subsystem, category: "hooks")
    /// Placing agents' events in worktrees.
    static let agents = Logger(subsystem: subsystem, category: "agents")
    /// Moving settings and hooks over from the app's former name.
    static let migration = Logger(subsystem: subsystem, category: "migration")
    static let widgets = Logger(subsystem: subsystem, category: "widgets")
    /// Saving and loading Mimamori's own state.
    static let state = Logger(subsystem: subsystem, category: "state")
}
