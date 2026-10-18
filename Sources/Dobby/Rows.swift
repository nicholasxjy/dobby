import AppKit
import DobbyCore
import SwiftUI

// Column widths shared by rows and their headers.
enum Column {
    static let pid: CGFloat = 46
    static let bar: CGFloat = 32
    static let value: CGFloat = 58
    static let port: CGFloat = 44
    static let proto: CGFloat = 30
    static let reach: CGFloat = 58
    static let rowHeight: CGFloat = 28
}

/// Read once; rows compare port owners against it.
private let currentUserName = NSUserName()

struct RowState: Equatable {
    var isSelected: Bool
    var isHovering: Bool
    /// Critical system process that Dobby won't end.
    var isProtected: Bool

    /// Hovering an endable, unselected row swaps its icon for a quit button.
    var showsQuitButton: Bool { isHovering && !isSelected && !isProtected }
    var primary: Color { isSelected ? .white : .primary }
    var secondary: Color { isSelected ? .white.opacity(0.8) : .secondary }
}

/// Rows hold values plus the monitor (a stable reference) instead of closures, so SwiftUI can skip
/// re-rendering rows whose values didn't change.
struct ProcessRow: View, @MainActor Equatable {
    let row: ProcessUsage
    let metric: Metric
    let scale: Double
    let icon: NSImage
    let state: RowState
    let monitor: ProcessMonitor

    static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.metric == b.metric && a.scale == b.scale && a.icon === b.icon && a.state == b.state
    }

    var body: some View {
        let value = ProcessRanking.value(of: row, metric)
        let heat = Heat.forValue(value, metric: metric)
        let label = row.displayLabel(currentUID: getuid())
        HStack(spacing: 8) {
            RowLeading(icon: icon, state: state, quitHelp: "Quit “\(row.name)” (⌘⌫)") {
                monitor.quit(pid: row.pid, name: row.name)
            }
            NameLabel(title: label.title, detail: label.detail, state: state)
            Spacer(minLength: 4)
            if state.isProtected {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(state.secondary)
                    .accessibilityLabel("Protected")
            }
            Text(String(row.pid))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(state.secondary)
                .frame(width: Column.pid, alignment: .trailing)
            MiniBar(
                fraction: value / max(scale, 1),
                color: state.isSelected ? .white : heat.barColor,
                track: state.isSelected ? .white.opacity(0.28) : Palette.track,
                width: Column.bar
            )
            Text(formatted(value))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(state.isSelected ? .white : heat.textColor)
                .frame(width: Column.value, alignment: .trailing)
        }
        .modifier(RowChrome(state: state, id: AnyHashable(row.pid), monitor: monitor) {
            monitor.toggleSelection(row.pid)
        })
        .contextMenu {
            TerminationMenuItems(monitor: monitor, pid: row.pid, name: row.name)
                .disabled(state.isProtected)
            Divider()
            Button("Copy PID") { Pasteboard.copy(String(row.pid)) }
            if let path = row.path {
                Button("Copy Path") { Pasteboard.copy(path) }
                Button("Show in Finder") { Finder.reveal(row.appBundlePath ?? path) }
            }
        }
    }

    private func formatted(_ value: Double) -> String {
        switch metric {
        case .cpu: UsageFormat.percent(value)
        case .memory: UsageFormat.bytes(row.memoryBytes)
        }
    }
}

struct PortRow: View, @MainActor Equatable {
    let binding: PortBinding
    let icon: NSImage
    let state: RowState
    let monitor: ProcessMonitor

    static func == (a: Self, b: Self) -> Bool {
        a.binding == b.binding && a.icon === b.icon && a.state == b.state
    }

    var body: some View {
        let label = binding.displayLabel(currentUser: currentUserName)
        HStack(spacing: 8) {
            Text(String(binding.port))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(state.primary)
                .frame(width: Column.port, alignment: .leading)
            Text(binding.proto.rawValue.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(state.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(state.isSelected ? .white.opacity(0.45) : Palette.border))
                .frame(width: Column.proto, alignment: .leading)
            RowLeading(icon: icon, state: state, quitHelp: "Quit “\(binding.name)”, which holds this port (⌘⌫)") {
                monitor.quit(pid: binding.pid, name: binding.name)
            }
            NameLabel(title: label.title, detail: label.detail, state: state)
            Spacer(minLength: 4)
            Text(String(binding.pid))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(state.secondary)
                .frame(width: Column.pid, alignment: .trailing)
            ReachPill(isNetwork: binding.isNetworkReachable, isSelected: state.isSelected)
                .frame(width: Column.reach, alignment: .trailing)
        }
        .modifier(RowChrome(state: state, id: AnyHashable(binding.id), monitor: monitor) {
            monitor.togglePortSelection(binding.id)
        })
        .contextMenu {
            TerminationMenuItems(monitor: monitor, pid: binding.pid, name: binding.name)
                .disabled(state.isProtected)
            Divider()
            Button("Copy Port") { Pasteboard.copy(String(binding.port)) }
            Button("Copy PID") { Pasteboard.copy(String(binding.pid)) }
            if let path = binding.path {
                Button("Show in Finder") { Finder.reveal(binding.appBundlePath ?? path) }
            }
        }
    }
}

/// "LAN" in orange for network-reachable ports, "Local" otherwise.
struct ReachPill: View {
    let isNetwork: Bool
    var isSelected = false

    var body: some View {
        HStack(spacing: 3) {
            if isNetwork { Image(systemName: "wifi").font(.system(size: 8, weight: .bold)) }
            Text(isNetwork ? "LAN" : "Local")
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(isSelected ? .white : isNetwork ? Palette.warning : .secondary)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(isSelected ? .white.opacity(0.22) : isNetwork ? Palette.warningSoft : Palette.fill))
    }
}

struct ProcessColumnHeader: View {
    let title: String
    let isAdminOn: Bool
    let isPaused: Bool
    let metric: Metric

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            HeaderBadges(isAdminOn: isAdminOn, isPaused: isPaused)
            Spacer(minLength: 4)
            Text("PID").frame(width: Column.pid, alignment: .trailing)
            Text(metric == .cpu ? "CPU ↓" : "Memory ↓")
                .frame(width: Column.bar + 8 + Column.value, alignment: .trailing)
        }
        .modifier(ColumnHeaderStyle())
        .help(metric == .cpu ? "CPU is relative to one core (100% = one full core)" : "Memory is the process's actual footprint (same as Activity Monitor)")
    }
}

struct PortColumnHeader: View {
    let isAdminOn: Bool
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("Port").frame(width: Column.port, alignment: .leading)
            Text("Proto").frame(width: Column.proto, alignment: .leading)
            Text("Process")
            HeaderBadges(isAdminOn: isAdminOn, isPaused: isPaused)
            Spacer(minLength: 4)
            Text("PID").frame(width: Column.pid, alignment: .trailing)
            Text("Reach").frame(width: Column.reach, alignment: .trailing)
        }
        .modifier(ColumnHeaderStyle())
    }
}

private struct HeaderBadges: View {
    let isAdminOn: Bool
    let isPaused: Bool

    var body: some View {
        if isAdminOn {
            Badge(text: "Admin helper on", symbol: "shield.fill", foreground: .accentColor, background: Palette.accentSoft)
                .help("The admin helper is running. Choose Mine to stop it.")
        }
        if isPaused {
            Badge(text: "Paused", symbol: "pause.fill")
                .help("Rows hold still while the pointer is over the list")
        }
    }
}

// MARK: - Shared row pieces

/// The app icon, or a quit button in its place while the row is hovered.
private struct RowLeading: View {
    let icon: NSImage
    let state: RowState
    let quitHelp: String
    let quit: () -> Void

    var body: some View {
        if state.showsQuitButton {
            Button(action: quit) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Palette.critical)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Palette.criticalSoft))
            }
            .buttonStyle(.plain)
            .help(quitHelp)
            .accessibilityLabel("Quit")
        } else {
            AppIcon(image: icon)
        }
    }
}

private struct NameLabel: View {
    let title: String
    let detail: String?
    let state: RowState

    var body: some View {
        // The title keeps its room; the detail truncates first.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(state.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(state.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct RowChrome: ViewModifier {
    let state: RowState
    let id: AnyHashable
    let monitor: ProcessMonitor
    let select: () -> Void

    func body(content: Content) -> some View {
        content
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: Column.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(state.isSelected ? Color.accentColor : state.isHovering ? Palette.hover : .clear)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .onHover { monitor.setHovered(id, $0) }
            .accessibilityAddTraits(state.isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct ColumnHeaderStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(height: 24)
            .overlay(alignment: .top) { Hairline() }
            .overlay(alignment: .bottom) { Hairline() }
    }
}

struct AppIcon: View {
    let image: NSImage
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

private struct TerminationMenuItems: View {
    let monitor: ProcessMonitor
    let pid: pid_t
    let name: String

    var body: some View {
        Button("Quit") { monitor.quit(pid: pid, name: name) }
        Button("Force Quit") { monitor.forceQuit(pid: pid, name: name, confirmed: true) }
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum Finder {
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
