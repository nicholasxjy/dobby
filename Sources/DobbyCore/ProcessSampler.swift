import Darwin

/// Reads per-process CPU time and memory footprint via libproc.
/// Without root, only the current user's processes can be inspected; others are skipped.
public final class ProcessSampler {
    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebaseNumer = UInt64(info.numer)
        timebaseDenom = UInt64(max(info.denom, 1))
    }

    public func snapshot() -> [ProcessSnapshot] {
        allPIDs().compactMap(sample)
    }

    private func sample(_ pid: pid_t) -> ProcessSnapshot? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return nil }

        let path = executablePath(pid)
        let name = path.flatMap { $0.split(separator: "/").last.map(String.init) } ?? shortName(pid)
        // rusage CPU times are in mach absolute time units (not ns on Apple Silicon).
        let ticks = usage.ri_user_time + usage.ri_system_time
        return ProcessSnapshot(
            pid: pid,
            name: name,
            path: path,
            uid: owner(pid),
            cpuTimeNanos: ticks * timebaseNumer / timebaseDenom,
            memoryBytes: usage.ri_phys_footprint
        )
    }

    private func owner(_ pid: pid_t) -> uid_t {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size ? info.pbsi_uid : uid_t.max
    }

    private func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func shortName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "PID \(pid)" }
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
