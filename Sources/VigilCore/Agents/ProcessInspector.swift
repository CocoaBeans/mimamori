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

/// Finds agent processes and matches them to worktrees.
public actor AgentScanner {
    public var classifier: AgentClassifier
    private var previousCPU: [Int32: (time: TimeInterval, at: Date)] = [:]

    public init(classifier: AgentClassifier = AgentClassifier()) {
        self.classifier = classifier
    }

    public func setClassifier(_ classifier: AgentClassifier) {
        self.classifier = classifier
    }

    /// Returns agents grouped by the watched worktree their working directory falls in.
    /// Worktrees are matched longest-prefix first so nested worktrees win over their parent.
    public func scan(worktrees: [String]) -> [String: [AgentProcess]] {
        let roots = worktrees.sorted { $0.count > $1.count }
        let now = Date()
        var result: [String: [AgentProcess]] = [:]
        var seen = Set<Int32>()

        for pid in ProcessInspector.allPIDs() {
            guard let executable = ProcessInspector.executablePath(of: pid) else { continue }
            let name = (executable as NSString).lastPathComponent
            let needsArguments = AgentClassifier.isInterpreter(name)
            let arguments = needsArguments ? ProcessInspector.arguments(of: pid) : []
            guard let kind = classifier.classify(executable: executable, arguments: arguments) else { continue }
            guard let cwd = ProcessInspector.currentDirectory(of: pid) else { continue }
            guard let root = roots.first(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }) else { continue }

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
                startedAt: ProcessInspector.startDate(of: pid) ?? now, cpuLoad: load)
            result[root, default: []].append(process)
        }
        previousCPU = previousCPU.filter { seen.contains($0.key) }
        return result
    }
}
