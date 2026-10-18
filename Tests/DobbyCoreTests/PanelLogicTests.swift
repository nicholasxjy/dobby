import Foundation
import Testing
@testable import DobbyCore

@Suite struct ProcessDisplayLabelTests {
    let me: uid_t = 501

    @Test func showsHelpersUnderTheirAppWithTheirRole() {
        let chrome = usage(1, "Google Chrome Helper (Renderer)", path: "/Applications/Google Chrome.app/Contents/Frameworks/G.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)")
        #expect(chrome.displayLabel(currentUID: me) == ProcessDisplayLabel(title: "Google Chrome", detail: "Renderer helper"))

        let plain = usage(2, "Slack Helper", path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper")
        #expect(plain.displayLabel(currentUID: me) == ProcessDisplayLabel(title: "Slack", detail: "Helper"))
    }

    @Test func namesOtherNestedExecutablesAsTheDetail() {
        let docker = usage(3, "com.docker.backend", path: "/Applications/Docker.app/Contents/Resources/bin/com.docker.backend")
        #expect(docker.displayLabel(currentUID: me) == ProcessDisplayLabel(title: "Docker", detail: "com.docker.backend"))
    }

    @Test func keepsAppsAndToolsAsTheyAre() {
        let app = usage(4, "Visual Studio Code", path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron")
        #expect(app.displayLabel(currentUID: me) == ProcessDisplayLabel(title: "Visual Studio Code", detail: nil))
        #expect(usage(5, "nvim", path: "/opt/homebrew/bin/nvim").displayLabel(currentUID: me) == ProcessDisplayLabel(title: "nvim", detail: nil))
    }

    @Test func addsTheOwnerForOtherUsers() {
        let root = usage(6, "sysmond", path: "/usr/libexec/sysmond", uid: 0, owner: "root")
        #expect(root.displayLabel(currentUID: me) == ProcessDisplayLabel(title: "sysmond", detail: "root"))

        let rootHelper = usage(7, "Dobby Helper (GPU)", path: "/Applications/Dobby.app/Contents/Helpers/Dobby Helper (GPU)", uid: 0, owner: "root")
        #expect(rootHelper.displayLabel(currentUID: me).detail == "GPU helper · root")
    }
}

@Suite struct PortDisplayLabelTests {
    @Test func portsUseTheSameHelperNaming() {
        let processes: [pid_t: ProcessUsage] = [
            5: usage(5, "Google Chrome Helper (Aperitif)", path: "/Applications/Google Chrome.app/Contents/Frameworks/G.framework/Helpers/Google Chrome Helper (Aperitif).app/Contents/MacOS/Google Chrome Helper (Aperitif)"),
            6: usage(6, "cupsd", path: "/usr/sbin/cupsd", uid: 0, owner: "root"),
        ]
        let bindings = PortList.bindings(
            from: [SocketEntry(pid: 5, proto: .udp, address: "*", port: 5353), SocketEntry(pid: 6, proto: .tcp, address: "127.0.0.1", port: 631)],
            processes: processes
        )
        #expect(bindings[0].displayLabel(currentUser: "me") == ProcessDisplayLabel(title: "cupsd", detail: "root"))
        #expect(bindings[1].displayLabel(currentUser: "me") == ProcessDisplayLabel(title: "Google Chrome", detail: "Aperitif helper"))
    }
}

@Suite struct CompactBytesTests {
    @Test func usesAtMostOneDecimal() {
        #expect(UsageFormat.compactBytes(512 << 10) == "512 KB")
        #expect(UsageFormat.compactBytes(144_700_000) == "138 MB")
        #expect(UsageFormat.compactBytes(UInt64(42.7 * Double(1 << 30))) == "42.7 GB")
        #expect(UsageFormat.compactBytes(64 << 30) == "64.0 GB")
    }
}

@Suite struct PortReachTests {
    let bindings = PortList.bindings(
        from: [
            SocketEntry(pid: 10, proto: .tcp, address: "127.0.0.1", port: 5173),
            SocketEntry(pid: 10, proto: .tcp, address: "*", port: 3000),
            SocketEntry(pid: 11, proto: .udp, address: "192.168.1.5", port: 5353),
        ],
        processes: [:]
    )

    @Test func networkMeansAnyNonLoopbackAddress() {
        #expect(bindings.filter(\.isNetworkReachable).map(\.port) == [3000, 5353])
    }

    @Test func filtersByReach() {
        #expect(PortList.filtered(bindings, reach: .all).map(\.port) == [3000, 5173, 5353])
        #expect(PortList.filtered(bindings, reach: .network).map(\.port) == [3000, 5353])
        #expect(PortList.filtered(bindings, reach: .local).map(\.port) == [5173])
    }
}

@Suite struct NewNetworkPortsTests {
    private func bindings(_ entries: [(pid_t, PortProtocol, String, UInt16)]) -> [PortBinding] {
        PortList.bindings(from: entries.map { SocketEntry(pid: $0.0, proto: $0.1, address: $0.2, port: $0.3) }, processes: [:])
    }

    @Test func theFirstScanIsTheBaseline() {
        var watch = NewNetworkPorts()
        watch.update(with: bindings([(1, .tcp, "*", 22)]))
        #expect(watch.unseen.isEmpty)
    }

    @Test func reportsPortsThatStartListeningOnTheNetwork() {
        var watch = NewNetworkPorts()
        watch.update(with: bindings([(1, .tcp, "*", 22)]))
        watch.update(with: bindings([(1, .tcp, "*", 22), (2, .tcp, "*", 8080), (3, .tcp, "127.0.0.1", 5173)]))
        #expect(watch.unseen.map(\.port) == [8080])

        // Still open: reported once, not duplicated.
        watch.update(with: bindings([(1, .tcp, "*", 22), (2, .tcp, "*", 8080)]))
        #expect(watch.unseen.map(\.port) == [8080])
    }

    @Test func forgetsPortsThatCloseAndClearsOnAcknowledge() {
        var watch = NewNetworkPorts()
        watch.update(with: [])
        watch.update(with: bindings([(2, .tcp, "*", 8080), (4, .udp, "*", 9000)]))
        watch.update(with: bindings([(4, .udp, "*", 9000)]))
        #expect(watch.unseen.map(\.port) == [9000])

        watch.acknowledge()
        #expect(watch.unseen.isEmpty)
        watch.update(with: bindings([(4, .udp, "*", 9000)]))
        #expect(watch.unseen.isEmpty)
    }
}

@Suite struct PreferencesStoreTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "dobby.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    @Test func defaults() {
        withDefaults { defaults in
            let store = PreferencesStore(defaults: defaults)
            #expect(store.menuBarItems == .all)
            #expect(store.flagsNewNetworkPorts == false)
            #expect(store.refreshInterval == .twoSeconds)
        }
    }

    @Test func persistsChoices() {
        withDefaults { defaults in
            let store = PreferencesStore(defaults: defaults)
            store.menuBarItems = [.cpu, .ports]
            store.flagsNewNetworkPorts = true
            store.refreshInterval = .fiveSeconds
            let reread = PreferencesStore(defaults: defaults)
            #expect(reread.menuBarItems == [.cpu, .ports])
            #expect(reread.flagsNewNetworkPorts)
            #expect(reread.refreshInterval == .fiveSeconds)
        }
    }

    @Test func refreshIntervalsAreOneTwoOrFiveSeconds() {
        #expect(RefreshInterval.allCases.map(\.seconds) == [1, 2, 5])
        withDefaults { defaults in
            defaults.set(7, forKey: PreferencesStore.refreshIntervalKey)
            #expect(PreferencesStore(defaults: defaults).refreshInterval == .twoSeconds)
        }
    }
}

@Suite struct MenuBarAlertTests {
    private func memory(pressure: MemoryPressure) -> MemoryStats {
        MemoryStats(usedBytes: 56 << 30, totalBytes: 64 << 30, appBytes: 0, wiredBytes: 0, compressedBytes: 0, pressure: pressure)
    }

    @Test func flagsMemoryPressureAndNewNetworkPorts() {
        let calm = MenuBarSummary(cpu: 0.1, memory: memory(pressure: .normal), portCount: 3)
        #expect(!calm.isMemoryUnderPressure)
        #expect(calm.newNetworkPorts.isEmpty)

        let alert = MenuBarSummary(cpu: 0.1, memory: memory(pressure: .warning), portCount: 4, newNetworkPorts: ["python3 :8080"])
        #expect(alert.isMemoryUnderPressure)
        #expect(alert.description == "CPU 10% · Memory 88% (56.00 GB of 64.00 GB, pressure high) · 4 ports, new on the network: python3 :8080")
    }
}
