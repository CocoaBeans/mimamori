import Darwin
import Foundation

/// Thin wrappers over libproc for the user's own processes.
public enum ProcessInspector {
    public static func allPIDs() -> [Int32] {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<Int32>.size))
        }
        return Array(pids.prefix(Int(max(0, count)))).filter { $0 > 0 }
    }

    public static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func currentDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard result == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// The process that started this one.
    public static func parentPID(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }

    public static func startDate(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    /// Total CPU time consumed by the process, in seconds.
    public static func cpuTime(of pid: Int32) -> TimeInterval? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        let ticks = info.pti_total_user + info.pti_total_system
        return TimeInterval(ticks) * timebaseSeconds
    }

    private static let timebaseSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    /// The agent `pid` is, judged as the scanner judges it: by its executable and, for an
    /// interpreter, its arguments.
    public static func agentKind(of pid: Int32, classifier: AgentClassifier) -> AgentKind? {
        guard let executable = executablePath(of: pid) else { return nil }
        let arguments = AgentClassifier.isInterpreter((executable as NSString).lastPathComponent) ? arguments(of: pid) : []
        return classifier.classify(executable: executable, arguments: arguments)
    }

    /// The agent that started `pid`, or `pid` itself when it is one. A hook's command runs as a
    /// child of its agent, usually through a shell or two.
    public static func agentAncestor(of pid: Int32, classifier: AgentClassifier) -> (pid: Int32, kind: AgentKind)? {
        nearest(from: pid, parent: parentPID(of:)) { agentKind(of: $0, classifier: classifier) }
    }

    /// The first of `pid` and its ancestors, at most `limit` levels up, that `match` accepts.
    static func nearest<T>(from pid: Int32, limit: Int = 8, parent: (Int32) -> Int32?,
                           match: (Int32) -> T?) -> (pid: Int32, kind: T)? {
        var current = pid
        for _ in 0...limit {
            guard current > 1 else { return nil }
            if let found = match(current) { return (current, found) }
            guard let next = parent(current), next != current else { return nil }
            current = next
        }
        return nil
    }

    /// The process's argument vector, via KERN_PROCARGS2.
    public static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Executable path, then padding NULs, then argv.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        var start = index
        while index < size, arguments.count < Int(argc) {
            if buffer[index] == 0 {
                arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return arguments
    }
}

/// What one scan found.
public struct AgentScan: Sendable, Hashable {
    /// Agents grouped by the watched worktree their working directory falls in.
    public var byWorktree: [String: [AgentProcess]] = [:]
    /// Claude Code sessions whose process sits outside every watched worktree; their hooks may
    /// still report from one.
    public var elsewhere: [AgentProcess] = []

    public init(byWorktree: [String: [AgentProcess]] = [:], elsewhere: [AgentProcess] = []) {
        self.byWorktree = byWorktree
        self.elsewhere = elsewhere
    }

    /// Agents grouped by the worktree they work in. A Claude Code session counts where its status
    /// is, per `homes` (session id → worktree), which is not the folder its process started in
    /// once it moves to another worktree. A process outside every worktree counts only that way.
    public func attributed(homes: [String: String]) -> [String: [AgentProcess]] {
        var result: [String: [AgentProcess]] = [:]
        for (worktree, list) in byWorktree {
            for process in list {
                result[process.claudeSession.flatMap { homes[$0.sessionID] } ?? worktree, default: []].append(process)
            }
        }
        for process in elsewhere {
            if let home = process.claudeSession.flatMap({ homes[$0.sessionID] }) { result[home, default: []].append(process) }
        }
        return result
    }
}

/// Finds agent processes and matches them to worktrees.
public actor AgentScanner {
    public var classifier: AgentClassifier
    /// Where Claude Code records its sessions; nil to skip reading them.
    private let claudeSessions: URL?
    private var previousCPU: [Int32: (time: TimeInterval, at: Date)] = [:]
    /// What each process turned out to be, by pid and start time. A process keeps its executable,
    /// so a scan looks closely only at processes it has not seen: most of the Mac's are not agents.
    private var known: [Int32: (started: Date?, executable: String, kind: AgentKind?)] = [:]
    /// Younger processes are looked at again: a launcher script can still exec into an agent.
    static let settledAge: TimeInterval = 10

    public init(classifier: AgentClassifier = AgentClassifier(), claudeSessions: URL? = ClaudeSessionFiles.directory) {
        self.classifier = classifier
        self.claudeSessions = claudeSessions
    }

    public func setClassifier(_ classifier: AgentClassifier) {
        self.classifier = classifier
        known = [:]
    }

    /// Finds agents in `worktrees`, matched longest-prefix first so nested worktrees win over
    /// their parent, and Claude Code sessions running anywhere else.
    public func scan(worktrees: [String]) -> AgentScan {
        let roots = worktrees.sorted { $0.count > $1.count }
        let now = Date()
        var result = AgentScan()
        var seen = Set<Int32>()
        var alive = Set<Int32>()
        for pid in ProcessInspector.allPIDs() {
            alive.insert(pid)
            let started = ProcessInspector.startDate(of: pid)
            let executable: String
            let kind: AgentKind
            if let cached = known[pid], cached.started == started {
                guard let cachedKind = cached.kind else { continue }
                executable = cached.executable
                kind = cachedKind
            } else {
                guard let path = ProcessInspector.executablePath(of: pid) else { continue }
                let name = (path as NSString).lastPathComponent
                let arguments = AgentClassifier.isInterpreter(name) ? ProcessInspector.arguments(of: pid) : []
                let found = classifier.classify(executable: path, arguments: arguments)
                // Remember settled processes, and ones that keep their start time to themselves
                // (another user's): a pid reused by one of yours has a start time, so it is looked at.
                if started.map({ now.timeIntervalSince($0) > Self.settledAge }) ?? true {
                    known[pid] = (started, path, found)
                }
                guard let found else { continue }
                executable = path
                kind = found
            }
            guard let cwd = ProcessInspector.currentDirectory(of: pid) else { continue }
            let root = roots.first(where: { cwd == $0 || cwd.hasPrefix($0 + "/") })
            let session = kind == .claudeCode
                ? claudeSessions.flatMap { ClaudeSessionFiles.record(for: pid, startedAt: started, in: $0) } : nil
            guard root != nil || session != nil else { continue }

            seen.insert(pid)
            var load = 0.0
            if let cpu = ProcessInspector.cpuTime(of: pid) {
                if let previous = previousCPU[pid] {
                    let elapsed = now.timeIntervalSince(previous.at)
                    if elapsed > 0 { load = max(0, min(4, (cpu - previous.time) / elapsed)) }
                }
                previousCPU[pid] = (cpu, now)
            }
            let process = AgentProcess(
                pid: pid, kind: kind, executable: executable, workingDirectory: cwd,
                startedAt: started ?? now, cpuLoad: load, claudeSession: session)
            if let root {
                result.byWorktree[root, default: []].append(process)
            } else {
                result.elsewhere.append(process)
            }
        }
        previousCPU = previousCPU.filter { seen.contains($0.key) }
        known = known.filter { alive.contains($0.key) }
        return result
    }
}
