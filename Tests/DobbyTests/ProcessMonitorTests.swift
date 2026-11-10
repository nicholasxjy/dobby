import DobbyCore
import Foundation
import Observation
import Testing
@testable import Dobby

@MainActor
@Suite struct ProcessMonitorTests {
    let target = ProcessIdentity(pid: 999_999, startTime: 1)

    @Test func reusedPIDClearsSelectionAndForceQuitConfirmation() async {
        var snapshots = [snapshot(startTime: 100)]
        let monitor = ProcessMonitor(sampleProcesses: { snapshots }, scanSockets: { [] })
        monitor.start()
        defer { monitor.stop() }
        await monitor.sample(publish: true)
        let old = snapshots[0].identity
        monitor.selection = old
        monitor.forceQuit(identity: old, name: "worker")
        snapshots = [snapshot(startTime: 200)]
        await monitor.sample(publish: true)
        #expect(monitor.rows.first?.identity == snapshots[0].identity)
        #expect(monitor.selection == nil)
        #expect(monitor.confirmingForceQuit == nil)
    }

    @Test func reusedPortOwnerClearsSelectionAndForceQuitConfirmation() async throws {
        var snapshots = [snapshot(startTime: 100)]
        let monitor = ProcessMonitor(sampleProcesses: { snapshots }, scanSockets: {
            [SocketEntry(pid: 999_999, proto: .tcp, address: "127.0.0.1", port: 8080)]
        })
        monitor.tab = .ports
        monitor.start()
        defer { monitor.stop() }
        await monitor.sample(publish: true)
        let oldPort = try #require(monitor.portRows.first)
        monitor.portSelection = oldPort.id
        monitor.forceQuit(identity: snapshots[0].identity, name: "worker")
        snapshots = [snapshot(startTime: 200)]
        await monitor.sample(publish: true)
        #expect(monitor.portRows.first?.id != oldPort.id)
        #expect(monitor.portSelection == nil)
        #expect(monitor.confirmingForceQuit == nil)
    }

    private func snapshot(startTime: UInt64) -> ProcessSnapshot {
        ProcessSnapshot(pid: 999_999, startTime: startTime, name: "worker", path: "/bin/worker", uid: getuid(), cpuTimeNanos: startTime, memoryBytes: 42)
    }

    @Test(.timeLimit(.minutes(1))) func helperSnapshotPopulatesTheVisiblePanel() async throws {
        let client = try HelperClient()
        let clientIdentity = try ProcessIdentity.current(pid: getpid())
        let server = Task.detached { HelperServer.run(socketPath: client.socketPath, clientIdentity: clientIdentity) }
        defer { client.close() }
        try await Task.detached { try client.acceptHelper(timeout: 1, requiredPeerUID: getuid()) }.value
        let monitor = ProcessMonitor(sampleProcesses: { [] }, scanSockets: { [] }, connectHelper: { client })
        defer { monitor.stop() }
        monitor.requestAllUsers()
        let access = try #require(monitor.confirmAllUsers())
        await access.value
        let published = AsyncStream<Void> { continuation in
            withObservationTracking {
                _ = monitor.rows
            } onChange: {
                continuation.yield(())
                continuation.finish()
            }
        }
        monitor.start()
        for await _ in published { break }
        let identity = try ProcessIdentity.current(pid: getpid())
        #expect(monitor.rows.contains { $0.identity == identity })
        #expect(monitor.systemAccess == .on)
        monitor.showMineOnly()
        monitor.stop()
        #expect(await server.value == .clientDisconnected)
    }

    @Test func mineCancelsAdministratorStartup() async throws {
        let launch = Suspended<HelperClient?>()
        let monitor = ProcessMonitor(connectHelper: { try await launch.call() })
        monitor.requestAllUsers()
        let task = try #require(monitor.confirmAllUsers())
        #expect(monitor.systemAccess == .requesting)
        await launch.waitUntilStarted()
        monitor.showMineOnly()
        #expect(monitor.systemAccess == .off)

        let client = try HelperClient()
        launch.finish(.success(client))
        await task.value
        #expect(monitor.systemAccess == .off)
        #expect(!FileManager.default.fileExists(atPath: client.socketPath))
    }

    @Test func mineBeforeStartupDoesNotOpenAnAdministratorPrompt() async throws {
        var calls = 0
        let monitor = ProcessMonitor(connectHelper: {
            calls += 1
            return nil
        })
        monitor.requestAllUsers()
        let task = try #require(monitor.confirmAllUsers())
        monitor.showMineOnly()
        await task.value
        #expect(calls == 0)
        #expect(monitor.systemAccess == .off)
    }

    @Test func administratorAccessCanStartAndStopWithoutSamplingAHiddenPanel() async throws {
        let client = try HelperClient()
        let monitor = ProcessMonitor(connectHelper: { client })
        monitor.requestAllUsers()
        let task = try #require(monitor.confirmAllUsers())
        await task.value
        #expect(monitor.systemAccess == .on)
        #expect(!monitor.hasSampled)
        monitor.showMineOnly()
        #expect(monitor.systemAccess == .off)
        #expect(!FileManager.default.fileExists(atPath: client.socketPath))
    }

    @Test func successfulNetworkSampleBecomesReady() async throws {
        let next = Suspended<[pid_t: NetworkRate]>()
        var calls = 0
        let monitor = ProcessMonitor(sampleNetwork: { _ in
            calls += 1
            if calls == 1 { return [:] }
            return try await next.call()
        })
        monitor.tab = .network
        monitor.start()
        let task = try #require(monitor.updateNetworkSampling())
        await next.waitUntilStarted()
        #expect(monitor.networkState == .ready)
        #expect(monitor.hasSampledNetwork)
        monitor.stop()
        next.finish(.success([:]))
        await task.value
        #expect(monitor.networkState == .idle)
    }

    @Test func repeatedContinueStartsOnlyOneRequest() async throws {
        let launch = Suspended<HelperClient?>()
        let monitor = ProcessMonitor(connectHelper: { try await launch.call() })
        monitor.requestAllUsers()
        let task = try #require(monitor.confirmAllUsers())
        #expect(monitor.confirmAllUsers() == nil)
        await launch.waitUntilStarted()
        launch.finish(.success(nil))
        await task.value
        #expect(monitor.systemAccess == .off)
        #expect(monitor.notice == nil)
    }

    @Test func cancelledRequestCannotOverwriteANewerRequest() async throws {
        let first = Suspended<HelperClient?>()
        let second = Suspended<HelperClient?>()
        var calls = 0
        let monitor = ProcessMonitor(connectHelper: {
            calls += 1
            return try await (calls == 1 ? first : second).call()
        })
        monitor.requestAllUsers()
        let old = try #require(monitor.confirmAllUsers())
        await first.waitUntilStarted()
        monitor.showMineOnly()
        monitor.requestAllUsers()
        let current = try #require(monitor.confirmAllUsers())
        await second.waitUntilStarted()
        first.finish(.failure(TestFailure.failed))
        await old.value
        #expect(monitor.systemAccess == .requesting)
        #expect(monitor.notice == nil)
        second.finish(.success(nil))
        await current.value
        #expect(monitor.systemAccess == .off)
    }

    @Test func cancelledNetworkFailureCannotOverwriteANewerSession() async throws {
        let first = Suspended<[pid_t: NetworkRate]>()
        let second = Suspended<[pid_t: NetworkRate]>()
        var calls = 0
        let monitor = ProcessMonitor(sampleNetwork: { _ in
            calls += 1
            return try await (calls == 1 ? first : second).call()
        })
        monitor.tab = .network
        monitor.start()
        defer { monitor.stop() }
        let old = try #require(monitor.updateNetworkSampling())
        await first.waitUntilStarted()
        monitor.isShowingSettings = true
        #expect(monitor.networkState == .idle)
        monitor.isShowingSettings = false
        let current = try #require(monitor.updateNetworkSampling())
        await second.waitUntilStarted()
        first.finish(.failure(TestFailure.failed))
        await old.value
        #expect(monitor.networkState == .loading)
        #expect(monitor.networkError == nil)
        monitor.stop()
        second.finish(.failure(TestFailure.failed))
        await current.value
        #expect(monitor.networkState == .idle)
    }

    @Test func networkFailureCanBeRetried() async throws {
        let failed = Suspended<[pid_t: NetworkRate]>()
        let retry = Suspended<[pid_t: NetworkRate]>()
        var calls = 0
        let monitor = ProcessMonitor(sampleNetwork: { _ in
            calls += 1
            return try await (calls == 1 ? failed : retry).call()
        })
        monitor.tab = .network
        monitor.start()
        defer { monitor.stop() }
        let task = try #require(monitor.updateNetworkSampling())
        await failed.waitUntilStarted()
        failed.finish(.failure(TestFailure.failed))
        await task.value
        #expect(monitor.networkError != nil)
        let retried = try #require(monitor.updateNetworkSampling())
        #expect(monitor.networkState == .loading)
        #expect(monitor.networkError == nil)
        await retry.waitUntilStarted()
        monitor.stop()
        retry.finish(.success([:]))
        await retried.value
        #expect(monitor.networkState == .idle)
    }

    @Test func settingsDoNotStartProcessSampling() async throws {
        let monitor = ProcessMonitor()
        monitor.isShowingSettings = true
        monitor.start()
        defer { monitor.stop() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!monitor.hasSampled)
        monitor.isShowingSettings = false
        await monitor.sample(publish: true)
        #expect(monitor.hasSampled)
    }

    @Test func hidingOrOpeningSettingsDisarmsForceQuit() {
        let monitor = ProcessMonitor()
        monitor.forceQuit(identity: target, name: "Test")
        #expect(monitor.confirmingForceQuit != nil)
        monitor.stop()
        #expect(monitor.confirmingForceQuit == nil)
        monitor.forceQuit(identity: target, name: "Test")
        monitor.isShowingSettings = true
        #expect(monitor.confirmingForceQuit == nil)
    }

    @Test func escapeDisarmsForceQuitBeforeClearingSelection() {
        let monitor = ProcessMonitor()
        monitor.selection = target
        monitor.forceQuit(identity: target, name: "Test")
        monitor.cancel()
        #expect(monitor.confirmingForceQuit == nil)
        #expect(monitor.selection == target)
        monitor.cancel()
        #expect(monitor.selection == nil)
    }

    @Test func staleConfirmationTimerDoesNotDisarmANewConfirmation() async throws {
        let monitor = ProcessMonitor()
        monitor.forceQuit(identity: target, name: "Test")
        try await Task.sleep(for: .milliseconds(1500))
        monitor.selection = target
        monitor.forceQuit(identity: target, name: "Test")
        try await Task.sleep(for: .milliseconds(1700))
        #expect(monitor.confirmingForceQuit == target)
        monitor.stop()
    }
}

private enum TestFailure: Error { case failed }

/// Holds a real asynchronous boundary until the test delivers its result.
@MainActor
private final class Suspended<Value: Sendable> {
    private var pending: CheckedContinuation<Value, any Error>?
    private var started: CheckedContinuation<Void, Never>?

    func call() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            precondition(pending == nil)
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ result: Result<Value, any Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}
