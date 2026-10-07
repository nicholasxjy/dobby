import Darwin

/// Raw per-process counters captured at one point in time.
public struct ProcessSnapshot: Equatable, Sendable, Codable {
    public let pid: pid_t
    public let name: String
    public let path: String?
    /// Owning user; `uid_t.max` when it couldn't be read.
    public let uid: uid_t
    /// Cumulative user + system CPU time.
    public let cpuTimeNanos: UInt64
    /// Physical footprint, the same figure Activity Monitor shows as "Memory".
    public let memoryBytes: UInt64

    public init(pid: pid_t, name: String, path: String?, uid: uid_t, cpuTimeNanos: UInt64, memoryBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.path = path
        self.uid = uid
        self.cpuTimeNanos = cpuTimeNanos
        self.memoryBytes = memoryBytes
    }
}

/// A process with usage derived from two consecutive snapshots.
public struct ProcessUsage: Identifiable, Equatable, Sendable {
    public let pid: pid_t
    public var name: String
    public let path: String?
    public let uid: uid_t
    /// Account name for `uid`, filled in by the caller (e.g. "root").
    public var ownerName: String?
    /// Percent of one core; multi-threaded processes can exceed 100.
    public let cpuPercent: Double
    public let memoryBytes: UInt64

    public var id: pid_t { pid }

    public init(pid: pid_t, name: String, path: String?, uid: uid_t, cpuPercent: Double, memoryBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.path = path
        self.uid = uid
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }

    /// Executable file name, independent of any user-facing app name.
    public var executableName: String {
        path.flatMap { $0.split(separator: "/").last.map(String.init) } ?? name
    }

    /// The outermost `.app` bundle containing the executable, if any.
    public var appBundlePath: String? {
        path.flatMap(AppBundle.outermostAppPath(in:))
    }

    /// Name of the app this process helps, or nil when it is the app's main executable or not part of an app.
    public var owningAppName: String? {
        guard let path, let appPath = appBundlePath else { return nil }
        let mainExecutableDir = appPath + "/Contents/MacOS/"
        if path.hasPrefix(mainExecutableDir), !path.dropFirst(mainExecutableDir.count).contains("/") {
            return nil
        }
        return AppBundle.displayName(ofAppPath: appPath)
    }
}

public enum Metric: String, CaseIterable, Sendable {
    case cpu
    case memory
}

/// Processes whose termination crashes or logs out the session; Dobby refuses to end them.
public enum SystemProcesses {
    private static let critical: Set<String> = ["kernel_task", "launchd", "WindowServer", "loginwindow"]

    public static func isCritical(pid: pid_t, executableName: String) -> Bool {
        pid <= 1 || critical.contains(executableName)
    }
}
