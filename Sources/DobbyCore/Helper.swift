import Foundation

// A privileged helper (DobbyHelper, launched as root after an admin password prompt) lets the
// unprivileged app read every user's processes and signal them. The app listens on a Unix socket
// inside its private temp directory; the helper connects, and each side verifies the other:
// the app requires the peer to be root; the helper requires the launching app's PID and start token.
// The helper only answers snapshot requests and relays SIGTERM/SIGKILL, and exits when the app disconnects.

public struct HelperSnapshot: Codable, Sendable {
    public let processes: [ProcessSnapshot]
    public let sockets: [SocketEntry]
}

enum HelperRequest: Codable {
    case snapshot
    case signal(identity: ProcessIdentity, signal: Int32)
}

enum HelperResponse: Codable {
    case snapshot(HelperSnapshot)
    case signalResult(code: Int32)
    case error(String)
}

public enum HelperError: Error, Equatable {
    case timedOut
    case peerRejected
    case disconnected
    case io(errno: Int32)
}

/// App side of the helper connection. RPCs run on a serial queue, away from the caller's actor.
public final class HelperClient: @unchecked Sendable {
    public let socketPath: String
    private let directory: String
    private let requestTimeout: TimeInterval
    private let rpcQueue = DispatchQueue(label: "Dobby.HelperClient")
    private var listener: Int32 = -1
    private var channel: LineChannel?
    private var closed = false
    private var accepting = false
    // Protects ownership only; never held while waiting for socket readiness or a reply.
    private let lock = NSLock()

    public init(requestTimeout: TimeInterval = 3) throws(HelperError) {
        Darwin.signal(SIGPIPE, SIG_IGN)
        self.requestTimeout = requestTimeout
        var template = Array((NSTemporaryDirectory() + "dobby.XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw .io(errno: errno) }
        directory = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        socketPath = directory + "/helper.sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            let code = errno
            rmdir(directory)
            throw .io(errno: code)
        }
        let bound = withUnixAddress(socketPath) { bind(listener, $0, $1) }
        guard bound == 0, listen(listener, 1) == 0,
              fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else {
            let code = errno
            close()
            throw .io(errno: code)
        }
    }

    deinit { close() }

    /// Call off the main actor. Checks that the helper runs as `requiredPeerUID` (root in production).
    public func acceptHelper(timeout: TimeInterval, requiredPeerUID: uid_t = 0) throws(HelperError) {
        // A duplicate keeps the descriptor alive if close() races with poll/accept.
        let listening: Int32 = lock.withLock {
            guard !closed, !accepting, listener >= 0 else { return -1 }
            let copy = dup(listener)
            if copy >= 0 { accepting = true }
            return copy
        }
        guard listening >= 0 else { throw .disconnected }
        defer {
            Darwin.close(listening)
            lock.withLock { accepting = false }
        }
        let deadline = IODeadline(timeout: timeout)
        while true {
            guard lock.withLock({ !closed }) else { throw .disconnected }
            // Bounded slices also handle platforms where shutdown does not wake a listening socket.
            var pending = pollfd(fd: listening, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pending, 1, min(50, try deadline.millisecondsRemaining()))
            if ready < 0 {
                if errno == EINTR { continue }
                throw .io(errno: errno)
            }
            if ready == 0 { continue }
            let fd = accept(listening, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw .io(errno: errno)
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == requiredPeerUID else {
                Darwin.close(fd)
                throw .peerRejected
            }
            let accepted = LineChannel(fd: fd)
            let installed = lock.withLock {
                guard !closed else { return false }
                channel = accepted
                cleanUpListener()
                return true
            }
            guard installed else {
                accepted.close()
                throw .disconnected
            }
            return
        }
    }

    public func snapshot() async throws(HelperError) -> HelperSnapshot {
        guard case .snapshot(let snapshot) = try await request(.snapshot) else { throw .disconnected }
        return snapshot
    }

    /// Returns 0 or an errno value, like `kill(2)`.
    public func signal(_ identity: ProcessIdentity, _ signal: Int32) async -> Int32 {
        guard case .signalResult(let code)? = try? await request(.signal(identity: identity, signal: signal)) else { return ECONNRESET }
        return code
    }

    public func close() {
        lock.withLock {
            closed = true
            channel?.close()
            channel = nil
            cleanUpListener()
        }
    }

    private func request(_ request: HelperRequest) async throws(HelperError) -> HelperResponse {
        let deadline = IODeadline(timeout: requestTimeout)
        guard let body = try? JSONEncoder().encode(request) else {
            close()
            throw .disconnected
        }
        let expectsSnapshot: Bool
        switch request {
        case .snapshot: expectsSnapshot = true
        case .signal: expectsSnapshot = false
        }
        let result: Result<HelperResponse, HelperError> = await withCheckedContinuation { continuation in
            rpcQueue.async {
                guard let channel = self.lock.withLock({ self.channel }) else {
                    continuation.resume(returning: .failure(.disconnected))
                    return
                }
                do {
                    try channel.writeLine(body, deadline: deadline)
                    let line = try channel.readLine(deadline: deadline)
                    guard let response = try? JSONDecoder().decode(HelperResponse.self, from: line) else {
                        throw HelperError.disconnected
                    }
                    _ = try deadline.millisecondsRemaining()
                    switch response {
                    case .snapshot where expectsSnapshot, .signalResult where !expectsSnapshot:
                        continuation.resume(returning: .success(response))
                    default:
                        self.close()
                        continuation.resume(returning: .failure(.disconnected))
                    }
                } catch {
                    self.close()
                    continuation.resume(returning: .failure(error as? HelperError ?? .disconnected))
                }
            }
        }
        return try result.get()
    }

    /// Requires lock. Unlink under the same lock so accept and close cannot race directory cleanup.
    private func cleanUpListener() {
        if listener >= 0 {
            Darwin.close(listener)
            listener = -1
        }
        unlink(socketPath)
        rmdir(directory)
    }
}

/// Helper side: connects to the app, verifies it, then serves requests until the app disconnects.
public enum HelperServer {
    public enum Outcome: Equatable, Sendable {
        case clientDisconnected
        case peerRejected
        case connectFailed
    }

    public static func run(socketPath: String, clientIdentity: ProcessIdentity) -> Outcome {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .connectFailed }
        guard withUnixAddress(socketPath, { connect(fd, $0, $1) }) == 0 else {
            Darwin.close(fd)
            return .connectFailed
        }

        var peer: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) == 0, peer == clientIdentity.pid,
              (try? ProcessIdentity.current(pid: peer)) == clientIdentity else {
            Darwin.close(fd)
            return .peerRejected
        }

        let channel = LineChannel(fd: fd)
        defer { channel.close() }
        let sampler = ProcessSampler()
        let scanner = PortScanner()
        while let line = channel.readLine() {
            guard (try? ProcessIdentity.current(pid: peer)) == clientIdentity else { return .peerRejected }
            let response: HelperResponse
            switch try? JSONDecoder().decode(HelperRequest.self, from: line) {
            case .snapshot:
                response = .snapshot(HelperSnapshot(processes: sampler.snapshot(), sockets: scanner.scan()))
            case .signal(let identity, let signal):
                response = .signalResult(code: identity.send(signal))
            case nil:
                response = .error("bad request")
            }
            guard let body = try? JSONEncoder().encode(response), channel.writeLine(body) else { break }
        }
        return .clientDisconnected
    }

}

/// AppleScript that starts the helper as root via the standard admin password prompt.
public enum HelperLaunchScript {
    public static func make(
        helperPath: String,
        socketPath: String,
        clientIdentity: ProcessIdentity,
        prompt: String = "Dobby needs administrator privileges to show and end system processes."
    ) -> String {
        "do shell script (quoted form of \(literal(helperPath))) & \" --connect \" & (quoted form of \(literal(socketPath)))"
            + " & \" --client-pid \(clientIdentity.pid) --client-start-time \(clientIdentity.startTime) >/dev/null 2>&1 &\""
            + " with prompt \(literal(prompt)) with administrator privileges"
    }

    private static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// One absolute monotonic budget, shared by every read and write in an RPC.
struct IODeadline: Sendable {
    private let end: UInt64

    init(timeout: TimeInterval) {
        let now = DispatchTime.now().uptimeNanoseconds
        let seconds = timeout.isFinite ? max(0, min(timeout, 86_400)) : 0
        end = now + UInt64(seconds * 1_000_000_000)
    }

    func millisecondsRemaining() throws(HelperError) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < end else { throw .timedOut }
        return Int32(min(UInt64(Int32.max), (end - now + 999_999) / 1_000_000))
    }
}

/// Newline-delimited messages over a nonblocking stream socket.
final class LineChannel: @unchecked Sendable {
    private let fd: Int32
    private var buffer: [UInt8] = []
    private let lock = NSLock()
    private var closed = false
    private let setupError: Int32?

    init(fd: Int32) {
        self.fd = fd
        let flags = fcntl(fd, F_GETFL)
        setupError = flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 ? errno : nil
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    // Active operations retain the channel: shutdown wakes them, and the fd cannot be reused
    // until their references disappear. close() never waits for the RPC queue.
    deinit { Darwin.close(fd) }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            shutdown(fd, SHUT_RDWR)
        }
    }

    // The helper server has no idle timeout and exits on EOF, as before.
    func writeLine(_ data: Data) -> Bool { (try? writeLine(data, deadline: nil)) != nil }
    func readLine() -> Data? { try? readLine(deadline: nil) }

    func writeLine(_ data: Data, deadline: IODeadline?) throws(HelperError) {
        var bytes = [UInt8](data)
        bytes.append(0x0A)
        var offset = 0
        if let setupError { throw .io(errno: setupError) }
        while offset < bytes.count {
            if let deadline { _ = try deadline.millisecondsRemaining() }
            guard lock.withLock({ !closed }) else { throw .disconnected }
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written < 0 && errno == EINTR { continue }
            if written < 0 && errno == EAGAIN {
                try wait(for: Int16(POLLOUT), deadline: deadline)
                continue
            }
            guard written > 0 else { throw .disconnected }
            offset += written
        }
    }

    func readLine(deadline: IODeadline?) throws(HelperError) -> Data {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var searched = 0
        if let setupError { throw .io(errno: setupError) }
        while true {
            if let deadline { _ = try deadline.millisecondsRemaining() }
            guard lock.withLock({ !closed }) else { throw .disconnected }
            if let newline = buffer[searched...].firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeFirst(newline + 1)
                return line
            }
            searched = buffer.count
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN {
                try wait(for: Int16(POLLIN), deadline: deadline)
                continue
            }
            guard count > 0 else { throw .disconnected }
            buffer.append(contentsOf: chunk[..<count])
        }
    }

    private func wait(for event: Int16, deadline: IODeadline?) throws(HelperError) {
        if let setupError { throw .io(errno: setupError) }
        while true {
            guard lock.withLock({ !closed }) else { throw .disconnected }
            let timeout: Int32
            if let deadline { timeout = try deadline.millisecondsRemaining() } else { timeout = -1 }
            var pending = pollfd(fd: fd, events: event, revents: 0)
            let ready = poll(&pending, 1, timeout)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw .io(errno: errno) }
            guard ready > 0 else { throw .timedOut }
            if let deadline { _ = try deadline.millisecondsRemaining() }
            guard pending.revents & event != 0 else { throw .disconnected }
            return
        }
    }
}

private func withUnixAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        let bytes = Array(path.utf8.prefix(capacity - 1))
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}
