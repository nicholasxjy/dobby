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
    private let sendSignal: (ProcessIdentity, Int32) -> Int32
    private let requestAppQuit: (ProcessIdentity) -> Bool
    private let validate: (ProcessIdentity) throws(TerminationError) -> Void
    private let ownPID: pid_t

    public init(
        sendSignal: @escaping (ProcessIdentity, Int32) -> Int32 = { $0.send($1) },
        requestAppQuit: @escaping (ProcessIdentity) -> Bool = { _ in false },
        validate: @escaping (ProcessIdentity) throws(TerminationError) -> Void = { try $0.validate() },
        ownPID: pid_t = getpid()
    ) {
        self.sendSignal = sendSignal
        self.requestAppQuit = requestAppQuit
        self.validate = validate
        self.ownPID = ownPID
    }

    public func terminate(_ identity: ProcessIdentity, mode: TerminationMode) throws(TerminationError) {
        guard identity.pid > 1, identity.pid != ownPID else { throw .protectedProcess }
        try validate(identity)
        if mode == .quit, requestAppQuit(identity) { return }
        try Self.checkSignalResult(sendSignal(identity, mode == .quit ? SIGTERM : SIGKILL))
    }

    public static func checkSignalResult(_ code: Int32) throws(TerminationError) {
        switch code {
        case 0: return
        case EPERM, EACCES: throw .notPermitted
        case ESRCH: throw .noSuchProcess
        default: throw .failed(errno: code)
        }
    }
}
