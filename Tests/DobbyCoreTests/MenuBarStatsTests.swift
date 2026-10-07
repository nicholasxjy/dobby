import Foundation
import Testing
@testable import DobbyCore

private func memory(used: UInt64, total: UInt64) -> MemoryStats {
    MemoryStats(usedBytes: used, totalBytes: total, appBytes: 0, wiredBytes: 0, compressedBytes: 0, pressure: .normal)
}

@Suite struct MenuBarSummaryTests {
    @Test func formatsWholePercentagesAndPortCount() {
        let summary = MenuBarSummary(cpu: 0.234, memory: memory(used: 6 << 30, total: 16 << 30), portCount: 14)
        #expect(summary.cpu == "23%")
        #expect(summary.memory == "38%")
        #expect(summary.ports == "14")
    }

    @Test func roundsToNearestAndClampsToRange() {
        #expect(MenuBarSummary(cpu: 0.995, memory: nil, portCount: nil).cpu == "100%")
        #expect(MenuBarSummary(cpu: 1.4, memory: nil, portCount: nil).cpu == "100%")
        #expect(MenuBarSummary(cpu: -0.1, memory: nil, portCount: nil).cpu == "0%")
        #expect(MenuBarSummary(cpu: nil, memory: memory(used: 20, total: 10), portCount: nil).memory == "100%")
    }

    @Test func showsADashUntilSampled() {
        let summary = MenuBarSummary(cpu: nil, memory: nil, portCount: nil)
        #expect(summary.cpu == "–")
        #expect(summary.memory == "–")
        #expect(summary.ports == "–")
        #expect(MenuBarSummary(cpu: nil, memory: memory(used: 0, total: 0), portCount: 0).memory == "–")
        #expect(MenuBarSummary(cpu: nil, memory: nil, portCount: 0).ports == "0")
    }

    @Test func describesTheValuesInFull() {
        let summary = MenuBarSummary(cpu: 0.5, memory: memory(used: 8 << 30, total: 16 << 30), portCount: 1)
        #expect(summary.description == "CPU 50% · Memory 50% (8.00 GB of 16.00 GB) · 1 port")
        #expect(MenuBarSummary(cpu: nil, memory: nil, portCount: 3).description == "CPU – · Memory – · 3 ports")
    }
}

@Suite struct MenuBarStatsStoreTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "dobby.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    @Test func offByDefault() {
        withDefaults { #expect(MenuBarStatsStore(defaults: $0).isEnabled == false) }
    }

    @Test func persistsTheChoice() {
        withDefaults { defaults in
            MenuBarStatsStore(defaults: defaults).isEnabled = true
            #expect(MenuBarStatsStore(defaults: defaults).isEnabled)
            MenuBarStatsStore(defaults: defaults).isEnabled = false
            #expect(MenuBarStatsStore(defaults: defaults).isEnabled == false)
        }
    }
}
