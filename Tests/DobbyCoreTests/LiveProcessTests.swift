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

    @Test func samplerNoticesWhenAProcessExecsAnotherProgram() throws {
        let child = try spawn("/bin/sleep 0.4; exec /bin/sleep 5")
        defer { child.terminate() }
        usleep(100_000)
        let sampler = ProcessSampler()
        let before = try #require(sampler.snapshot().first { $0.pid == child.processIdentifier })
        #expect(before.path != "/bin/sleep") // the shell (/bin/sh itself hands over to bash or dash)

        usleep(600_000)
        let after = try #require(sampler.snapshot().first { $0.pid == child.processIdentifier })
        #expect(after.name == "sleep")
        #expect(after.path == "/bin/sleep")
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

    @Test(.enabled(if: ProcessIdentity.supportsSignals, "Requires identity-bound process signals"))
    func quitTerminatesNormalProcess() throws {
        let child = try spawn("exec /bin/sleep 30")
        usleep(50_000)
        try ProcessTerminator().terminate(ProcessIdentity.current(pid: child.processIdentifier), mode: .quit)
        #expect(waitForExit(child))
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGTERM)
    }

    @Test(.enabled(if: ProcessIdentity.supportsSignals, "Requires identity-bound process signals"))
    func forceQuitKillsProcessThatIgnoresQuit() throws {
        let child = try spawn("trap '' TERM; while :; do sleep 0.05; done")
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        usleep(100_000)
        let terminator = ProcessTerminator()

        try terminator.terminate(ProcessIdentity.current(pid: child.processIdentifier), mode: .quit)
        #expect(!waitForExit(child, timeout: 0.5), "SIGTERM should be ignored by the trap")

        try terminator.terminate(ProcessIdentity.current(pid: child.processIdentifier), mode: .forceQuit)
        #expect(waitForExit(child))
        #expect(child.terminationStatus == SIGKILL)
    }

    @Test func quitPrefersGracefulAppQuitWhenAvailable() throws {
        var signals: [(ProcessIdentity, Int32)] = []
        var appQuits: [ProcessIdentity] = []
        let terminator = ProcessTerminator(
            sendSignal: { signals.append(($0, $1)); return 0 },
            requestAppQuit: { appQuits.append($0); return $0.pid == 500 },
            validate: { _ in },
            ownPID: 1
        )
        try terminator.terminate(ProcessIdentity(pid: 500, startTime: 1), mode: .quit)
        try terminator.terminate(ProcessIdentity(pid: 501, startTime: 1), mode: .quit)
        try terminator.terminate(ProcessIdentity(pid: 500, startTime: 1), mode: .forceQuit)
        #expect(appQuits.map(\.pid) == [500, 501])
        #expect(signals.map { $0.0.pid } == [501, 500])
        #expect(signals.map(\.1) == [SIGTERM, SIGKILL])
    }

    @Test func unavailableAtomicSignalsNeverFallBackToPIDOnlySignals() throws {
        let child = try spawn("exec /bin/sleep 30")
        defer { if child.isRunning { child.terminate() } }
        let identity = try ProcessIdentity.current(pid: child.processIdentifier)
        #expect(identity.send(SIGKILL, using: nil) == ENOTSUP)
        #expect(child.isRunning)
    }

    @Test func staleIdentityCannotQuitOrSignalTheReplacement() throws {
        let child = try spawn("exec /bin/sleep 30")
        defer { if child.isRunning { child.terminate() } }
        let current = try ProcessIdentity.current(pid: child.processIdentifier)
        let stale = ProcessIdentity(pid: current.pid, startTime: current.startTime + 1)
        var signals = 0
        var appQuits = 0
        let terminator = ProcessTerminator(
            sendSignal: { _, _ in signals += 1; return 0 },
            requestAppQuit: { _ in appQuits += 1; return true }
        )
        #expect(throws: TerminationError.noSuchProcess) { try terminator.terminate(stale, mode: .quit) }
        #expect(throws: TerminationError.noSuchProcess) { try terminator.terminate(stale, mode: .forceQuit) }
        #expect(signals == 0)
        #expect(appQuits == 0)
        #expect(stale.send(SIGKILL) == ESRCH)
        #expect(child.isRunning)
    }

    @Test func signalBoundaryRejectsACurrentCriticalExecutable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("WindowServer")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: binary.path)
        let child = Process()
        child.executableURL = binary
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let identity = try ProcessIdentity.current(pid: child.processIdentifier)
        #expect(ProcessSampler.name(of: identity.pid) == "WindowServer")
        #expect(identity.send(SIGKILL) == EPERM)
        #expect(throws: TerminationError.protectedProcess) { try ProcessTerminator().terminate(identity, mode: .quit) }
        #expect(child.isRunning)
    }

    @Test func refusesProtectedProcessesAndReportsErrors() {
        let terminator = ProcessTerminator()
        #expect(throws: TerminationError.protectedProcess) { try terminator.terminate(ProcessIdentity(pid: 0, startTime: 1), mode: .forceQuit) }
        #expect(throws: TerminationError.protectedProcess) { try terminator.terminate(ProcessIdentity(pid: 1, startTime: 1), mode: .forceQuit) }
        #expect(throws: TerminationError.protectedProcess) { try terminator.terminate(ProcessIdentity(pid: getpid(), startTime: 1), mode: .forceQuit) }
        // launchd-owned root process: not permitted for a normal user.
        if getuid() != 0, let root = rootOwnedPID() {
            #expect(throws: TerminationError.notPermitted) { try terminator.terminate(ProcessIdentity.current(pid: root), mode: .quit) }
        }
        #expect(throws: TerminationError.noSuchProcess) { try terminator.terminate(ProcessIdentity(pid: 999_999, startTime: 1), mode: .quit) }
    }
}
