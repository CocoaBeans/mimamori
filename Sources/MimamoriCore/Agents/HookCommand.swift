import Foundation

/// The shell command every Mimamori hook runs: curl, posting the event JSON on its standard input
/// to Mimamori's socket. Claude Code's hooks, the Hermes script and the setups for other agents
/// all build it here.
public enum HookCommand {
    /// Goes up whenever the command changes, so Mimamori can tell its older hooks apart and
    /// rewrite them. Commands from before the token was added (1.0 and 1.1) count as 1.
    public static let version = 2
    /// The header that carries `version`. The socket ignores it; it is there to be read back.
    static let versionHeader = "Mimamori-Hook"

    /// The real home folder, which a socket path inside is written as `$HOME`.
    public static var defaultHome: String { FileManager.default.homeDirectoryForCurrentUser.path }

    /// The bare curl call posting standard input to `address` on Mimamori's socket, giving up
    /// after `timeout` seconds. `address` is a path such as `/event` or `/event?agent=codex`.
    public static func curl(socketPath: String, address: String, timeout: Int, home: String = defaultHome) -> String {
        let url = AgentConfigLocations.shellQuoted("http://mimamori" + address)
        return "curl -s -m \(timeout) -H 'Expect:' -H 'Content-Type: application/json' -H '\(versionHeader): \(version)'"
            + " --unix-socket \(quotedSocket(socketPath, home: home)) --data-binary @- \(url)"
    }

    /// A hook that reports an event: output discarded, a one-second limit, and it always succeeds,
    /// so it can never hold up or block the agent.
    public static func event(socketPath: String, address: String = "/event", home: String = defaultHome) -> String {
        curl(socketPath: socketPath, address: address, timeout: 1, home: home) + " >/dev/null 2>&1 || true"
    }

    /// The PermissionRequest hook: it waits for Mimamori's answer and prints it, which Claude Code
    /// takes as the decision. With no answer, or no Mimamori, it prints nothing and still succeeds.
    public static func permission(socketPath: String, home: String = defaultHome) -> String {
        curl(socketPath: socketPath, address: "/permission", timeout: 595, home: home) + " 2>/dev/null || true"
    }

    /// The socket path in double quotes, as `$HOME/…` when it is inside `home`, so a settings file
    /// moves between machines and users.
    static func quotedSocket(_ socketPath: String, home: String) -> String {
        let escaped = { (text: Substring) -> String in
            var result = ""
            for character in text {
                if "\"\\$`".contains(character) { result.append("\\") }
                result.append(character)
            }
            return result
        }
        if !home.isEmpty, socketPath.hasPrefix(home + "/") {
            return "\"$HOME" + escaped(socketPath.dropFirst(home.count)) + "\""
        }
        return "\"" + escaped(Substring(socketPath)) + "\""
    }

    /// What a hook command Mimamori wrote says about itself.
    public struct Installed: Equatable, Sendable {
        /// The socket it posts to, with `$HOME` or `~` expanded.
        public var socketPath: String
        public var version: Int
    }

    /// Reads the socket path and version from a hook command, or nil when it posts to no socket.
    public static func parse(_ command: String, home: String = defaultHome) -> Installed? {
        guard let flag = command.range(of: "--unix-socket") else { return nil }
        guard var path = firstWord(command[flag.upperBound...]), !path.isEmpty else { return nil }
        for prefix in ["$HOME", "${HOME}", "~"] where path == prefix || path.hasPrefix(prefix + "/") {
            path = home + path.dropFirst(prefix.count)
            break
        }
        return Installed(socketPath: path, version: version(in: command))
    }

    /// The token's number, or 1 for a command from before there was one.
    static func version(in command: String) -> Int {
        guard let header = command.range(of: versionHeader + ":") else { return 1 }
        let digits = command[header.upperBound...].drop { $0 == " " }.prefix { $0.isASCII && $0.isNumber }
        return Int(digits) ?? 1
    }

    /// The first shell word in `text`, with its quotes and escapes removed.
    private static func firstWord(_ text: Substring) -> String? {
        var word = ""
        var quote: Character?
        var escaping = false
        var started = false
        for character in text {
            if escaping {
                word.append(character)
                escaping = false
            } else if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\" && open == "\"" {
                    escaping = true
                } else {
                    word.append(character)
                }
            } else if character == " " || character == "\t" {
                if started { return word }
            } else if character == "\"" || character == "'" {
                quote = character
                started = true
            } else if character == "\\" {
                escaping = true
                started = true
            } else {
                word.append(character)
                started = true
            }
        }
        return started && quote == nil ? word : nil
    }
}
