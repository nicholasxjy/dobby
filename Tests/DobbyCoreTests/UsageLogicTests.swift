import Foundation
import Testing
@testable import DobbyCore

private func snap(_ pid: pid_t, _ name: String, cpu: UInt64, mem: UInt64 = 0, path: String? = nil, uid: uid_t = 501) -> ProcessSnapshot {
    ProcessSnapshot(pid: pid, name: name, path: path, uid: uid, cpuTimeNanos: cpu, memoryBytes: mem)
}

func usage(_ pid: pid_t, _ name: String, cpu: Double = 0, mem: UInt64 = 0, path: String? = nil, uid: uid_t = 501, owner: String? = nil) -> ProcessUsage {
    var usage = ProcessUsage(pid: pid, name: name, path: path, uid: uid, cpuPercent: cpu, memoryBytes: mem)
    usage.ownerName = owner
    return usage
}

@Suite struct UsageCalculatorTests {
    @Test func cpuPercentIsCPUTimeOverWallTime() {
        let previous = [snap(1, "a", cpu: 1_000_000_000), snap(2, "b", cpu: 0)]
        let current = [snap(1, "a", cpu: 1_500_000_000), snap(2, "b", cpu: 3_000_000_000)]
        let result = UsageCalculator.usages(previous: previous, current: current, elapsedNanos: 2_000_000_000)
        let byPID = Dictionary(uniqueKeysWithValues: result.map { ($0.pid, $0) })
        #expect(byPID[1]?.cpuPercent == 25)
        // Multi-threaded processes can exceed 100%, like Activity Monitor.
        #expect(byPID[2]?.cpuPercent == 150)
    }

    @Test func newProcessHasZeroCPUUntilSecondSample() {
        let result = UsageCalculator.usages(previous: [], current: [snap(7, "new", cpu: 9_000_000_000, mem: 42)], elapsedNanos: 1_000_000_000)
        #expect(result == [usage(7, "new", cpu: 0, mem: 42)])
    }

    @Test func carriesOwnerUID() {
        let result = UsageCalculator.usages(previous: [], current: [snap(9, "sshd", cpu: 0, uid: 0)], elapsedNanos: 1)
        #expect(result.first?.uid == 0)
    }

    @Test func reusedPIDIsTreatedAsNewProcess() {
        let previous = [snap(5, "old", cpu: 5_000_000_000)]
        let renamed = UsageCalculator.usages(previous: previous, current: [snap(5, "other", cpu: 6_000_000_000)], elapsedNanos: 1_000_000_000)
        let restarted = UsageCalculator.usages(previous: previous, current: [snap(5, "old", cpu: 100)], elapsedNanos: 1_000_000_000)
        #expect(renamed.first?.cpuPercent == 0)
        #expect(restarted.first?.cpuPercent == 0)
    }

    @Test func zeroElapsedTimeYieldsZeroCPU() {
        let result = UsageCalculator.usages(previous: [snap(1, "a", cpu: 0)], current: [snap(1, "a", cpu: 10)], elapsedNanos: 0)
        #expect(result.first?.cpuPercent == 0)
    }
}

@Suite struct ProcessRankingTests {
    let items = [
        usage(10, "Safari", cpu: 5, mem: 800),
        usage(11, "kernel_task", cpu: 30, mem: 100),
        usage(12, "Xcode", cpu: 30, mem: 2_000),
        usage(13, "Google Chrome Helper", cpu: 1, mem: 50,
              path: "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
    ]

    @Test func sortsByCPUDescendingWithNameAsTieBreaker() {
        let ranked = ProcessRanking.ranked(items, by: .cpu, query: "")
        #expect(ranked.map(\.pid) == [11, 12, 10, 13])
    }

    @Test func sortsByMemoryDescending() {
        let ranked = ProcessRanking.ranked(items, by: .memory, query: "")
        #expect(ranked.map(\.pid) == [12, 10, 11, 13])
    }

    @Test func filtersByNamePIDOrOwningAppCaseInsensitively() {
        #expect(ProcessRanking.ranked(items, by: .cpu, query: "safari").map(\.pid) == [10])
        #expect(ProcessRanking.ranked(items, by: .cpu, query: "12").map(\.pid) == [12])
        #expect(ProcessRanking.ranked(items, by: .cpu, query: "google chrome").map(\.pid) == [13])
        #expect(ProcessRanking.ranked(items, by: .cpu, query: "  ").count == 4)
    }

    @Test func filtersByOwnerName() {
        let mixed = items + [usage(1, "launchd", uid: 0, owner: "root"), usage(2, "WindowServer", uid: 88, owner: "_windowserver")]
        #expect(ProcessRanking.ranked(mixed, by: .cpu, query: "root").map(\.pid) == [1])
    }

    @Test func frozenOrderKeepsExistingRowsInPlaceAndAppendsNewOnes() {
        let fresh = [usage(3, "c", cpu: 90), usage(4, "d", cpu: 50), usage(1, "a", cpu: 10)]
        // pid 2 vanished, pid 4 is new; 1 and 3 keep their previous relative order.
        let frozen = ProcessRanking.applyingFrozenOrder(fresh, previousOrder: [1, 2, 3])
        #expect(frozen.map(\.pid) == [1, 3, 4])
        #expect(frozen.first?.cpuPercent == 10)
    }

    @Test func barScaleHasAFloorSoIdleProcessesLookSmall() {
        let idle = [usage(1, "a", cpu: 2, mem: 10 << 20)]
        #expect(ProcessRanking.barScale(for: idle, metric: .cpu) == 50)
        #expect(ProcessRanking.barScale(for: idle, metric: .memory) == Double(1 << 30))
        let busy = [usage(1, "a", cpu: 230, mem: 3 << 30)]
        #expect(ProcessRanking.barScale(for: busy, metric: .cpu) == 230)
        #expect(ProcessRanking.barScale(for: busy, metric: .memory) == Double(3 << 30))
    }
}

@Suite struct AppBundleTests {
    @Test func findsOutermostAppBundle() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/G.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(AppBundle.outermostAppPath(in: helper) == "/Applications/Google Chrome.app")
        #expect(AppBundle.displayName(ofAppPath: "/Applications/Google Chrome.app") == "Google Chrome")
        #expect(AppBundle.outermostAppPath(in: "/usr/libexec/trustd") == nil)
        #expect(AppBundle.outermostAppPath(in: "/opt/foo.application/bin/x") == nil)
    }

    @Test func helperUsageExposesOwningAppName() {
        let u = usage(1, "Code Helper", path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper")
        #expect(u.owningAppName == "Visual Studio Code")
        #expect(usage(2, "Visual Studio Code", path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron").owningAppName == nil)
    }
}

@Suite struct SystemProcessesTests {
    @Test func flagsProcessesThatWouldCrashOrLogOutTheSession() {
        #expect(SystemProcesses.isCritical(pid: 0, executableName: "kernel_task"))
        #expect(SystemProcesses.isCritical(pid: 1, executableName: "launchd"))
        #expect(SystemProcesses.isCritical(pid: 400, executableName: "WindowServer"))
        #expect(SystemProcesses.isCritical(pid: 401, executableName: "loginwindow"))
        #expect(!SystemProcesses.isCritical(pid: 402, executableName: "sshd"))
    }
}

@Suite struct UsageFormatTests {
    @Test func formatsBytesWithBinaryUnits() {
        #expect(UsageFormat.bytes(0) == "0 KB")
        #expect(UsageFormat.bytes(512 * 1024) == "512 KB")
        #expect(UsageFormat.bytes(1536 * 1024) == "1.5 MB")
        #expect(UsageFormat.bytes(UInt64(1.25 * 1024 * 1024 * 1024)) == "1.25 GB")
    }

    @Test func formatsPercentWithOneDecimal() {
        #expect(UsageFormat.percent(0) == "0.0%")
        #expect(UsageFormat.percent(12.345) == "12.3%")
        #expect(UsageFormat.percent(187.06) == "187.1%")
    }
}

@Suite struct SystemStatsTests {
    @Test func cpuUsageIsBusyTicksOverTotalTicks() {
        let a = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let b = CPUTicks(user: 160, system: 70, idle: 900, nice: 70)
        // busy delta = 60 + 20 + 20 = 100, total delta = 200
        #expect(SystemStats.cpuUsage(from: a, to: b) == 0.5)
        #expect(SystemStats.cpuUsage(from: a, to: a) == 0)
    }

    @Test func cpuLoadSplitsUserAndSystem() {
        let a = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let b = CPUTicks(user: 160, system: 70, idle: 900, nice: 70)
        // user = 60 + nice 20 = 80 of 200 ticks, system = 20 of 200.
        let load = SystemStats.cpuLoad(from: a, to: b)
        #expect(load == CPULoad(user: 0.4, system: 0.1))
        #expect(load.total == 0.5)
        #expect(SystemStats.cpuLoad(from: a, to: a) == CPULoad(user: 0, system: 0))
    }

    @Test func readsLiveMemoryAndCPU() throws {
        let memory = try #require(SystemStats.memory())
        #expect(memory.usedBytes > 0)
        #expect(memory.usedBytes <= memory.totalBytes)
        // "Used" is the sum of the breakdown shown in the memory legend.
        #expect(memory.appBytes + memory.wiredBytes + memory.compressedBytes >= memory.usedBytes)
        #expect(memory.appBytes > 0 && memory.wiredBytes > 0)
        #expect(SystemStats.cpuTicks() != nil)
    }
}

@Suite struct RingHistoryTests {
    @Test func keepsTheMostRecentValuesInOrder() {
        var history = RingHistory<Int>(capacity: 3)
        #expect(history.values.isEmpty)
        for value in 1...5 { history.append(value) }
        #expect(history.values == [3, 4, 5])
        #expect(history.capacity == 3)
    }
}
