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
            rebuildRows(keepOrder: false)
        }
    }
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
                try? await Task.sleep(for: .seconds(2))
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
                self?.sample(publish: true)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        isVisible = false
        lastSampleTime = 0
        isPointerInList = false
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
                show("系统进程助手已断开，只显示当前用户的进程", isError: true)
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
        portRows = PortList.filtered(allPorts, query: query)
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

    func clearSelectionOrQuery() {
        if selection != nil || portSelection != nil {
            selection = nil
            portSelection = nil
        } else {
            query = ""
        }
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
            show("「\(name)」是系统关键进程，结束它会导致死机或注销", isError: true)
            return
        }
        do {
            try terminator.terminate(pid, mode: mode)
            show(mode == .quit ? "已请求退出「\(name)」" : "已强制退出「\(name)」", isError: false)
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
        case .protectedProcess: return "「\(name)」受保护，不能在这里结束"
        case .notPermitted:
            return systemAccess == .on ? "没有权限结束「\(name)」" : "没有权限结束「\(name)」，打开「含系统进程」后可重试"
        case .noSuchProcess: return "「\(name)」已经退出"
        case .failed(let code): return "结束「\(name)」失败（\(String(cString: strerror(code)))）"
        }
    }

    private func show(_ text: String, isError: Bool) {
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

    func toggleSystemAccess() {
        switch systemAccess {
        case .off: Task { await enableSystemAccess() }
        case .on: disableSystemAccess()
        case .requesting: break
        }
    }

    private func enableSystemAccess() async {
        systemAccess = .requesting
        let helperURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("DobbyHelper")
        guard let helperURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            systemAccess = .off
            show("找不到 DobbyHelper，请用 scripts/build-app.sh 重新打包", isError: true)
            return
        }
        do {
            let client = try HelperClient()
            let script = HelperLaunchScript.make(helperPath: helperURL.path, socketPath: client.socketPath, clientPID: getpid())
            let result = await Self.runAppleScript(script)
            guard result.status == 0 else {
                systemAccess = .off
                // -128: the user cancelled the password prompt.
                if !result.error.contains("-128") { show("无法获取管理员权限", isError: true) }
                return
            }
            try await Task.detached { try client.acceptHelper(timeout: 10) }.value
            helper = client
            systemAccess = .on
            show("已显示所有用户的进程", isError: false)
            sample(publish: true)
        } catch {
            systemAccess = .off
            show("系统进程助手启动失败", isError: true)
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
