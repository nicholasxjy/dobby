import Darwin

/// A PID plus the kernel start token, which remains distinct when a PID is recycled.
public struct ProcessIdentity: Hashable, Codable, Sendable {
    public let pid: pid_t
    public let startTime: UInt64

    public init(pid: pid_t, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
    }

    public static func current(pid: pid_t) throws(TerminationError) -> Self {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else {
            try ProcessTerminator.checkSignalResult(errno)
            throw .noSuchProcess
        }
        return Self(pid: pid, startTime: usage.ri_proc_start_abstime)
    }

    public func validate() throws(TerminationError) {
        guard startTime != 0, try Self.current(pid: pid) == self else { throw .noSuchProcess }
        guard !SystemProcesses.isCritical(pid: pid, executableName: ProcessSampler.name(of: pid)) else {
            throw .protectedProcess
        }
    }

    typealias AuditSignal = @convention(c) (UnsafeMutablePointer<audit_token_t>, Int32) -> Int32

    private static let nativeSignal: AuditSignal? = {
        // Darwin defines RTLD_DEFAULT as (void *)-2; Swift does not import that macro.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_signal_with_audittoken") else { return nil }
        return unsafeBitCast(symbol, to: AuditSignal.self)
    }()

    public static var supportsSignals: Bool { nativeSignal != nil }

    /// Signals the captured generation atomically; older systems fail closed.
    public func send(_ signal: Int32) -> Int32 {
        send(signal, using: Self.nativeSignal)
    }

    func send(_ signal: Int32, using nativeSignal: AuditSignal?) -> Int32 {
        guard signal == SIGTERM || signal == SIGKILL else { return EINVAL }
        guard pid > 1, pid != getpid() else { return EPERM }
        do {
            try validate()
            guard let nativeSignal else { return ENOTSUP }
            var token = try auditToken()
            return nativeSignal(&token, signal)
        } catch {
            switch error {
            case .protectedProcess, .notPermitted: return EPERM
            case .noSuchProcess: return ESRCH
            case .failed(let code): return code
            }
        }
    }

    private func auditToken() throws(TerminationError) -> audit_token_t {
        try validate()
        var port: mach_port_name_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &port) == KERN_SUCCESS else { throw .notPermitted }
        defer { mach_port_deallocate(mach_task_self_, port) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(port, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw .notPermitted }
        // A PID may have changed between acquiring its task port and reading the token.
        try validate()
        return token
    }
}
