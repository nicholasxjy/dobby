import Foundation

// A privileged helper (DobbyHelper, launched as root after an admin password prompt) lets the
// unprivileged app read every user's processes and signal them. The app listens on a Unix socket
// inside its private temp directory; the helper connects, and each side verifies the other:
// the app requires the peer to be root, the helper requires the peer to be the PID that launched it.
// The helper only answers snapshot requests and relays SIGTERM/SIGKILL, and exits when the app disconnects.

public struct HelperSnapshot: Codable, Sendable {
    public let processes: [ProcessSnapshot]
    public let sockets: [SocketEntry]
}

enum HelperRequest: Codable {
    case snapshot
    case signal(pid: pid_t, signal: Int32)
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

/// App side of the helper connection. Methods block; requests are serialized.
public final class HelperClient: @unchecked Sendable {
    public let socketPath: String
    private let directory: String
    private var listener: Int32 = -1
    private var channel: LineChannel?
    private let lock = NSLock()

    public init() throws(HelperError) {
        // SO_NOSIGPIPE can't be set on a socket whose peer already closed (EINVAL), so a helper that
        // exits at the wrong moment would kill the app on the next write. Broken pipes surface as `.disconnected`.
        Darwin.signal(SIGPIPE, SIG_IGN)
        var template = Array((NSTemporaryDirectory() + "dobby.XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw .io(errno: errno) } // created with mode 0700
        directory = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        socketPath = directory + "/helper.sock"

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw .io(errno: errno) }
        let bound = withUnixAddress(socketPath) { bind(listener, $0, $1) }
        guard bound == 0, listen(listener, 1) == 0 else {
            let code = errno
            cleanUp()
            throw .io(errno: code)
        }
    }

    deinit {
        close()
    }

    /// Waits for the helper to connect and checks it runs as `requiredPeerUID` (root in production).
    public func acceptHelper(timeout: TimeInterval, requiredPeerUID: uid_t = 0) throws(HelperError) {
        var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&pending, 1, Int32(timeout * 1000)) > 0 else { throw .timedOut }
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { throw .io(errno: errno) }

        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == requiredPeerUID else {
            Darwin.close(fd)
            throw .peerRejected
        }
        // A hung helper must not freeze the UI.
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        lock.withLock { channel = LineChannel(fd: fd) }
        // Nobody else gets to connect.
        cleanUp()
    }

    public func snapshot() throws(HelperError) -> HelperSnapshot {
        guard case .snapshot(let snapshot) = try request(.snapshot) else { throw .disconnected }
        return snapshot
    }

    /// Returns 0 or an errno value, like `kill(2)`.
    public func signal(_ pid: pid_t, _ signal: Int32) -> Int32 {
        guard case .signalResult(let code)? = try? request(.signal(pid: pid, signal: signal)) else { return ECONNRESET }
        return code
    }

    public func close() {
        lock.withLock {
            channel?.close()
            channel = nil
        }
        cleanUp()
    }

    private func request(_ request: HelperRequest) throws(HelperError) -> HelperResponse {
        lock.lock()
        defer { lock.unlock() }
        guard let channel,
              let body = try? JSONEncoder().encode(request),
              channel.writeLine(body),
              let line = channel.readLine(),
              let response = try? JSONDecoder().decode(HelperResponse.self, from: line)
        else { throw .disconnected }
        return response
    }

    private func cleanUp() {
        lock.withLock {
            if listener >= 0 {
                Darwin.close(listener)
                listener = -1
            }
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

    public static func run(socketPath: String, clientPID: pid_t) -> Outcome {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .connectFailed }
        guard withUnixAddress(socketPath, { connect(fd, $0, $1) }) == 0 else {
            Darwin.close(fd)
            return .connectFailed
        }

        var peer: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) == 0, peer == clientPID else {
            Darwin.close(fd)
            return .peerRejected
        }

        let channel = LineChannel(fd: fd)
        defer { channel.close() }
        let sampler = ProcessSampler()
        let scanner = PortScanner()
        while let line = channel.readLine() {
            let response: HelperResponse
            switch try? JSONDecoder().decode(HelperRequest.self, from: line) {
            case .snapshot:
                response = .snapshot(HelperSnapshot(processes: sampler.snapshot(), sockets: scanner.scan()))
            case .signal(let pid, let signal):
                response = .signalResult(code: relay(signal, to: pid))
            case nil:
                response = .error("bad request")
            }
            guard let body = try? JSONEncoder().encode(response), channel.writeLine(body) else { break }
        }
        return .clientDisconnected
    }

    private static func relay(_ signal: Int32, to pid: pid_t) -> Int32 {
        guard signal == SIGTERM || signal == SIGKILL else { return EINVAL }
        guard pid > 1, pid != getpid() else { return EPERM }
        return kill(pid, signal) == 0 ? 0 : errno
    }
}

/// AppleScript that starts the helper as root via the standard admin password prompt.
public enum HelperLaunchScript {
    public static func make(
        helperPath: String,
        socketPath: String,
        clientPID: pid_t,
        prompt: String = "Dobby 需要管理员权限，以显示和结束系统进程。"
    ) -> String {
        "do shell script (quoted form of \(literal(helperPath))) & \" --connect \" & (quoted form of \(literal(socketPath)))"
            + " & \" --client-pid \(clientPID) >/dev/null 2>&1 &\""
            + " with prompt \(literal(prompt)) with administrator privileges"
    }

    private static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Newline-delimited messages over a stream socket.
final class LineChannel {
    private let fd: Int32
    private var buffer: [UInt8] = []

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    func writeLine(_ data: Data) -> Bool {
        var bytes = [UInt8](data)
        bytes.append(0x0A)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    func readLine() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeFirst(newline + 1)
                return line
            }
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[..<count])
        }
    }

    func close() {
        Darwin.close(fd)
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
