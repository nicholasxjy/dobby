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
            .init(tab: .memory, title: "内存", value: monitor.memory.map { UsageFormat.bytes($0.usedBytes) } ?? "—", shortcut: "2"),
            .init(tab: .ports, title: "端口", value: monitor.hasSampled ? String(monitor.allPorts.count) : "—", shortcut: "3"),
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
                    StatLine(color: Palette.user, label: "用户", value: monitor.cpuLoad.map { percent($0.user) } ?? "—")
                    StatLine(color: Palette.system, label: "系统", value: monitor.cpuLoad.map { percent($0.system) } ?? "—")
                    StatLine(color: nil, label: "空闲", value: monitor.cpuLoad.map { percent(1 - $0.total) } ?? "—")
                    StatLine(color: nil, label: "核心", value: String(SystemStats.coreCount))
                }
                .frame(width: 128)
            }
        case .memory:
            HStack(spacing: 14) {
                HistoryGraph(series: [.init(values: monitor.memoryHistory, color: pressureColor)], capacity: 90)
                VStack(spacing: 2) {
                    StatLine(color: pressureColor, label: "已用", value: monitor.memory.map { UsageFormat.bytes($0.usedBytes) } ?? "—")
                    StatLine(color: nil, label: "App", value: monitor.memory.map { UsageFormat.bytes($0.appBytes) } ?? "—")
                    StatLine(color: nil, label: "联动", value: monitor.memory.map { UsageFormat.bytes($0.wiredBytes) } ?? "—")
                    StatLine(color: nil, label: "已压缩", value: monitor.memory.map { UsageFormat.bytes($0.compressedBytes) } ?? "—")
                    StatLine(color: nil, label: "压力", value: pressureLabel, valueColor: pressureColor)
                }
                .frame(width: 128)
            }
        case .ports:
            let ports = monitor.allPorts
            Grid(horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    StatLine(color: nil, label: "TCP 监听", value: String(ports.filter { $0.proto == .tcp }.count))
                    StatLine(color: nil, label: "UDP", value: String(ports.filter { $0.proto == .udp }.count))
                }
                GridRow {
                    StatLine(color: Palette.memory, label: "仅本机", value: String(ports.filter { $0.exposure == .loopback }.count))
                    StatLine(color: Palette.warning, label: "局域网可访问", value: String(ports.filter { $0.exposure != .loopback }.count))
                }
                GridRow {
                    Text("关闭端口即结束占用它的进程")
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
        case .warning: "偏高"
        case .critical: "严重"
        case .normal: "正常"
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
                TextField(monitor.tab == .ports ? "搜索端口号、进程名或 PID" : "搜索进程名、所属应用、用户或 PID", text: $monitor.query)
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
                    .help("清除搜索")
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
                Text("含系统进程").font(.system(size: 11.5))
            }
            .toggleStyle(.checkbox)
            .disabled(monitor.systemAccess == .requesting)
            if monitor.systemAccess == .requesting {
                ProgressView().controlSize(.mini)
            }
        }
        .help(monitor.systemAccess == .on
            ? "正在显示所有用户的进程（root 等）。取消勾选会结束管理员助手"
            : "显示 root 等其他用户的进程和端口，并允许结束它们（需要管理员密码，Dobby 退出后失效）")
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
            ContentUnavailableView("没有被占用的端口", systemImage: "network.slash", description: Text(monitor.systemAccess == .on ? "没有进程在监听端口" : "当前用户的进程都没有在监听端口"))
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
                Text("↑↓ 选择 · ⌘⌫ 退出 · ⌥⌘⌫ 强制退出 · ⌘1/2/3 切换")
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
            .help("退出 Dobby（⌘Q）")
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 14)
        .frame(height: 28)
        .overlay(alignment: .top) { Hairline() }
    }

    private var settingsMenu: some View {
        Menu {
            Picker("外观", selection: $theme.theme) {
                ForEach(AppTheme.allCases, id: \.self) { option in
                    Label(option.title, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(launchAtLogin.state == .needsApproval ? "开机启动（待系统设置中允许）" : "开机启动", isOn: Binding(
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
        .help("设置：外观、开机启动")
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
            Button("退出所选进程") {
                if let target { monitor.quit(pid: target.pid, name: target.name) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(target == nil)

            Button("强制退出所选进程") {
                if let target { monitor.forceQuit(pid: target.pid, name: target.name) }
            }
            .keyboardShortcut(.delete, modifiers: [.command, .option])
            .disabled(target == nil)

            Button("取消") {
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
