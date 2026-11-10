import Darwin
import Foundation
import Testing
@testable import DobbyCore

/// Every fixture has an independent shutdown watchdog, including when the code under test hangs.
private final class TestPeer: @unchecked Sendable {
    let fd: Int32
    let channel: LineChannel

    init(fd: Int32) {
        self.fd = fd
        channel = LineChannel(fd: fd)
        let channel = channel
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { channel.close() }
    }

    func send(_ data: Data) {
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    func send(_ text: String) { send(Data(text.utf8)) }
    func close() { channel.close() }
}

@Suite(.serialized) struct HelperIOTests {
    private func connected(timeout: TimeInterval = 0.15) throws -> (HelperClient, TestPeer) {
        let client = try HelperClient(requestTimeout: timeout)
        let peer = try connectPeer(to: client.socketPath)
        try client.acceptHelper(timeout: 1, requiredPeerUID: getuid())
        return (client, peer)
    }

    private func connectPeer(to path: String) throws -> TestPeer {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperError.io(errno: errno) }
        let peer = TestPeer(fd: fd)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8) + [UInt8(0)]
            raw.copyBytes(from: bytes)
        }
        let code = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard code == 0 else { throw HelperError.io(errno: errno) }
        return peer
    }

    private func pair() throws -> (TestPeer, TestPeer) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw HelperError.io(errno: errno) }
        var size: Int32 = 1024
        #expect(setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)) == 0)
        return (TestPeer(fd: fds[0]), TestPeer(fd: fds[1]))
    }

    private func snapshotError(_ client: HelperClient) async -> HelperError? {
        do {
            _ = try await client.snapshot()
            Issue.record("Expected snapshot failure")
            return nil
        } catch { return error }
    }

    private var emptySnapshot: Data {
        get throws { try JSONEncoder().encode(HelperResponse.snapshot(HelperSnapshot(processes: [], sockets: []))) }
    }

    @Test func silentPeerTimesOutAndLateReplyCannotBeReused() async throws {
        let (client, peer) = try connected()
        defer { client.close(); peer.close() }
        let start = ContinuousClock.now
        #expect(await snapshotError(client) == .timedOut)
        #expect(start.duration(to: .now) < .seconds(1))
        peer.send(try emptySnapshot + Data([0x0A]))
        #expect(await snapshotError(client) == .disconnected)
        #expect(await client.signal(ProcessIdentity(pid: getpid(), startTime: 1), SIGTERM) == ECONNRESET)
    }

    @Test func trickledBytesDoNotExtendTheDeadline() async throws {
        let (client, peer) = try connected()
        defer { client.close(); peer.close() }
        let trickle = Task.detached {
            _ = try? peer.channel.readLine(deadline: IODeadline(timeout: 1))
            for _ in 0..<15 {
                peer.send(" ")
                usleep(30_000)
            }
        }
        let start = ContinuousClock.now
        #expect(await snapshotError(client) == .timedOut)
        #expect(start.duration(to: .now) < .milliseconds(400))
        await trickle.value
        #expect(await snapshotError(client) == .disconnected)
    }

    @Test(arguments: ["not json\n", "{\"signalResult\":{\"code\":0}}\n", "{\"error\":{\"_0\":\"bad request\"}}\n"])
    func badReplyInvalidatesEvenWithAValidReplyAlreadyBuffered(_ reply: String) async throws {
        let (client, peer) = try connected()
        defer { client.close(); peer.close() }
        peer.send(Data(reply.utf8) + (try emptySnapshot) + Data([0x0A]))
        #expect(await snapshotError(client) == .disconnected)
        #expect(await snapshotError(client) == .disconnected)
    }

    @Test func wrongSignalReplyInvalidatesConnection() async throws {
        let (client, peer) = try connected()
        defer { client.close(); peer.close() }
        peer.send(try emptySnapshot + Data([0x0A]))
        #expect(await client.signal(ProcessIdentity(pid: getpid(), startTime: 1), SIGTERM) == ECONNRESET)
        #expect(await snapshotError(client) == .disconnected)
    }

    @Test func peerEOFInvalidatesConnection() async throws {
        let (client, peer) = try connected()
        defer { client.close() }
        peer.close()
        #expect(await snapshotError(client) == .disconnected)
        #expect(await snapshotError(client) == .disconnected)
    }

    @Test func nonReadingPeerBoundsWrites() throws {
        let (writer, reader) = try pair()
        defer { writer.close(); reader.close() }
        let start = ContinuousClock.now
        #expect(throws: HelperError.timedOut) {
            try writer.channel.writeLine(Data(repeating: 65, count: 1024 * 1024), deadline: IODeadline(timeout: 0.15))
        }
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test func writeAndReadShareOneBudget() async throws {
        let (writer, reader) = try pair()
        defer { writer.close(); reader.close() }
        let response = Task.detached {
            usleep(100_000)
            _ = try? reader.channel.readLine(deadline: IODeadline(timeout: 1))
            usleep(120_000)
            reader.send("reply\n")
        }
        let deadline = IODeadline(timeout: 0.16)
        try writer.channel.writeLine(Data(repeating: 65, count: 256 * 1024), deadline: deadline)
        #expect(throws: HelperError.timedOut) { try writer.channel.readLine(deadline: deadline) }
        await response.value
    }

    @Test @MainActor func closeInterruptsIOWithoutBlockingMainActor() async throws {
        let (client, peer) = try connected(timeout: 1.5)
        defer { client.close(); peer.close() }
        let request = Task { await snapshotError(client) }
        // Receipt proves the RPC is waiting for its reply before close is timed.
        let received = await Task.detached {
            (try? peer.channel.readLine(deadline: IODeadline(timeout: 1))) != nil
        }.value
        #expect(received)
        let start = ContinuousClock.now
        client.close()
        #expect(start.duration(to: .now) < .milliseconds(200))
        #expect(await request.value == .disconnected)
    }

    @Test func closeInterruptsBackpressuredWrite() async throws {
        let (writer, reader) = try pair()
        defer { writer.close(); reader.close() }
        let writing = Task.detached { () -> HelperError? in
            do {
                try writer.channel.writeLine(Data(repeating: 65, count: 1024 * 1024), deadline: IODeadline(timeout: 1.5))
                return nil
            } catch { return error as? HelperError ?? .disconnected }
        }
        // POLLIN proves the writer started filling the socket.
        var pending = pollfd(fd: reader.fd, events: Int16(POLLIN), revents: 0)
        #expect(poll(&pending, 1, 1000) > 0)
        let start = ContinuousClock.now
        writer.close()
        #expect(start.duration(to: .now) < .milliseconds(200))
        #expect(await writing.value == .disconnected)
    }

    @Test func queuedRequestDeadlineIncludesQueueResidence() async throws {
        let (client, peer) = try connected(timeout: 0.5)
        defer { client.close(); peer.close() }
        let valid = try emptySnapshot + Data([0x0A])
        let first = Task { try await client.snapshot() }
        // Submit the second RPC only after the first occupies the queue.
        _ = try await Task.detached {
            try peer.channel.readLine(deadline: IODeadline(timeout: 1))
        }.value
        let second = Task { await snapshotError(client) }
        let responding = Task.detached {
            usleep(300_000)
            peer.send(valid)
            _ = try? peer.channel.readLine(deadline: IODeadline(timeout: 1))
            usleep(300_000)
            peer.send(valid)
        }
        #expect(try await first.value.processes.isEmpty)
        #expect(await second.value == .timedOut)
        await responding.value
    }

    @Test func queuedRequestsFailAfterFirstTimeout() async throws {
        let (client, peer) = try connected()
        defer { client.close(); peer.close() }
        async let first = snapshotError(client)
        async let second = snapshotError(client)
        let errors = await [first, second]
        #expect(errors.contains(.timedOut))
        #expect(errors.contains(.disconnected))
    }

    @Test func closeRacingAcceptCannotInstallAConnectionOrLeaveSocketFiles() async throws {
        for iteration in 0..<20 {
            let client = try HelperClient()
            let path = client.socketPath
            // Alternate idle and already-connected listeners to cover both ownership races.
            let peer = try iteration % 2 == 0 ? connectPeer(to: path) : nil
            defer { peer?.close() }
            let accepting = Task.detached { () -> HelperError? in
                do {
                    try client.acceptHelper(timeout: 1, requiredPeerUID: getuid())
                    return nil
                } catch { return error as? HelperError ?? .disconnected }
            }
            client.close()
            let result = await accepting.value
            #expect(result == nil || result == .disconnected)
            #expect(!FileManager.default.fileExists(atPath: path))
            #expect(!FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
            #expect(await snapshotError(client) == .disconnected)
        }
    }
}
