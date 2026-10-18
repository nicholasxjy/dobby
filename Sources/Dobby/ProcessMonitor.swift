import AppKit
import DobbyCore
import Observation

/// Samples processes while the panel is visible and exposes ranked rows plus system totals.
@MainActor
@Observable
final class ProcessMonitor {
    struct Notice: Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    enum Tab: Hashable {
        case cpu, memory, ports
    }

    /// Whether the root helper is supplying every user's processes.
    enum SystemAccess: Equatable {
        case off, requesting, on
    }

    var tab: Tab = .cpu {
        didSet {
            guard tab != oldValue else { return }
            selection = nil
            portSelection = nil
            hoveredRowID = nil
            rebuildRows(keepOrder: false)
            if tab == .ports { acknowledgeNewNetworkPorts() }
        }
    }
    /// The Ports tab's All / LAN / Local filter.
    var portReach: PortReach = .all {
        didSet { if portReach != oldValue { rebuildPorts() } }
    }
    /// The settings view replaces the list while open.
    var isShowingSettings = false {
        didSet {
            guard isShowingSettings != oldValue else { return }
            if isShowingSettings {
                hoveredRowID = nil
                isExplainingSystemAccess = false
                isPointerInList = false
            } else if refreshTask != nil {
                // Process sampling pauses behind the settings view; catch up right away.
                sample(publish: true)
            }
        }
    }
    /// "All users" was chosen; the explanation shows before the password prompt.
    var isExplainingSystemAccess = false
    var metric: Metric { tab == .memory ? .memory : .cpu }
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            rebuildRows(keepOrder: false)
            rebuildPorts()
        }
    }
    /// While the pointer is over the list, rows keep their positions so clicks don't land on the wrong process.
    var isPointerInList = false {
        didSet { if oldValue && !isPointerInList { rebuildRows(keepOrder: false) } }
    }
    /// Row under the pointer: a PID on process tabs, a `PortBinding.ID` on the ports tab.
    var hoveredRowID: AnyHashable?
    var selection: pid_t? {
        didSet { if selection != oldValue { confirmingForceQuit = nil } }
    }
    var portSelection: PortBinding.ID? {
        didSet { if portSelection != oldValue { confirmingForceQuit = nil } }
    }

    private(set) var rows: [ProcessUsage] = []
    private(set) var barScale: Double = 1
    private(set) var processCount = 0
    private(set) var portRows: [PortBinding] = []
    private(set) var allPorts: [PortBinding] = []
    /// Ports matching the search, split by reach, for the filter chips.
    private(set) var portCounts = PortCounts()
    private(set) var hasSampled = false
    /// Latest whole-system CPU split, plus history for the graphs (oldest first).
    private(set) var cpuLoad: CPULoad?
    private(set) var cpuHistory: [CPULoad] = []
    private(set) var memory: MemoryStats?
    private(set) var memoryHistory: [Double] = []
    var systemCPU: Double? { cpuLoad?.total }
    private(set) var notice: Notice?
    private(set) var confirmingForceQuit: pid_t?
    private(set) var systemAccess: SystemAccess = .off
    /// Processes Dobby refuses to end (launchd, WindowServer, ...).
    private(set) var protectedPIDs: Set<pid_t> = []
    /// Latest totals for the menu bar readout, refreshed every system sample while `showsMenuBarStats` is on.
    private(set) var menuBarSummary = MenuBarSummary(cpu: nil, memory: nil, portCount: nil)
    var showsMenuBarStats = false {
        didSet { if showsMenuBarStats && !oldValue { refreshMenuBarSummary() } }
    }
    /// The readout shows the port count, so scan ports while the panel is closed too.
    var countsPortsInBackground = false
    /// Report ports that start listening on the network in the menu bar readout.
    var flagsNewNetworkPorts = false {
        didSet {
            guard flagsNewNetworkPorts != oldValue else { return }
            newNetworkPorts = NewNetworkPorts()
            if showsMenuBarStats { refreshMenuBarSummary() }
        }
    }

    @ObservationIgnored private let sampler = ProcessSampler()
    @ObservationIgnored private let portScanner = PortScanner()
    @ObservationIgnored private var helper: HelperClient?
    @ObservationIgnored private var userNames: [uid_t: String] = [:]
    @ObservationIgnored private var usages: [ProcessUsage] = []
    @ObservationIgnored private var lastSnapshots: [ProcessSnapshot] = []
    @ObservationIgnored private var lastSampleTime: UInt64 = 0
    @ObservationIgnored private var lastTicks: CPUTicks?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var cpuSamples = RingHistory<CPULoad>(capacity: 90)
    @ObservationIgnored private var memorySamples = RingHistory<Double>(capacity: 90)
    @ObservationIgnored private var latestMemory: MemoryStats?
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    /// Same count as the Ports tab total; scanned in the background only for the menu bar readout.
    @ObservationIgnored private var portCount: Int?
    @ObservationIgnored private var newNetworkPorts = NewNetworkPorts()
    @ObservationIgnored private let preferences = PreferencesSettings.shared

    struct PortCounts: Equatable {
        var tcp = 0
        var udp = 0
        var network = 0
        var local = 0
        var all: Int { network + local }
    }

    private var interval: Duration { .seconds(preferences.refreshInterval.seconds) }

    /// How much time the history graphs cover.
    var historySpan: String {
        let seconds = 90 * preferences.refreshInterval.seconds
        return seconds % 60 == 0 ? "\(seconds / 60) min" : String(format: "%.1f min", Double(seconds) / 60)
    }

    /// The process the quit shortcuts and the action bar act on, from whichever tab is showing.
    var selectedTarget: (pid: pid_t, name: String, icon: NSImage)? {
        if tab == .ports {
            return portRows.first { $0.id == portSelection }.map { ($0.pid, $0.name, icon(forAppBundle: $0.appBundlePath)) }
        }
        return rows.first { $0.pid == selection }.map { ($0.pid, $0.name, icon(forAppBundle: $0.appBundlePath)) }
    }

    // MARK: Sampling

    init() {
        // System totals are a couple of host_statistics calls: cheap enough to sample all the time,
        // so the graphs already have history when the panel opens. Process sampling stays panel-only.
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sampleSystem()
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    private func sampleSystem() {
        let ticks = SystemStats.cpuTicks()
        if let lastTicks, let ticks {
            cpuSamples.append(SystemStats.cpuLoad(from: lastTicks, to: ticks))
        }
        lastTicks = ticks
        latestMemory = SystemStats.memory()
        if let latestMemory {
            memorySamples.append(Double(latestMemory.usedBytes) / Double(max(latestMemory.totalBytes, 1)))
        }
        // Hidden panels don't need view updates.
        if isVisible { publishSystem() }
        if showsMenuBarStats { refreshMenuBarSummary() }
    }

    private func refreshMenuBarSummary() {
        // While the panel is open, process sampling keeps the count current.
        if !isVisible, countsPortsInBackground, let bindings = scanPorts() {
            portCount = bindings.count
            if flagsNewNetworkPorts { newNetworkPorts.update(with: bindings) }
        }
        let summary = MenuBarSummary(
            cpu: cpuSamples.values.last?.total,
            memory: latestMemory,
            portCount: portCount,
            newNetworkPorts: flagsNewNetworkPorts ? newNetworkPorts.unseen.map(Self.portLabel) : []
        )
        // Unchanged numbers shouldn't redraw the status item.
        if summary != menuBarSummary { menuBarSummary = summary }
    }

    /// "python3 :8080"; background scans don't carry process names, so look the name up.
    private static func portLabel(_ binding: PortBinding) -> String {
        let name = binding.name.hasPrefix("PID ") ? ProcessSampler.name(of: binding.pid) : binding.name
        return "\(name) :\(binding.port)"
    }

    /// Seen while the Ports tab is open, so the menu bar stops flagging them.
    private func acknowledgeNewNetworkPorts() {
        guard !newNetworkPorts.unseen.isEmpty else { return }
        newNetworkPorts.acknowledge()
        if showsMenuBarStats { refreshMenuBarSummary() }
    }

    /// A few milliseconds of libproc calls. With the root helper on, covers every user's ports like the Ports tab.
    private func scanPorts() -> [PortBinding]? {
        let sockets: [SocketEntry]
        if let helper {
            // A failing helper is reported and turned off by the next panel sample; keep the last count until then.
            guard let snapshot = try? helper.snapshot() else { return nil }
            sockets = snapshot.sockets
        } else {
            sockets = portScanner.scan()
        }
        return PortList.bindings(from: sockets, processes: [:])
    }

    private func publishSystem() {
        cpuHistory = cpuSamples.values
        cpuLoad = cpuSamples.values.last
        memoryHistory = memorySamples.values
        memory = latestMemory
    }

    func setVisible(_ visible: Bool) {
        visible ? start() : stop()
    }

    func start() {
        guard refreshTask == nil else { return }
        isVisible = true
        publishSystem()
        refreshTask = Task { [weak self] in
            // A fresh baseline first, so CPU reflects "now" rather than the time since the panel was last open.
            self?.sample(publish: self?.usages.isEmpty ?? true)
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                if self?.isShowingSettings == false { self?.sample(publish: true) }
                try? await Task.sleep(for: self?.interval ?? .seconds(2))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        isVisible = false
        lastSampleTime = 0
        isPointerInList = false
        hoveredRowID = nil
    }

    private func sample(publish: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        var snapshots: [ProcessSnapshot]
        var helperSockets: [SocketEntry]?
        if let helper {
            do {
                let snapshot = try helper.snapshot()
                snapshots = snapshot.processes
                helperSockets = snapshot.sockets
            } catch {
                disableSystemAccess(resample: false)
                show("System process helper disconnected; showing only your processes", isError: true)
                snapshots = sampler.snapshot()
            }
        } else {
            snapshots = sampler.snapshot()
        }
        let elapsed = lastSampleTime == 0 ? 0 : now - lastSampleTime
        var fresh = UsageCalculator.usages(previous: lastSnapshots, current: snapshots, elapsedNanos: elapsed)
        lastSnapshots = snapshots
        lastSampleTime = now
        guard publish else { return }

        // Prefer the user-facing app name ("Visual Studio Code" over "Electron").
        let appNames = Dictionary(
            NSWorkspace.shared.runningApplications.compactMap { app in app.localizedName.map { (app.processIdentifier, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        for index in fresh.indices {
            if let name = appNames[fresh[index].pid] { fresh[index].name = name }
            fresh[index].ownerName = userName(fresh[index].uid)
        }

        usages = fresh
        protectedPIDs = Set(fresh.lazy.filter { SystemProcesses.isCritical(pid: $0.pid, executableName: $0.executableName) }.map(\.pid))
        rebuildRows(keepOrder: isPointerInList)

        let processes = Dictionary(fresh.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        allPorts = PortList.bindings(from: helperSockets ?? portScanner.scan(), processes: processes)
        portCount = allPorts.count
        if flagsNewNetworkPorts {
            newNetworkPorts.update(with: allPorts)
            if tab == .ports { newNetworkPorts.acknowledge() }
        }
        rebuildPorts()
        hasSampled = true
    }

    private func userName(_ uid: uid_t) -> String? {
        guard uid != uid_t.max else { return nil }
        if let cached = userNames[uid] { return cached }
        let name = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
        userNames[uid] = name
        return name
    }

    private func rebuildPorts() {
        let matching = PortList.filtered(allPorts, query: query)
        var counts = PortCounts()
        for binding in matching {
            if binding.proto == .tcp { counts.tcp += 1 } else { counts.udp += 1 }
            if binding.isNetworkReachable { counts.network += 1 } else { counts.local += 1 }
        }
        if counts != portCounts { portCounts = counts }
        portRows = PortList.filtered(matching, reach: portReach)
        if let portSelection, !portRows.contains(where: { $0.id == portSelection }) {
            self.portSelection = nil
        }
    }

    private func rebuildRows(keepOrder: Bool) {
        var ranked = ProcessRanking.ranked(usages, by: metric, query: query)
        if keepOrder {
            ranked = ProcessRanking.applyingFrozenOrder(ranked, previousOrder: rows.map(\.pid))
        }
        rows = ranked
        barScale = ProcessRanking.barScale(for: ranked, metric: metric)
        processCount = usages.count
        if let selection, !ranked.contains(where: { $0.pid == selection }) {
            self.selection = nil
        }
    }

    // MARK: Selection

    func moveSelection(by offset: Int) {
        if tab == .ports {
            portSelection = Self.moved(portSelection, by: offset, in: portRows.map(\.id))
        } else {
            selection = Self.moved(selection, by: offset, in: rows.map(\.pid))
        }
    }

    private static func moved<ID: Equatable>(_ current: ID?, by offset: Int, in ids: [ID]) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return ids[offset > 0 ? 0 : ids.count - 1]
        }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }

    func toggleSelection(_ pid: pid_t) {
        selection = selection == pid ? nil : pid
    }

    func togglePortSelection(_ id: PortBinding.ID) {
        portSelection = portSelection == id ? nil : id
    }

    func setHovered(_ id: AnyHashable, _ inside: Bool) {
        if inside {
            if hoveredRowID != id { hoveredRowID = id }
        } else if hoveredRowID == id {
            hoveredRowID = nil
        }
    }

    var hasSelection: Bool { selectedTarget != nil }

    /// What Esc undoes first: the settings view, the All users explanation, the selection, then the search.
    var canCancel: Bool {
        isShowingSettings || isExplainingSystemAccess || hasSelection || !query.isEmpty
    }

    func cancel() {
        if isShowingSettings {
            isShowingSettings = false
        } else if isExplainingSystemAccess {
            isExplainingSystemAccess = false
        } else if selection != nil || portSelection != nil {
            selection = nil
            portSelection = nil
        } else {
            query = ""
        }
    }

    /// Ports a process holds, for the details card.
    func ports(heldBy pid: pid_t) -> [PortBinding] {
        allPorts.filter { $0.pid == pid }
    }

    // MARK: Termination

    func quit(pid: pid_t, name: String) {
        perform(.quit, pid: pid, name: name)
    }

    /// First call arms the button; a second call within a few seconds force quits.
    func forceQuit(pid: pid_t, name: String, confirmed: Bool = false) {
        guard confirmed || confirmingForceQuit == pid else {
            confirmingForceQuit = pid
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if self?.confirmingForceQuit == pid { self?.confirmingForceQuit = nil }
            }
            return
        }
        perform(.forceQuit, pid: pid, name: name)
    }

    private func perform(_ mode: TerminationMode, pid: pid_t, name: String) {
        confirmingForceQuit = nil
        guard !protectedPIDs.contains(pid), pid > 1 else {
            show("“\(name)” is a critical system process; ending it would freeze or log out the Mac", isError: true)
            return
        }
        do {
            try terminator.terminate(pid, mode: mode)
            show(mode == .quit ? "Asked “\(name)” to quit" : "Force quit “\(name)”", isError: false)
        } catch {
            show(message(for: error, name: name), isError: true)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.sample(publish: true)
        }
    }

    private func message(for error: TerminationError, name: String) -> String {
        switch error {
        case .protectedProcess: return "“\(name)” is protected and can't be ended here"
        case .notPermitted:
            return systemAccess == .on ? "No permission to end “\(name)”" : "No permission to end “\(name)”; switch to All users and try again"
        case .noSuchProcess: return "“\(name)” has already exited"
        case .failed(let code): return "Couldn't end “\(name)” (\(String(cString: strerror(code))))"
        }
    }

    func show(_ text: String, isError: Bool) {
        let notice = Notice(text: text, isError: isError)
        self.notice = notice
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.notice == notice { self?.notice = nil }
        }
    }

    private var terminator: ProcessTerminator {
        let helper = self.helper
        return ProcessTerminator(
            // Signal directly when allowed; otherwise relay through the root helper if it's running.
            sendSignal: { pid, signal in
                let code = kill(pid, signal) == 0 ? 0 : errno
                guard code == EPERM, let helper else { return code }
                return helper.signal(pid, signal)
            },
            requestAppQuit: { pid in
                MainActor.assumeIsolated {
                    guard let app = NSRunningApplication(processIdentifier: pid), app.bundleURL != nil else { return false }
                    return app.terminate()
                }
            }
        )
    }

    // MARK: System access

    /// "All users": explain first; the password prompt comes from `confirmAllUsers()`.
    func requestAllUsers() {
        if systemAccess == .off { isExplainingSystemAccess = true }
    }

    func confirmAllUsers() {
        isExplainingSystemAccess = false
        guard systemAccess == .off else { return }
        Task { await enableSystemAccess() }
    }

    /// "Mine": stops the root helper if it's running.
    func showMineOnly() {
        isExplainingSystemAccess = false
        if systemAccess == .on { disableSystemAccess() }
    }

    private func enableSystemAccess() async {
        systemAccess = .requesting
        let helperURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("DobbyHelper")
        guard let helperURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            systemAccess = .off
            show("DobbyHelper not found; rebuild the app with scripts/build-app.sh", isError: true)
            return
        }
        do {
            let client = try HelperClient()
            let script = HelperLaunchScript.make(helperPath: helperURL.path, socketPath: client.socketPath, clientPID: getpid())
            let result = await Self.runAppleScript(script)
            guard result.status == 0 else {
                systemAccess = .off
                // -128: the user cancelled the password prompt.
                if !result.error.contains("-128") { show("Couldn't get administrator privileges", isError: true) }
                return
            }
            try await Task.detached { try client.acceptHelper(timeout: 10) }.value
            helper = client
            systemAccess = .on
            show("Showing processes of all users", isError: false)
            sample(publish: true)
        } catch {
            systemAccess = .off
            show("System process helper failed to start", isError: true)
        }
    }

    private func disableSystemAccess(resample: Bool = true) {
        helper?.close() // the helper exits when the connection closes
        helper = nil
        systemAccess = .off
        if resample, refreshTask != nil { sample(publish: true) }
    }

    private nonisolated static func runAppleScript(_ source: String) async -> (status: Int32, error: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            process.terminationHandler = { process in
                let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: (process.terminationStatus, message))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }

    // MARK: Icons

    func icon(forAppBundle appBundlePath: String?) -> NSImage {
        let key = appBundlePath ?? "generic"
        if let cached = iconCache[key] { return cached }
        let image = appBundlePath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
        iconCache[key] = image
        return image
    }
}
