import DobbyCore
import SwiftUI

struct ContentView: View {
    @Bindable var monitor: ProcessMonitor
    @Bindable var theme: ThemeSettings
    @FocusState private var searchFocused: Bool
    private let launchAtLogin = LaunchAtLoginSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(items: tabItems, selection: $monitor.tab)
            summary
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(height: 98)
            Hairline()
            searchRow
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            columnHeader
            list
            if let target = monitor.selectedTarget {
                SelectionActionBar(
                    name: target.name,
                    pid: target.pid,
                    icon: target.icon,
                    isProtected: monitor.protectedPIDs.contains(target.pid),
                    isConfirmingForceQuit: monitor.confirmingForceQuit == target.pid,
                    onQuit: { monitor.quit(pid: target.pid, name: target.name) },
                    onForceQuit: { monitor.forceQuit(pid: target.pid, name: target.name) }
                )
            }
            footer
        }
        .frame(width: 400, height: 580)
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

    // MARK: Tabs & summary

    private var tabItems: [TabStrip.Item] {
        [
            .init(tab: .cpu, title: "CPU", value: monitor.systemCPU.map(percent) ?? "—", shortcut: "1"),
            .init(tab: .memory, title: "Memory", value: monitor.memory.map { UsageFormat.bytes($0.usedBytes) } ?? "—", shortcut: "2"),
            .init(tab: .ports, title: "Ports", value: monitor.hasSampled ? String(monitor.allPorts.count) : "—", shortcut: "3"),
        ]
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    @ViewBuilder private var summary: some View {
        switch monitor.tab {
        case .cpu:
            HStack(spacing: 14) {
                HistoryGraph(
                    series: [
                        .init(values: monitor.cpuHistory.map(\.user), color: Palette.user),
                        .init(values: monitor.cpuHistory.map(\.system), color: Palette.system),
                    ],
                    capacity: 90
                )
                VStack(spacing: 2) {
                    StatLine(color: Palette.user, label: "User", value: monitor.cpuLoad.map { percent($0.user) } ?? "—")
                    StatLine(color: Palette.system, label: "System", value: monitor.cpuLoad.map { percent($0.system) } ?? "—")
                    StatLine(color: nil, label: "Idle", value: monitor.cpuLoad.map { percent(1 - $0.total) } ?? "—")
                    StatLine(color: nil, label: "Cores", value: String(SystemStats.coreCount))
                }
                .frame(width: 146)
            }
        case .memory:
            HStack(spacing: 14) {
                HistoryGraph(series: [.init(values: monitor.memoryHistory, color: pressureColor)], capacity: 90)
                VStack(spacing: 2) {
                    StatLine(color: pressureColor, label: "Used", value: monitor.memory.map { UsageFormat.bytes($0.usedBytes) } ?? "—")
                    StatLine(color: nil, label: "App", value: monitor.memory.map { UsageFormat.bytes($0.appBytes) } ?? "—")
                    StatLine(color: nil, label: "Wired", value: monitor.memory.map { UsageFormat.bytes($0.wiredBytes) } ?? "—")
                    StatLine(color: nil, label: "Compressed", value: monitor.memory.map { UsageFormat.bytes($0.compressedBytes) } ?? "—")
                    StatLine(color: nil, label: "Pressure", value: pressureLabel, valueColor: pressureColor)
                }
                .frame(width: 146)
            }
        case .ports:
            let ports = monitor.allPorts
            Grid(horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    StatLine(color: nil, label: "TCP listening", value: String(ports.filter { $0.proto == .tcp }.count))
                    StatLine(color: nil, label: "UDP", value: String(ports.filter { $0.proto == .udp }.count))
                }
                GridRow {
                    StatLine(color: Palette.memory, label: "Local only", value: String(ports.filter { $0.exposure == .loopback }.count))
                    StatLine(color: Palette.warning, label: "Network-reachable", value: String(ports.filter { $0.exposure != .loopback }.count))
                }
                GridRow {
                    Text("Closing a port ends the process holding it")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .gridCellColumns(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private var pressureColor: Color {
        switch monitor.memory?.pressure {
        case .warning: Palette.warning
        case .critical: Palette.critical
        default: Palette.memory
        }
    }

    private var pressureLabel: String {
        switch monitor.memory?.pressure {
        case .warning: "High"
        case .critical: "Critical"
        case .normal: "Normal"
        case nil: "—"
        }
    }

    // MARK: Search

    private var searchRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(monitor.tab == .ports ? "Search port, process or PID" : "Search process, app, user or PID", text: $monitor.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
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
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 4).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.border))

            systemAccessToggle
        }
    }

    private var systemAccessToggle: some View {
        HStack(spacing: 4) {
            Toggle(isOn: Binding(
                get: { monitor.systemAccess == .on },
                set: { _ in monitor.toggleSystemAccess() }
            )) {
                Text("System processes").font(.system(size: 11.5))
            }
            .toggleStyle(.checkbox)
            .disabled(monitor.systemAccess == .requesting)
            if monitor.systemAccess == .requesting {
                ProgressView().controlSize(.mini)
            }
        }
        .help(monitor.systemAccess == .on
            ? "Showing processes of all users (root and others). Unchecking stops the admin helper"
            : "Show and end processes and ports of root and other users (asks for an admin password; lasts until Dobby quits)")
    }

    // MARK: List

    @ViewBuilder private var columnHeader: some View {
        if monitor.tab == .ports {
            PortColumnHeader(count: monitor.portRows.count)
        } else {
            ProcessColumnHeader(
                count: monitor.rows.count,
                includesSystem: monitor.systemAccess == .on,
                metric: monitor.metric,
                isPaused: monitor.isPointerInList
            )
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if monitor.tab == .ports {
                        ForEach(monitor.portRows) { binding in
                            PortRow(
                                binding: binding,
                                icon: monitor.icon(forAppBundle: binding.appBundlePath),
                                state: state(rowID: binding.id, pid: binding.pid, isSelected: monitor.portSelection == binding.id),
                                actions: actions(rowID: binding.id, pid: binding.pid, name: binding.name) {
                                    monitor.portSelection = monitor.portSelection == binding.id ? nil : binding.id
                                }
                            )
                            .id(AnyHashable(binding.id))
                        }
                    } else {
                        ForEach(monitor.rows) { row in
                            ProcessRow(
                                row: row,
                                metric: monitor.metric,
                                scale: monitor.barScale,
                                icon: monitor.icon(forAppBundle: row.appBundlePath),
                                state: state(rowID: row.pid, pid: row.pid, isSelected: monitor.selection == row.pid),
                                actions: actions(rowID: row.pid, pid: row.pid, name: row.name) {
                                    monitor.selection = monitor.selection == row.pid ? nil : row.pid
                                }
                            )
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

    private func scroll(_ proxy: ScrollViewProxy, to id: AnyHashable?) {
        guard let id, !monitor.isPointerInList else { return }
        proxy.scrollTo(id)
    }

    private func state(rowID: AnyHashable, pid: pid_t, isSelected: Bool) -> RowState {
        RowState(
            isSelected: isSelected,
            isHovering: monitor.hoveredRowID == rowID,
            isProtected: monitor.protectedPIDs.contains(pid)
        )
    }

    private func actions(rowID: AnyHashable, pid: pid_t, name: String, select: @escaping () -> Void) -> RowActions {
        RowActions(
            select: select,
            hover: { inside in
                if inside { monitor.hoveredRowID = rowID } else if monitor.hoveredRowID == rowID { monitor.hoveredRowID = nil }
            },
            quit: { monitor.quit(pid: pid, name: name) },
            forceQuit: { monitor.forceQuit(pid: pid, name: name, confirmed: true) }
        )
    }

    @ViewBuilder private var emptyState: some View {
        let isEmpty = monitor.tab == .ports ? monitor.portRows.isEmpty : monitor.rows.isEmpty
        if !isEmpty {
            EmptyView()
        } else if !monitor.hasSampled {
            ProgressView().controlSize(.small)
        } else if !monitor.query.isEmpty {
            ContentUnavailableView.search(text: monitor.query)
        } else if monitor.tab == .ports {
            ContentUnavailableView("No ports in use", systemImage: "network.slash", description: Text(monitor.systemAccess == .on ? "No process is listening on a port" : "None of your processes is listening on a port"))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let notice = monitor.notice {
                Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(notice.isError ? Palette.critical : Palette.memory)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("↑↓ select · ⌘⌫ quit · ⌥⌘⌫ force quit · ⌘1/2/3 tabs")
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            settingsMenu
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut("q")
            .help("Quit Dobby (⌘Q)")
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 14)
        .frame(height: 28)
        .overlay(alignment: .top) { Hairline() }
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Appearance", selection: $theme.theme) {
                ForEach(AppTheme.allCases, id: \.self) { option in
                    Label(option.title, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(launchAtLogin.state == .needsApproval ? "Launch at Login (Needs Approval)" : "Launch at Login", isOn: Binding(
                get: { launchAtLogin.state != .off },
                set: { enabled in
                    if let notice = launchAtLogin.setEnabled(enabled) { monitor.show(notice.text, isError: notice.isError) }
                }
            ))
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Settings: appearance, launch at login")
    }
}

/// Arrow keys move the selection; works while the search field has focus.
private struct KeyboardControls: ViewModifier {
    let monitor: ProcessMonitor

    func body(content: Content) -> some View {
        content
            .onKeyPress(.upArrow) {
                monitor.moveSelection(by: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                monitor.moveSelection(by: 1)
                return .handled
            }
    }
}

/// ⌘⌫ quits, ⌥⌘⌫ force quits (press twice), Esc clears selection then search.
/// These are button key equivalents because a focused text field swallows such keys before onKeyPress sees them.
/// Each is disabled when it has nothing to do, so the key falls through (⌘⌫ edits text, Esc closes the panel).
private struct ShortcutButtons: View {
    let monitor: ProcessMonitor

    var body: some View {
        let target = monitor.selectedTarget
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

            Button("Cancel") {
                monitor.clearSelectionOrQuery()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(target == nil && monitor.query.isEmpty)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
