import Foundation
import Testing
@testable import DobbyCore

private final class BundleToken {}

@Suite struct HelperLaunchScriptTests {
    @Test func quotesPathsForBothAppleScriptAndShell() {
        let script = HelperLaunchScript.make(
            helperPath: #"/Apps/My "Dobby".app/Contents/MacOS/DobbyHelper"#,
            socketPath: #"/tmp/a\b c/h.sock"#,
            clientIdentity: ProcessIdentity(pid: 42, startTime: 123)
        )
        let escapedHelper = #"quoted form of "/Apps/My \"Dobby\".app/Contents/MacOS/DobbyHelper""#
        let escapedSocket = #"quoted form of "/tmp/a\\b c/h.sock""#
        #expect(script.contains(escapedHelper))
        #expect(script.contains(escapedSocket))
        #expect(script.contains("--client-pid 42"))
        #expect(script.contains("--client-start-time 123"))
        #expect(script.contains("with administrator privileges"))
        // Backgrounded with output detached, so osascript returns as soon as the helper starts.
        #expect(script.contains(">/dev/null 2>&1 &"))
    }
}

/// Runs the helper server in-process (as the current user) against a real client socket.
@Suite(.serialized) struct HelperProtocolTests {
    private func startServer(socketPath: String, clientIdentity: ProcessIdentity) -> Task<HelperServer.Outcome, Never> {
        Task.detached { HelperServer.run(socketPath: socketPath, clientIdentity: clientIdentity) }
    }

    @Test func servesSnapshotsAndSignalsToTheLaunchingApp() async throws {
        let client = try HelperClient()
        let server = startServer(socketPath: client.socketPath, clientIdentity: try ProcessIdentity.current(pid: getpid()))
        try client.acceptHelper(timeout: 5, requiredPeerUID: getuid())

        let snapshot = try await client.snapshot()
        #expect(snapshot.processes.contains { $0.pid == getpid() && $0.uid == getuid() })

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let identity = try ProcessIdentity.current(pid: child.processIdentifier)
        let stale = ProcessIdentity(pid: identity.pid, startTime: identity.startTime + 1)
        #expect(await client.signal(stale, SIGKILL) == ESRCH)
        #expect(child.isRunning)
        if ProcessIdentity.supportsSignals {
            #expect(await client.signal(identity, SIGKILL) == 0)
        } else {
            #expect(await client.signal(identity, SIGKILL) == ENOTSUP)
            child.terminate()
        }
        child.waitUntilExit()
        #expect(child.terminationStatus == (ProcessIdentity.supportsSignals ? SIGKILL : SIGTERM))

        #expect(await client.signal(ProcessIdentity(pid: 1, startTime: 1), SIGKILL) == EPERM, "pid 1 is always refused")
        #expect(await client.signal(identity, SIGSTOP) == EINVAL, "only TERM and KILL are relayed")

        client.close()
        #expect(await server.value == .clientDisconnected)
    }

    @Test func helperRefusesAPeerThatIsNotTheLaunchingApp() async throws {
        let client = try HelperClient()
        let server = startServer(socketPath: client.socketPath, clientIdentity: ProcessIdentity(pid: getppid(), startTime: 1))
        try client.acceptHelper(timeout: 5, requiredPeerUID: getuid())
        #expect(await server.value == .peerRejected)
        await #expect(throws: HelperError.self) { try await client.snapshot() }
    }

    @Test func helperRejectsTheLaunchingPIDWithADifferentStartTime() async throws {
        let current = try ProcessIdentity.current(pid: getpid())
        let stale = ProcessIdentity(pid: current.pid, startTime: current.startTime + 1)
        let client = try HelperClient()
        let server = startServer(socketPath: client.socketPath, clientIdentity: stale)
        try client.acceptHelper(timeout: 1, requiredPeerUID: getuid())
        #expect(await server.value == .peerRejected)
        await #expect(throws: HelperError.self) { try await client.snapshot() }
    }

    @Test func appRefusesAHelperThatIsNotRoot() async throws {
        try #require(getuid() != 0)
        let client = try HelperClient()
        let server = startServer(socketPath: client.socketPath, clientIdentity: try ProcessIdentity.current(pid: getpid()))
        #expect(throws: HelperError.peerRejected) { try client.acceptHelper(timeout: 5, requiredPeerUID: 0) }
        _ = await server.value
    }

    @Test func acceptTimesOutWhenNoHelperConnects() throws {
        let client = try HelperClient()
        #expect(throws: HelperError.timedOut) { try client.acceptHelper(timeout: 0.2, requiredPeerUID: getuid()) }
    }

    @Test(arguments: [nil, "0", "invalid"] as [String?])
    func helperBinaryRequiresAValidStartIdentity(_ startTime: String?) throws {
        let binary = Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("DobbyHelper")
        let helper = Process()
        helper.executableURL = binary
        helper.arguments = ["--connect", "/unused", "--client-pid", String(getpid())]
        if let startTime { helper.arguments! += ["--client-start-time", startTime] }
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        helper.waitUntilExit()
        #expect(helper.terminationStatus == 64)
    }

    @Test func helperBinaryExitsWhenTheAppDisconnects() async throws {
        let binary = Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("DobbyHelper")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path))

        let client = try HelperClient()
        let helper = Process()
        helper.executableURL = binary
        let clientIdentity = try ProcessIdentity.current(pid: getpid())
        helper.arguments = ["--connect", client.socketPath, "--client-pid", String(clientIdentity.pid), "--client-start-time", String(clientIdentity.startTime)]
        try helper.run()
        defer { if helper.isRunning { helper.terminate() } }

        try client.acceptHelper(timeout: 5, requiredPeerUID: getuid())
        #expect(try await client.snapshot().sockets.allSatisfy { $0.port != 0 })
        client.close()

        let deadline = Date().addingTimeInterval(3)
        while helper.isRunning && Date() < deadline { usleep(20_000) }
        #expect(!helper.isRunning)
        #expect(helper.terminationStatus == 0)
    }
}
