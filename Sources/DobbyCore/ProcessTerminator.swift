import Darwin

public enum TerminationMode: Sendable {
    /// Graceful: asks apps to quit (they may prompt to save) or sends SIGTERM.
    case quit
    /// Immediate SIGKILL; unsaved data is lost.
    case forceQuit
}

public enum TerminationError: Error, Equatable {
    case protectedProcess
    case notPermitted
    case noSuchProcess
    case failed(errno: Int32)
}

public struct ProcessTerminator {
    /// Returns 0 on success or an errno value.
    private let sendSignal: (pid_t, Int32) -> Int32
    /// Returns true when the PID belongs to an app that accepted a graceful quit request.
    private let requestAppQuit: (pid_t) -> Bool
    private let ownPID: pid_t

    public init(
        sendSignal: @escaping (pid_t, Int32) -> Int32 = { kill($0, $1) == 0 ? 0 : errno },
        requestAppQuit: @escaping (pid_t) -> Bool = { _ in false },
        ownPID: pid_t = getpid()
    ) {
        self.sendSignal = sendSignal
        self.requestAppQuit = requestAppQuit
        self.ownPID = ownPID
    }

    public func terminate(_ pid: pid_t, mode: TerminationMode) throws(TerminationError) {
        guard pid > 1, pid != ownPID else { throw .protectedProcess }
        if mode == .quit, requestAppQuit(pid) { return }

        switch sendSignal(pid, mode == .quit ? SIGTERM : SIGKILL) {
        case 0: return
        case EPERM: throw .notPermitted
        case ESRCH: throw .noSuchProcess
        case let code: throw .failed(errno: code)
        }
    }
}
