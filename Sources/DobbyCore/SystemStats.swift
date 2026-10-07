import Darwin

public struct CPUTicks: Equatable, Sendable {
    public let user: UInt64
    public let system: UInt64
    public let idle: UInt64
    public let nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Fractions (0...1) of total CPU capacity across all cores.
public struct CPULoad: Equatable, Sendable {
    public let user: Double
    public let system: Double

    public init(user: Double, system: Double) {
        self.user = user
        self.system = system
    }

    public var total: Double { user + system }
}

/// The most recent `capacity` values, oldest first.
public struct RingHistory<Element: Sendable>: Sendable {
    public let capacity: Int
    public private(set) var values: [Element] = []

    public init(capacity: Int) {
        self.capacity = capacity
    }

    public mutating func append(_ value: Element) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
}

public enum MemoryPressure: Sendable {
    case normal, warning, critical
}

public struct MemoryStats: Equatable, Sendable {
    /// App memory + wired + compressed, matching Activity Monitor's "Memory Used".
    public let usedBytes: UInt64
    public let totalBytes: UInt64
    public let appBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let pressure: MemoryPressure
}

public enum SystemStats {
    private static let host = mach_host_self()

    public static var coreCount: Int { ProcessInfo.activeCores }

    public static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        return CPUTicks(user: UInt64(ticks.0), system: UInt64(ticks.1), idle: UInt64(ticks.2), nice: UInt64(ticks.3))
    }

    /// Fraction (0...1) of all cores that were busy between two readings.
    public static func cpuUsage(from start: CPUTicks, to end: CPUTicks) -> Double {
        cpuLoad(from: start, to: end).total
    }

    /// Busy time split into user (including nice) and system, as fractions of all cores.
    public static func cpuLoad(from start: CPUTicks, to end: CPUTicks) -> CPULoad {
        func delta(_ a: UInt64, _ b: UInt64) -> Double { b >= a ? Double(b - a) : 0 }
        let user = delta(start.user, end.user) + delta(start.nice, end.nice)
        let system = delta(start.system, end.system)
        let total = user + system + delta(start.idle, end.idle)
        guard total > 0 else { return CPULoad(user: 0, system: 0) }
        return CPULoad(user: user / total, system: system / total)
    }

    public static func memory() -> MemoryStats? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(sysconf(_SC_PAGESIZE))
        let appPages = UInt64(info.internal_page_count) - min(UInt64(info.purgeable_count), UInt64(info.internal_page_count))
        let wiredPages = UInt64(info.wire_count)
        let compressedPages = UInt64(info.compressor_page_count)
        let total = ProcessInfo.physicalMemory
        return MemoryStats(
            usedBytes: min((appPages + wiredPages + compressedPages) * pageSize, total),
            totalBytes: total,
            appBytes: appPages * pageSize,
            wiredBytes: wiredPages * pageSize,
            compressedBytes: compressedPages * pageSize,
            pressure: pressure()
        )
    }

    private static func pressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }
}

private enum ProcessInfo {
    static var physicalMemory: UInt64 { sysctlValue("hw.memsize") ?? 0 }
    static var activeCores: Int { Int(sysctlValue("hw.activecpu") as Int32? ?? 1) }

    private static func sysctlValue<T: FixedWidthInteger>(_ name: String) -> T? {
        var value: T = 0
        var size = MemoryLayout<T>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}
