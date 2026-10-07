import Foundation
import Testing
@testable import DobbyCore

/// Exercises the real sampler and terminator against child processes spawned by the test.
@Suite(.serialized) struct LiveProcessTests {
    private func spawn(_ script: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        return process
    }

    private func rootOwnedPID() -> pid_t? {
        let pgrep = Process()
        let pipe = Pipe()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-u", "root", "-x", "notifyd"]
        pgrep.standardOutput = pipe
        guard (try? pgrep.run()) != nil else { return nil }
        pgrep.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").first.flatMap { pid_t($0) }
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        return !process.isRunning
    }

    @Test func samplerSeesCurrentAndChildProcesses() throws {
        let child = try spawn("exec /bin/sleep 30")
        defer { child.terminate() }
        usleep(100_000)

        let snapshots = ProcessSampler().snapshot()
        let me = try #require(snapshots.first { $0.pid == getpid() })
        #expect(me.memoryBytes > 0)
        #expect(me.uid == getuid())
        #expect(me.cpuTimeNanos > 0)

        let sleeper = try #require(snapshots.first { $0.pid == child.processIdentifier })
        #expect(sleeper.name == "sleep")
        #expect(sleeper.path == "/bin/sleep")
    }

    @Test func samplerMeasuresBusyProcessCPU() throws {
        let child = try spawn("while :; do :; done")
        defer { child.terminate() }
        usleep(100_000) // let /bin/sh finish exec so the name is stable across samples
        let sampler = ProcessSampler()
        let first = sampler.snapshot()
        let start = DispatchTime.now().uptimeNanoseconds
        usleep(500_000)
        let second = sampler.snapshot()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        let usages = UsageCalculator.usages(previous: first, current: second, elapsedNanos: elapsed)
        let busy = try #require(usages.first { $0.pid == child.processIdentifier })
        #expect(busy.cpuPercent > 50)
        #expect(busy.cpuPercent < 130)
    }

    @Test func quitTerminatesNormalProcess() throws {
        let child = try spawn("exec /bin/sleep 30")
        usleep(50_000)
        try ProcessTerminator().terminate(child.processIdentifier, mode: .quit)
        #expect(waitForExit(child))
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGTERM)
    }

    @Test func forceQuitKillsProcessThatIgnoresQuit() throws {
        let child = try spawn("trap '' TERM; while :; do sleep 0.05; done")
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        usleep(100_000)
        let terminator = ProcessTerminator()

        try terminator.terminate(child.processIdentifier, mode: .quit)
        #expect(!waitForExit(child, timeout: 0.5), "SIGTERM should be ignored by the trap")

        try terminator.terminate(child.processIdentifier, mode: .forceQuit)
        #expect(waitForExit(child))
        #expect(child.terminationStatus == SIGKILL)
    }

    @Test func quitPrefersGracefulAppQuitWhenAvailable() throws {
        var signals: [(pid_t, Int32)] = []
        var appQuits: [pid_t] = []
        let terminator = ProcessTerminator(
            sendSignal: { signals.append(($0, $1)); return 0 },
            requestAppQuit: { appQuits.append($0); return $0 == 500 },
            ownPID: 1
        )
        try terminator.terminate(500, mode: .quit)
        try terminator.terminate(501, mode: .quit)
        try terminator.terminate(500, mode: .forceQuit)
        #expect(appQuits == [500, 501])
        #expect(signals.map(\.0) == [501, 500])
        #expect(signals.map(\.1) == [SIGTERM, SIGKILL])
    }

    @Test func refusesProtectedProcessesAndReportsErrors() {
        let terminator = ProcessTerminator()
        #expect(throws: TerminationError.protectedProcess) { try terminator.terminate(0, mode: .forceQuit) }
        #expect(throws: TerminationError.protectedProcess) { try terminator.terminate(1, mode: .forceQuit) }
        #expect(throws: TerminationError.protectedProcess) { try terminator.terminate(getpid(), mode: .forceQuit) }
        // launchd-owned root process: not permitted for a normal user.
        if getuid() != 0, let root = rootOwnedPID() {
            #expect(throws: TerminationError.notPermitted) { try terminator.terminate(root, mode: .quit) }
        }
        #expect(throws: TerminationError.noSuchProcess) { try terminator.terminate(999_999, mode: .quit) }
    }
}
