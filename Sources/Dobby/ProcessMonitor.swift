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
        case cpu, memory, ports, network
    }

    /// Whether the root helper is supplying every user's processes.
    enum SystemAccess: Equatable {
        case off, explaining, requesting, on
    }

    enum NetworkState: Equatable {
        case idle, loading, ready, failed(String)
    }

    var tab: Tab = .cpu {
        didSet {
            guard tab != oldValue else { return }
            selection = nil
            portSelection = nil
            hoveredRowID = nil
            rebuildRows(keepOrder: false)
            if tab == .ports { acknowledgeNewNetworkPorts() }
            updateNetworkSampling()
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
            invalidateProcessSample()
            updateNetworkSampling()
            if isShowingSettings {
                confirmingForceQuit = nil
                hoveredRowID = nil
                dismissSystemAccessExplanation()
                isPointerInList = false
            } else if shouldSampleProcesses {
                // Process sampling pauses behind the settings view; catch up right away.
                Task { await sample(publish: true) }
            }
        }
    }
    /// "All users" was chosen; the explanation shows before the password prompt.
    var isExplainingSystemAccess: Bool { systemAccess == .explaining }
    var metric: Metric {
        switch tab {
        case .cpu, .ports: .cpu
        case .memory: .memory
        case .network: .network
        }
    }
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
    var selection: ProcessIdentity? {
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
    private(set) var network: NetworkRate?
    private(set) var networkHistory: [NetworkRate] = []
    private(set) var networkState: NetworkState = .idle
    var hasSampledNetwork: Bool { networkState == .ready }
    var networkError: String? {
        if case .failed(let message) = networkState { message } else { nil }
    }
    /// Latest whole-system CPU split, plus history for the graphs (oldest first).
    private(set) var cpuLoad: CPULoad?
    private(set) var cpuHistory: [CPULoad] = []
    private(set) var memory: MemoryStats?
    private(set) var memoryHistory: [Double] = []
    var systemCPU: Double? { cpuLoad?.total }
    private(set) var notice: Notice?
    private(set) var confirmingForceQuit: ProcessIdentity? {
        didSet {
            forceQuitTask?.cancel()
            forceQuitTask = nil
        }
    }
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

    @ObservationIgnored private let sampleProcesses: () -> [ProcessSnapshot]
    @ObservationIgnored private let scanSockets: () -> [SocketEntry]
    @ObservationIgnored private var processSampleID: UUID?
    @ObservationIgnored private var samplingGeneration = UUID()
    @ObservationIgnored private var backgroundPortTask: Task<Void, Never>?
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
    @ObservationIgnored private var lastInterfaces: [UInt16: NetworkCounters]?
    @ObservationIgnored private var lastNetworkTime: UInt64 = 0
    @ObservationIgnored private var latestNetwork: NetworkRate?
    @ObservationIgnored private var networkSamples = RingHistory<NetworkRate>(capacity: 90)
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored private var systemAccessTask: Task<Void, Never>?
    @ObservationIgnored private var forceQuitTask: Task<Void, Never>?
    @ObservationIgnored private let sampleNetwork: (Int) async throws -> [pid_t: NetworkRate]
    @ObservationIgnored private let connectHelper: () async throws -> HelperClient?
    @ObservationIgnored private var networkRates: [ProcessIdentity: NetworkRate] = [:]
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
    private var shouldSampleProcesses: Bool { isVisible && !isShowingSettings }

    /// How much time the history graphs cover.
    var historySpan: String {
        let seconds = 90 * preferences.refreshInterval.seconds
        return seconds % 60 == 0 ? "\(seconds / 60) min" : String(format: "%.1f min", Double(seconds) / 60)
    }

    /// The process the quit shortcuts and the action bar act on, from whichever tab is showing.
    var selectedTarget: (identity: ProcessIdentity, name: String, icon: NSImage)? {
        if tab == .ports {
            guard let row = portRows.first(where: { $0.id == portSelection }), let identity = row.identity else { return nil }
            return (identity, row.name, icon(forAppBundle: row.appBundlePath))
        }
        return rows.first { $0.identity == selection }.map { ($0.identity, $0.name, icon(forAppBundle: $0.appBundlePath)) }
    }

    // MARK: Sampling

    init(
        sampleProcesses: @escaping () -> [ProcessSnapshot] = ProcessSampler().snapshot,
        scanSockets: @escaping () -> [SocketEntry] = PortScanner().scan,
        sampleNetwork: @escaping (Int) async throws -> [pid_t: NetworkRate] = { try await NetworkProcessSampler.sample(seconds: $0) },
        connectHelper: @escaping () async throws -> HelperClient? = ProcessMonitor.connectSystemHelper
    ) {
        self.sampleProcesses = sampleProcesses
        self.scanSockets = scanSockets
        self.sampleNetwork = sampleNetwork
        self.connectHelper = connectHelper
        // System totals use cheap host and interface counters, sampled all the time,
        // so the graphs already have history when the panel opens. Process sampling stays panel-only.
        Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.interval else { return }
                self?.sampleSystem()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func sampleSystem() {
        let ticks = SystemStats.cpuTicks()
        if let lastTicks, let ticks {
            cpuSamples.append(SystemStats.cpuLoad(from: lastTicks, to: ticks))
        }
        lastTicks = ticks
        let now = DispatchTime.now().uptimeNanoseconds
        let interfaces = NetworkStats.interfaces()
        if let previous = lastInterfaces, let interfaces {
            latestNetwork = NetworkStats.rate(previous: previous, current: interfaces, seconds: Double(now - lastNetworkTime) / 1e9)
            if let latestNetwork { networkSamples.append(latestNetwork) }
        } else {
            latestNetwork = nil
        }
        lastInterfaces = interfaces
        lastNetworkTime = now
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
        if !shouldSampleProcesses, countsPortsInBackground, backgroundPortTask == nil {
            updateBackgroundPorts()
        }
        let summary = MenuBarSummary(
            cpu: cpuSamples.values.last?.total,
            memory: latestMemory,
            portCount: portCount,
            newNetworkPorts: flagsNewNetworkPorts ? newNetworkPorts.unseen.map(Self.portLabel) : [],
            network: latestNetwork
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

    private func invalidateProcessSample() {
        samplingGeneration = UUID()
        processSampleID = nil
    }

    private func helperDisconnected() {
        disableSystemAccess(resample: false)
        show("System process helper disconnected; showing only your processes", isError: true)
    }

    private func updateBackgroundPorts() {
        let client = helper
        let generation = samplingGeneration
        backgroundPortTask = Task { [weak self] in
            guard let self else { return }
            defer { self.backgroundPortTask = nil }
            let sockets: [SocketEntry]
            do {
                if let client {
                    sockets = try await client.snapshot().sockets
                } else {
                    sockets = self.scanSockets()
                }
                guard !Task.isCancelled, generation == self.samplingGeneration, self.helper === client,
                      !self.shouldSampleProcesses, self.countsPortsInBackground else { return }
            } catch {
                guard !Task.isCancelled, generation == self.samplingGeneration, self.helper === client,
                      !self.shouldSampleProcesses, self.countsPortsInBackground else { return }
                self.helperDisconnected()
                sockets = self.scanSockets()
            }
            let bindings = PortList.bindings(from: sockets, processes: [:])
            self.portCount = bindings.count
            if self.flagsNewNetworkPorts { self.newNetworkPorts.update(with: bindings) }
            self.refreshMenuBarSummary()
        }
    }

    private func publishSystem() {
        cpuHistory = cpuSamples.values
        cpuLoad = cpuSamples.values.last
        memoryHistory = memorySamples.values
        memory = latestMemory
        network = latestNetwork
        networkHistory = networkSamples.values
    }

    func setVisible(_ visible: Bool) {
        visible ? start() : stop()
    }

    func start() {
        guard refreshTask == nil else { return }
        isVisible = true
        updateNetworkSampling()
        publishSystem()
        refreshTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            // A fresh baseline first, so CPU reflects "now" rather than the time since the panel was last open.
            if self?.shouldSampleProcesses == true {
                await self?.sample(publish: self?.usages.isEmpty ?? true)
            }
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                if self?.shouldSampleProcesses == true { await self?.sample(publish: true) }
                try? await Task.sleep(for: self?.interval ?? .seconds(2))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        isVisible = false
        updateNetworkSampling()
        lastSampleTime = 0
        invalidateProcessSample()
        confirmingForceQuit = nil
        isPointerInList = false
        hoveredRowID = nil
    }

    func sample(publish: Bool) async {
        guard shouldSampleProcesses, processSampleID == nil else { return }
        let sampleID = UUID()
        processSampleID = sampleID
        defer { if processSampleID == sampleID { processSampleID = nil } }
        let generation = samplingGeneration
        var snapshots: [ProcessSnapshot]
        var helperSockets: [SocketEntry]?
        if let helper {
            do {
                let snapshot = try await helper.snapshot()
                guard !Task.isCancelled, generation == samplingGeneration, self.helper === helper, shouldSampleProcesses else { return }
                snapshots = snapshot.processes
                helperSockets = snapshot.sockets
            } catch {
                guard !Task.isCancelled, generation == samplingGeneration, self.helper === helper, shouldSampleProcesses else { return }
                helperDisconnected()
                snapshots = sampleProcesses()
            }
        } else {
            snapshots = sampleProcesses()
        }
        let now = DispatchTime.now().uptimeNanoseconds
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
            fresh[index].network = networkRates[fresh[index].identity]
        }

        usages = fresh
        protectedPIDs = Set(fresh.lazy.filter { SystemProcesses.isCritical(pid: $0.pid, executableName: $0.executableName) }.map(\.pid))
        rebuildRows(keepOrder: isPointerInList)

        let processes = Dictionary(fresh.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        allPorts = PortList.bindings(from: helperSockets ?? scanSockets(), processes: processes)
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
        let items = tab == .network ? usages.filter { $0.network != nil } : usages
        var ranked = ProcessRanking.ranked(items, by: metric, query: query)
        if keepOrder {
            ranked = ProcessRanking.applyingFrozenOrder(ranked, previousOrder: rows.map(\.identity))
        }
        rows = ranked
        barScale = ProcessRanking.barScale(for: ranked, metric: metric)
        processCount = items.count
        if let selection, !ranked.contains(where: { $0.identity == selection }) {
            self.selection = nil
        }
    }

    // MARK: Network traffic

    @discardableResult
    func updateNetworkSampling() -> Task<Void, Never>? {
        guard shouldSampleProcesses, tab == .network else {
            networkTask?.cancel()
            networkTask = nil
            networkState = .idle
            return nil
        }
        if let networkTask { return networkTask }
        networkRates = [:]
        networkState = .loading
        for index in usages.indices { usages[index].network = nil }
        rebuildRows(keepOrder: false)
        networkTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let baseline = self.usages.isEmpty
                        ? self.sampleProcesses().map { ($0.pid, $0.identity) }
                        : self.usages.map { ($0.pid, $0.identity) }
                    let identities = Dictionary(baseline, uniquingKeysWith: { _, last in last })
                    let rates = try await self.sampleNetwork(self.preferences.refreshInterval.seconds)
                    try Task.checkCancellation()
                    self.networkRates = Dictionary(rates.compactMap { pid, rate in
                        guard let identity = identities[pid], (try? ProcessIdentity.current(pid: pid)) == identity else { return nil }
                        return (identity, rate)
                    }, uniquingKeysWith: { _, last in last })
                    self.networkState = .ready
                    for index in self.usages.indices { self.usages[index].network = self.networkRates[self.usages[index].identity] }
                    self.rebuildRows(keepOrder: self.isPointerInList)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self.networkState = .failed("Couldn't read process traffic. Try again.")
                    self.networkRates = [:]
                    for index in self.usages.indices { self.usages[index].network = nil }
                    self.rebuildRows(keepOrder: false)
                    self.networkTask = nil
                    return
                }
            }
        }
        return networkTask
    }

    // MARK: Selection

    func moveSelection(by offset: Int) {
        if tab == .ports {
            portSelection = Self.moved(portSelection, by: offset, in: portRows.map(\.id))
        } else {
            selection = Self.moved(selection, by: offset, in: rows.map(\.identity))
        }
    }

    private static func moved<ID: Equatable>(_ current: ID?, by offset: Int, in ids: [ID]) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return ids[offset > 0 ? 0 : ids.count - 1]
        }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }

    func toggleSelection(_ identity: ProcessIdentity) {
        selection = selection == identity ? nil : identity
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

    /// Esc backs out of settings, the explanation, force-quit confirmation, selection, then search.
    var canCancel: Bool {
        isShowingSettings || isExplainingSystemAccess || confirmingForceQuit != nil || hasSelection || !query.isEmpty
    }

    func cancel() {
        if isShowingSettings {
            isShowingSettings = false
        } else if isExplainingSystemAccess {
            dismissSystemAccessExplanation()
        } else if confirmingForceQuit != nil {
            confirmingForceQuit = nil
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

    @discardableResult
    func quit(identity: ProcessIdentity, name: String) -> Task<Void, Never> {
        perform(.quit, identity: identity, name: name)
    }

    /// First call arms the captured process generation; a second call force quits that same generation.
    @discardableResult
    func forceQuit(identity: ProcessIdentity, name: String, confirmed: Bool = false) -> Task<Void, Never>? {
        guard confirmed || confirmingForceQuit == identity else {
            confirmingForceQuit = identity
            forceQuitTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.confirmingForceQuit = nil
            }
            return nil
        }
        return perform(.forceQuit, identity: identity, name: name)
    }

    private func perform(_ mode: TerminationMode, identity: ProcessIdentity, name: String) -> Task<Void, Never> {
        confirmingForceQuit = nil
        let client = helper
        return Task {
            do {
                guard !protectedPIDs.contains(identity.pid), identity.pid > 1 else { throw TerminationError.protectedProcess }
                do {
                    try terminator.terminate(identity, mode: mode)
                } catch TerminationError.notPermitted {
                    guard let client else { throw TerminationError.notPermitted }
                    let code = await client.signal(identity, mode == .quit ? SIGTERM : SIGKILL)
                    if code == ECONNRESET, helper === client { disableSystemAccess(resample: false) }
                    try ProcessTerminator.checkSignalResult(code)
                }
                show(mode == .quit ? "Asked “\(name)” to quit" : "Force quit “\(name)”", isError: false)
            } catch let error as TerminationError {
                show(message(for: error, name: name), isError: true)
            } catch {
                show("Couldn't end “\(name)”", isError: true)
            }
            try? await Task.sleep(for: .milliseconds(600))
            if shouldSampleProcesses { await sample(publish: true) }
        }
    }

    private func message(for error: TerminationError, name: String) -> String {
        switch error {
        case .protectedProcess: return "“\(name)” is protected and can't be ended here"
        case .notPermitted:
            return systemAccess == .on ? "No permission to end “\(name)”" : "No permission to end “\(name)”; switch to All users and try again"
        case .noSuchProcess: return "“\(name)” has already exited"
        case .failed(let code):
            if code == ENOTSUP { return "Safe process signals require macOS 15 or later. Apps can still quit normally." }
            if code == ECONNRESET { return "Lost the helper connection while ending “\(name)”. Check the list before trying again." }
            return "Couldn't end “\(name)” (\(String(cString: strerror(code))))"
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
        ProcessTerminator(requestAppQuit: { identity in
            MainActor.assumeIsolated {
                guard let app = NSRunningApplication(processIdentifier: identity.pid), app.bundleURL != nil,
                      (try? identity.validate()) != nil else { return false }
                return app.terminate()
            }
        })
    }

    // MARK: System access

    /// "All users": explain first; the password prompt comes from `confirmAllUsers()`.
    func requestAllUsers() {
        if systemAccess == .off { systemAccess = .explaining }
    }

    func dismissSystemAccessExplanation() {
        if systemAccess == .explaining { systemAccess = .off }
    }

    @discardableResult
    func confirmAllUsers() -> Task<Void, Never>? {
        guard systemAccess == .explaining else { return nil }
        systemAccess = .requesting
        let task = Task { await enableSystemAccess() }
        systemAccessTask = task
        return task
    }

    /// "Mine": cancels startup or stops the running root helper.
    func showMineOnly() {
        systemAccessTask?.cancel()
        systemAccessTask = nil
        if systemAccess == .on {
            disableSystemAccess()
        } else {
            systemAccess = .off
        }
    }

    private func enableSystemAccess() async {
        guard !Task.isCancelled else { return }
        do {
            let client = try await connectHelper()
            guard !Task.isCancelled else {
                client?.close()
                return
            }
            systemAccessTask = nil
            guard let client else {
                systemAccess = .off
                return
            }
            helper = client
            invalidateProcessSample()
            systemAccess = .on
            show("Showing processes of all users", isError: false)
            if shouldSampleProcesses { await sample(publish: true) }
        } catch {
            guard !Task.isCancelled else { return }
            systemAccessTask = nil
            systemAccess = .off
            let message = switch error {
            case SystemAccessError.helperMissing: "DobbyHelper not found; rebuild the app with scripts/build-app.sh"
            case SystemAccessError.authorizationFailed: "Couldn't get administrator privileges"
            default: "System process helper failed to start"
            }
            show(message, isError: true)
        }
    }

    private enum SystemAccessError: Error { case helperMissing, authorizationFailed }

    private static func connectSystemHelper() async throws -> HelperClient? {
        let helperURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("DobbyHelper")
        guard let helperURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw SystemAccessError.helperMissing
        }
        let client = try HelperClient()
        let script = HelperLaunchScript.make(helperPath: helperURL.path, socketPath: client.socketPath, clientIdentity: try ProcessIdentity.current(pid: getpid()))
        let result = await runAppleScript(script)
        try Task.checkCancellation()
        guard result.status == 0 else {
            // -128: the user cancelled the password prompt.
            if result.error.contains("-128") { return nil }
            throw SystemAccessError.authorizationFailed
        }
        try await Task.detached { try client.acceptHelper(timeout: 10) }.value
        return client
    }

    private func disableSystemAccess(resample: Bool = true) {
        helper?.close() // the helper exits when the connection closes
        helper = nil
        invalidateProcessSample()
        systemAccess = .off
        if resample, shouldSampleProcesses { Task { await sample(publish: true) } }
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
