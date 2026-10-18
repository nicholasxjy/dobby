import DobbyCore
import SwiftUI

/// The panel. Each section is its own view so SwiftUI's observation tracking re-renders only the
/// sections whose data changed (hovering a row doesn't redraw the tiles or the graph).
struct ContentView: View {
    @Bindable var monitor: ProcessMonitor
    @Bindable var theme: ThemeSettings
    @FocusState private var searchFocused: Bool
    private let launchAtLogin = LaunchAtLoginSettings.shared

    var body: some View {
        Group {
            if monitor.isShowingSettings {
                SettingsView(monitor: monitor, theme: theme)
            } else {
                VStack(spacing: 0) {
                    VitalTiles(monitor: monitor)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                    DetailSection(monitor: monitor)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    SearchToolbar(monitor: monitor, searchFocused: $searchFocused)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                    if monitor.isExplainingSystemAccess {
                        SystemAccessExplainer(monitor: monitor)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                    }
                    ListSection(monitor: monitor)
                    InspectorSection(monitor: monitor)
                    FooterBar(monitor: monitor)
                }
            }
        }
        .frame(width: 400, height: 640)
        .background(Palette.background)
        .clipShape(PanelChrome.shape)
        .overlay(PanelChrome.shape.strokeBorder(Palette.border))
        .background(WindowVisibilityReader { visible in
            monitor.setVisible(visible)
            if visible {
                searchFocused = true
                launchAtLogin.refresh()
            }
        })
        .modifier(KeyboardControls(monitor: monitor))
        .background(ShortcutButtons(monitor: monitor))
    }
}

private func percent(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
}

// MARK: - Tiles

private struct VitalTiles: View {
    let monitor: ProcessMonitor

    var body: some View {
        HStack(spacing: 6) {
            let load = monitor.cpuLoad
            VitalTile(
                title: "CPU",
                symbol: "cpu",
                value: load.map { percent($0.total) } ?? "—",
                detail: "\(SystemStats.coreCount) cores",
                segments: [.init(fraction: load?.user ?? 0, color: Palette.user), .init(fraction: load?.system ?? 0, color: Palette.system)],
                shortcut: "1",
                isSelected: monitor.tab == .cpu
            ) { monitor.tab = .cpu }

            let memory = monitor.memory
            VitalTile(
                title: "Memory",
                symbol: "memorychip",
                value: memory.map { UsageFormat.compactBytes($0.usedBytes) } ?? "—",
                detail: memory.map { "of \(wholeGigabytes($0.totalBytes)) · \(PressureStyle($0.pressure).label)" } ?? "—",
                detailColor: memory.map { $0.pressure == .normal ? Color.secondary : PressureStyle($0.pressure).color } ?? .secondary,
                segments: [.init(fraction: memory.map { Double($0.usedBytes) / Double(max($0.totalBytes, 1)) } ?? 0, color: PressureStyle(memory?.pressure).color)],
                shortcut: "2",
                isSelected: monitor.tab == .memory
            ) { monitor.tab = .memory }

            let ports = monitor.allPorts
            let network = ports.lazy.filter(\.isNetworkReachable).count
            let networkFraction = ports.isEmpty ? 0 : Double(network) / Double(ports.count)
            VitalTile(
                title: "Ports",
                symbol: "network",
                value: monitor.hasSampled ? String(ports.count) : "—",
                detail: "\(network) open to LAN",
                detailColor: network > 0 ? Palette.warning : .secondary,
                segments: ports.isEmpty ? [] : [.init(fraction: networkFraction, color: Palette.warningFill), .init(fraction: 1 - networkFraction, color: Palette.neutralBar)],
                shortcut: "3",
                isSelected: monitor.tab == .ports
            ) { monitor.tab = .ports }
        }
    }

    private func wholeGigabytes(_ bytes: UInt64) -> String {
        "\(Int((Double(bytes) / Double(1 << 30)).rounded())) GB"
    }
}

struct PressureStyle {
    let label: String
    let color: Color

    init(_ pressure: MemoryPressure?) {
        switch pressure {
        case .warning: (label, color) = ("High", Palette.warningFill)
        case .critical: (label, color) = ("Critical", Palette.critical)
        case .normal: (label, color) = ("Normal", Palette.memory)
        case nil: (label, color) = ("—", Palette.memory)
        }
    }
}

// MARK: - Graph or port filters

private struct DetailSection: View {
    let monitor: ProcessMonitor

    var body: some View {
        switch monitor.tab {
        case .cpu: cpu
        case .memory: memory
        case .ports: PortFilters(monitor: monitor)
        }
    }

    private var cpu: some View {
        let load = monitor.cpuLoad
        return GraphWithLegend(
            series: [
                .init(values: monitor.cpuHistory.map(\.user), color: Palette.user),
                .init(values: monitor.cpuHistory.map(\.system), color: Palette.system),
            ],
            scale: "100%",
            span: monitor.historySpan,
            legend: [
                LegendItem(label: "User", value: load.map { percent($0.user) } ?? "—", swatch: Palette.user),
                LegendItem(label: "System", value: load.map { percent($0.system) } ?? "—", swatch: Palette.system),
                LegendItem(label: "Idle", value: load.map { percent(1 - $0.total) } ?? "—"),
                LegendItem(label: "Cores", value: String(SystemStats.coreCount)),
            ]
        )
    }

    private var memory: some View {
        let stats = monitor.memory
        let pressure = PressureStyle(stats?.pressure)
        return GraphWithLegend(
            series: [.init(values: monitor.memoryHistory, color: pressure.color)],
            scale: stats.map { UsageFormat.compactBytes($0.totalBytes) } ?? "",
            span: monitor.historySpan,
            legend: [
                LegendItem(label: "App", value: stats.map { UsageFormat.compactBytes($0.appBytes) } ?? "—"),
                LegendItem(label: "Wired", value: stats.map { UsageFormat.compactBytes($0.wiredBytes) } ?? "—"),
                LegendItem(label: "Compressed", value: stats.map { UsageFormat.compactBytes($0.compressedBytes) } ?? "—"),
                LegendItem(label: "Pressure", value: pressure.label, valueColor: pressure.color),
            ]
        )
    }
}

private struct LegendItem: Hashable {
    let label: String
    let value: String
    var swatch: Color?
    var valueColor: Color = .primary
}

private struct GraphWithLegend: View {
    let series: [HistoryGraph.Series]
    let scale: String
    let span: String
    let legend: [LegendItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HistoryGraph(series: series, capacity: 90)
                .frame(height: 54)
                .overlay(alignment: .topTrailing) { caption(scale).padding(.top, 3).padding(.trailing, 6) }
                .overlay(alignment: .bottomLeading) { caption(span).padding(.bottom, 3).padding(.leading, 6) }
            HStack(spacing: 10) {
                ForEach(legend, id: \.label) { item in
                    HStack(spacing: 4) {
                        if let swatch = item.swatch {
                            RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 7, height: 7)
                        }
                        Text(item.label).foregroundStyle(.secondary)
                        Text(item.value)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(item.valueColor)
                    }
                }
            }
            .font(.system(size: 11))
            .lineLimit(1)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 9.5)).foregroundStyle(.tertiary)
    }
}

private struct PortFilters: View {
    let monitor: ProcessMonitor

    var body: some View {
        let counts = monitor.portCounts
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                chip(.all, "All", counts.all, dot: Color.secondary.opacity(0.6))
                chip(.network, "LAN", counts.network, dot: Palette.warningFill)
                chip(.local, "Local", counts.local, dot: Palette.neutralBar)
                Spacer(minLength: 4)
                Text("TCP \(counts.tcp) · UDP \(counts.udp)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            note
        }
    }

    private func chip(_ reach: PortReach, _ title: String, _ count: Int, dot: Color) -> some View {
        let isSelected = monitor.portReach == reach
        let isNetwork = reach == .network && isSelected
        return Button {
            monitor.portReach = reach
        } label: {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(title)
                Text(String(count)).fontWeight(.semibold).monospacedDigit()
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(isNetwork ? Palette.warning : isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(isNetwork ? Palette.warningSoft : isSelected ? Palette.surface : .clear))
            .overlay(Capsule().strokeBorder(isNetwork ? .clear : isSelected ? Palette.border : Palette.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var note: some View {
        let (text, isNetwork): (String, Bool) = switch monitor.portReach {
        case .network: ("These ports accept connections from other devices on your network. Closing one quits the process that holds it.", true)
        case .local: ("Only apps on this Mac can reach these ports.", false)
        case .all: ("Closing a port quits the process that holds it. LAN ports are reachable from other devices.", false)
        }
        return Label(text, systemImage: "info.circle")
            .font(.system(size: 11))
            .foregroundStyle(isNetwork ? Palette.warning : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(isNetwork ? Palette.warningSoft : Palette.fill))
    }
}

// MARK: - Search and scope

private struct SearchToolbar: View {
    @Bindable var monitor: ProcessMonitor
    var searchFocused: FocusState<Bool>.Binding

    private enum Scope: Hashable { case mine, all }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                TextField(monitor.tab == .ports ? "Search port, process or PID" : "Search name, app, user or PID", text: $monitor.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused(searchFocused)
                    .modifier(KeyboardControls(monitor: monitor))
                if !monitor.query.isEmpty {
                    Button {
                        monitor.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.border))

            PillSegments(
                options: [
                    .init(value: Scope.mine, title: "Mine"),
                    .init(value: Scope.all, title: "All users", symbol: "shield", isBusy: monitor.systemAccess == .requesting),
                ],
                selection: monitor.systemAccess != .off || monitor.isExplainingSystemAccess ? Scope.all : Scope.mine
            ) { scope in
                scope == .all ? monitor.requestAllUsers() : monitor.showMineOnly()
            }
            .fixedSize()
            .help("Mine: your processes. All users: root and other accounts too (asks for an admin password).")
        }
    }
}

private struct SystemAccessExplainer: View {
    let monitor: ProcessMonitor

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.accentSoft))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Show processes of all users?")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Lists and ends processes and ports owned by root and other accounts. Dobby starts a small helper with admin rights. It stops when you switch back to Mine or quit Dobby. Nothing is installed.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                Button("Not Now") { monitor.isExplainingSystemAccess = false }
                    .buttonStyle(FlatButtonStyle())
                Button {
                    monitor.confirmAllUsers()
                } label: {
                    Label("Continue…", systemImage: "lock.fill")
                }
                .buttonStyle(FlatButtonStyle(tint: .accentColor, prominent: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.surface)
        )
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
        .elevated(cornerRadius: 10)
    }
}

// MARK: - List

private struct ListSection: View {
    let monitor: ProcessMonitor

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if monitor.tab == .ports {
                            ForEach(monitor.portRows) { binding in
                                PortRow(
                                    binding: binding,
                                    icon: monitor.icon(forAppBundle: binding.appBundlePath),
                                    state: state(id: binding.id, pid: binding.pid, isSelected: monitor.portSelection == binding.id),
                                    monitor: monitor
                                )
                                .equatable()
                                .id(AnyHashable(binding.id))
                            }
                        } else {
                            ForEach(monitor.rows) { row in
                                ProcessRow(
                                    row: row,
                                    metric: monitor.metric,
                                    scale: monitor.barScale,
                                    icon: monitor.icon(forAppBundle: row.appBundlePath),
                                    state: state(id: row.pid, pid: row.pid, isSelected: monitor.selection == row.pid),
                                    monitor: monitor
                                )
                                .equatable()
                                .id(AnyHashable(row.pid))
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                }
                .overlay { emptyState }
                .onHover { monitor.isPointerInList = $0 }
                .onChange(of: monitor.selection) { _, selection in
                    scroll(proxy, to: selection.map { AnyHashable($0) })
                }
                .onChange(of: monitor.portSelection) { _, selection in
                    scroll(proxy, to: selection.map { AnyHashable($0) })
                }
            }
        }
    }

    @ViewBuilder private var header: some View {
        let isAdminOn = monitor.systemAccess == .on
        if monitor.tab == .ports {
            PortColumnHeader(isAdminOn: isAdminOn, isPaused: monitor.isPointerInList)
        } else {
            ProcessColumnHeader(
                title: monitor.query.isEmpty
                    ? "\(monitor.processCount.formatted()) processes"
                    : "\(monitor.rows.count) \(monitor.rows.count == 1 ? "match" : "matches")",
                isAdminOn: isAdminOn,
                isPaused: monitor.isPointerInList,
                metric: monitor.metric
            )
        }
    }

    private func state(id: AnyHashable, pid: pid_t, isSelected: Bool) -> RowState {
        RowState(isSelected: isSelected, isHovering: monitor.hoveredRowID == id, isProtected: monitor.protectedPIDs.contains(pid))
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: AnyHashable?) {
        guard let id, !monitor.isPointerInList else { return }
        proxy.scrollTo(id)
    }

    @ViewBuilder private var emptyState: some View {
        let isEmpty = monitor.tab == .ports ? monitor.portRows.isEmpty : monitor.rows.isEmpty
        if !isEmpty {
            EmptyView()
        } else if !monitor.hasSampled {
            ProgressView().controlSize(.small)
        } else if !monitor.query.isEmpty {
            VStack(spacing: 4) {
                Text("No results for “\(monitor.query)”")
                    .font(.system(size: 13, weight: .semibold))
                Text(monitor.tab == .ports ? "Try a port, process name or PID" : "Try a name, app, user or PID")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .multilineTextAlignment(.center)
        } else if monitor.tab == .ports {
            ContentUnavailableView(
                monitor.portReach == .all ? "No ports in use" : "No \(monitor.portReach == .network ? "LAN" : "local-only") ports",
                systemImage: "network.slash",
                description: Text(monitor.systemAccess == .on ? "No process is listening on a matching port" : "None of your processes is listening on a matching port")
            )
        }
    }
}

// MARK: - Details card

private struct InspectorSection: View {
    let monitor: ProcessMonitor

    var body: some View {
        if let model {
            InspectorCard(model: model, monitor: monitor)
        }
    }

    private var model: InspectorModel? {
        if monitor.tab == .ports {
            guard let id = monitor.portSelection, let binding = monitor.portRows.first(where: { $0.id == id }) else { return nil }
            return InspectorModel(
                port: binding,
                icon: monitor.icon(forAppBundle: binding.appBundlePath),
                otherPorts: monitor.ports(heldBy: binding.pid).filter { $0.id != binding.id },
                isProtected: monitor.protectedPIDs.contains(binding.pid),
                isConfirming: monitor.confirmingForceQuit == binding.pid
            )
        }
        guard let pid = monitor.selection, let row = monitor.rows.first(where: { $0.pid == pid }) else { return nil }
        return InspectorModel(
            process: row,
            icon: monitor.icon(forAppBundle: row.appBundlePath),
            ports: monitor.ports(heldBy: pid),
            isProtected: monitor.protectedPIDs.contains(pid),
            isConfirming: monitor.confirmingForceQuit == pid
        )
    }
}

// MARK: - Footer

private struct FooterBar: View {
    let monitor: ProcessMonitor

    var body: some View {
        HStack(spacing: 8) {
            if let notice = monitor.notice {
                Label {
                    Text(notice.text).foregroundStyle(notice.isError ? Palette.critical : .primary)
                } icon: {
                    Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .foregroundStyle(notice.isError ? Palette.critical : Palette.memory)
                }
                .lineLimit(1)
                .truncationMode(.middle)
            } else {
                HStack(spacing: 10) {
                    ForEach(hints, id: \.label) { hint in
                        HStack(spacing: 4) {
                            if let key = hint.key { KeyCap(key: key) }
                            Text(hint.label)
                        }
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                monitor.isShowingSettings = true
            } label: {
                Image(systemName: "gearshape").frame(width: 26, height: 24)
            }
            .buttonStyle(IconButtonStyle())
            .foregroundStyle(.secondary)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power").frame(width: 26, height: 24)
            }
            .buttonStyle(IconButtonStyle())
            .foregroundStyle(.secondary)
            .keyboardShortcut("q")
            .help("Quit Dobby (⌘Q)")
            .accessibilityLabel("Quit Dobby")
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 32)
        .overlay(alignment: .top) { Hairline() }
    }

    private var hints: [(key: String?, label: String)] {
        monitor.hasSelection
            ? [("⌘⌫", "Quit"), ("⌥⌘⌫", "Force quit"), ("esc", "Close")]
            : [("↑↓", "Select"), ("⌘1–3", "Views"), (nil, "Type to search")]
    }
}

// MARK: - Keyboard

/// Arrow keys move the selection; works while the search field has focus.
private struct KeyboardControls: ViewModifier {
    let monitor: ProcessMonitor

    func body(content: Content) -> some View {
        content
            .onKeyPress(.upArrow) {
                guard !monitor.isShowingSettings else { return .ignored }
                monitor.moveSelection(by: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard !monitor.isShowingSettings else { return .ignored }
                monitor.moveSelection(by: 1)
                return .handled
            }
    }
}

/// ⌘⌫ quits, ⌥⌘⌫ force quits (press twice), ⌘, opens settings, Esc backs out one step.
/// These are button key equivalents because a focused text field swallows such keys before onKeyPress sees them.
/// Each is disabled when it has nothing to do, so the key falls through (⌘⌫ edits text, Esc closes the panel).
private struct ShortcutButtons: View {
    let monitor: ProcessMonitor

    var body: some View {
        let target = monitor.isShowingSettings ? nil : monitor.selectedTarget
        ZStack {
            Button("Quit Selected Process") {
                if let target { monitor.quit(pid: target.pid, name: target.name) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(target == nil)

            Button("Force Quit Selected Process") {
                if let target { monitor.forceQuit(pid: target.pid, name: target.name) }
            }
            .keyboardShortcut(.delete, modifiers: [.command, .option])
            .disabled(target == nil)

            Button("Settings") {
                monitor.isShowingSettings.toggle()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Cancel") {
                monitor.cancel()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(!monitor.canCancel)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
