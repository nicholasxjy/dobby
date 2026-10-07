import Foundation
import Testing
@testable import DobbyCore

private final class BundleToken {}

@Suite struct HelperLaunchScriptTests {
    @Test func quotesPathsForBothAppleScriptAndShell() {
        let script = HelperLaunchScript.make(
            helperPath: #"/Apps/My "Dobby".app/Contents/MacOS/DobbyHelper"#,
            socketPath: #"/tmp/a\b c/h.sock"#,
            clientPID: 42
        )
        let escapedHelper = #"quoted form of "/Apps/My \"Dobby\".app/Contents/MacOS/DobbyHelper""#
        let escapedSocket = #"quoted form of "/tmp/a\\b c/h.sock""#
        #expect(script.contains(escapedHelper))
        #expect(script.contains(escapedSocket))
        #expect(script.contains("--client-pid 42"))
        #expect(script.contains("with administrator privileges"))
        // Backgrounded with output detached, so osascript returns as soon as the helper starts.
        #expect(script.contains(">/dev/null 2>&1 &"))
    }
}

/// Runs the helper server in-process (as the current user) against a real client socket.
@Suite(.serialized) struct HelperProtocolTests {
    private func startServer(socketPath: String, clientPID: pid_t) -> Task<HelperServer.Outcome, Never> {
        Task.detached { HelperServer.run(socketPath: socketPath, clientPID: clientPID) }
    }

    @Test func servesSnapshotsAndSignalsToTheLaunchingApp() async throws {
        let client = try HelperClient()
        let server = startServer(socketPath: client.socketPath, clientPID: getpid())
        try client.acceptHelper(timeout: 5, requiredPeerUID: getuid())

        let snapshot = try client.snapshot()
        #expect(snapshot.processes.contains { $0.pid == getpid() && $0.uid == getuid() })

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        #expect(client.signal(child.processIdentifier, SIGKILL) == 0)
        child.waitUntilExit()
        #expect(child.terminationStatus == SIGKILL)

        #expect(client.signal(1, SIGKILL) == EPERM, "pid 1 is always refused")
        #expect(client.signal(child.processIdentifier, SIGSTOP) == EINVAL, "only TERM and KILL are relayed")

        client.close()
        #expect(await server.value == .clientDisconnected)
    }

    @Test func helperRefusesAPeerThatIsNotTheLaunchingApp() async throws {
        let client = try HelperClient()
        let server = startServer(socketPath: client.socketPath, clientPID: getppid())
        try client.acceptHelper(timeout: 5, requiredPeerUID: getuid())
        #expect(await server.value == .peerRejected)
        #expect(throws: HelperError.self) { try client.snapshot() }
    }

    @Test func appRefusesAHelperThatIsNotRoot() async throws {
        try #require(getuid() != 0)
        let client = try HelperClient()
        let server = startServer(socketPath: client.socketPath, clientPID: getpid())
        #expect(throws: HelperError.peerRejected) { try client.acceptHelper(timeout: 5, requiredPeerUID: 0) }
        _ = await server.value
    }

    @Test func acceptTimesOutWhenNoHelperConnects() throws {
        let client = try HelperClient()
        #expect(throws: HelperError.timedOut) { try client.acceptHelper(timeout: 0.2, requiredPeerUID: getuid()) }
    }

    @Test func helperBinaryExitsWhenTheAppDisconnects() throws {
        let binary = Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("DobbyHelper")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path))

        let client = try HelperClient()
        let helper = Process()
        helper.executableURL = binary
        helper.arguments = ["--connect", client.socketPath, "--client-pid", String(getpid())]
        try helper.run()
        defer { if helper.isRunning { helper.terminate() } }

        try client.acceptHelper(timeout: 5, requiredPeerUID: getuid())
        #expect(try client.snapshot().sockets.allSatisfy { $0.port != 0 })
        client.close()

        let deadline = Date().addingTimeInterval(3)
        while helper.isRunning && Date() < deadline { usleep(20_000) }
        #expect(!helper.isRunning)
        #expect(helper.terminationStatus == 0)
    }
}
