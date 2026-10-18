import Darwin

/// Reads per-process CPU time and memory footprint via libproc.
/// Without root, only the current user's processes can be inspected; others are skipped.
public final class ProcessSampler {
    private struct Identity {
        let startTime: UInt64
        /// The kernel's short command name; it changes when the process execs another program.
        let command: (UInt64, UInt64)
        let name: String
        let path: String?
        let uid: uid_t
    }

    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64
    /// Path and name per process, so repeat samples skip the costly path lookup.
    /// Start time and command name tell a reused PID or an exec apart from the cached process.
    private var identities: [pid_t: Identity] = [:]

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebaseNumer = UInt64(info.numer)
        timebaseDenom = UInt64(max(info.denom, 1))
    }

    public func snapshot() -> [ProcessSnapshot] {
        let snapshots = allPIDs().compactMap(sample)
        if identities.count > snapshots.count * 2 {
            let live = Set(snapshots.map(\.pid))
            identities = identities.filter { live.contains($0.key) }
        }
        return snapshots
    }

    /// The short process name, or "PID n" when it can't be read.
    public static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "PID \(pid)" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func sample(_ pid: pid_t) -> ProcessSnapshot? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return nil }

        let identity = identity(of: pid, startTime: usage.ri_proc_start_abstime, info: shortInfo(pid))
        // rusage CPU times are in mach absolute time units (not ns on Apple Silicon).
        let ticks = usage.ri_user_time + usage.ri_system_time
        return ProcessSnapshot(
            pid: pid,
            name: identity.name,
            path: identity.path,
            uid: identity.uid,
            cpuTimeNanos: ticks * timebaseNumer / timebaseDenom,
            memoryBytes: usage.ri_phys_footprint
        )
    }

    private func identity(of pid: pid_t, startTime: UInt64, info: proc_bsdshortinfo?) -> Identity {
        let command = info.map { withUnsafeBytes(of: $0.pbsi_comm) { ($0.loadUnaligned(as: UInt64.self), $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) } } ?? (0, 0)
        let uid = info?.pbsi_uid ?? uid_t.max
        if let cached = identities[pid], cached.startTime == startTime, cached.command == command, cached.uid == uid {
            return cached
        }
        let path = executablePath(pid)
        let identity = Identity(
            startTime: startTime,
            command: command,
            name: path.flatMap { $0.split(separator: "/").last.map(String.init) } ?? Self.name(of: pid),
            path: path,
            uid: uid
        )
        // A process that can't be fully read yet (exec in progress) is looked up again next time.
        if path != nil, info != nil { identities[pid] = identity }
        return identity
    }

    private func shortInfo(_ pid: pid_t) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Every PID currently known to the kernel (including ones this user can't inspect).
func allPIDs() -> [pid_t] {
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
    let count = pids.withUnsafeMutableBytes { buffer in
        proc_listallpids(buffer.baseAddress, Int32(buffer.count))
    }
    guard count > 0 else { return [] }
    return pids.prefix(Int(count)).filter { $0 > 0 }
}
