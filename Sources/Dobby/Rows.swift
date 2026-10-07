import AppKit
import DobbyCore
import SwiftUI

// Column widths shared by rows and their headers.
private enum Column {
    static let pid: CGFloat = 46
    static let bar: CGFloat = 30
    static let value: CGFloat = 62
    static let port: CGFloat = 48
    static let proto: CGFloat = 28
    static let exposure: CGFloat = 58
}

struct ProcessRow: View {
    let row: ProcessUsage
    let metric: Metric
    let scale: Double
    let icon: NSImage
    let state: RowState
    let actions: RowActions

    private var value: Double { ProcessRanking.value(of: row, metric) }
    private var heat: Heat { Heat.forValue(value, metric: metric) }

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(image: icon)
            NameLabel(name: row.name, detail: detail, isSelected: state.isSelected)
            Spacer(minLength: 6)
            Text(String(row.pid))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(state.isSelected ? Color.white.opacity(0.8) : Color.secondary)
                .frame(width: Column.pid, alignment: .trailing)
            MiniBar(fraction: value / max(scale, 1), color: state.isSelected ? .white : heat.barColor)
                .frame(width: Column.bar, height: 3)
            Text(formatted)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(state.isSelected ? .white : heat.textColor)
                .frame(width: Column.value, alignment: .trailing)
        }
        .modifier(RowChrome(state: state, actions: actions))
        .contextMenu {
            TerminationMenuItems(actions: actions)
                .disabled(state.isProtected)
            Divider()
            CopyMenuItem(title: "Copy PID", text: String(row.pid))
            if let path = row.path {
                CopyMenuItem(title: "Copy Path", text: path)
                RevealMenuItem(path: row.appBundlePath ?? path)
            }
        }
    }

    private var detail: String? {
        let parts = [row.owningAppName, row.uid == getuid() ? nil : row.ownerName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var formatted: String {
        switch metric {
        case .cpu: UsageFormat.percent(row.cpuPercent)
        case .memory: UsageFormat.bytes(row.memoryBytes)
        }
    }
}

struct ProcessColumnHeader: View {
    let count: Int
    let includesSystem: Bool
    let metric: Metric
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("Processes \(count)\(includesSystem ? " · incl. system" : "")")
            if isPaused {
                Label("Sort paused", systemImage: "pause.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 6)
            Text("PID").frame(width: Column.pid, alignment: .trailing)
            Color.clear.frame(width: Column.bar, height: 1)
            Text(metric == .cpu ? "CPU ↓" : "Memory ↓").frame(width: Column.value, alignment: .trailing)
        }
        .modifier(ColumnHeaderStyle())
        .help(metric == .cpu ? "CPU is relative to one core (100% = one full core)" : "Memory is the process's actual footprint (same as Activity Monitor)")
    }
}

struct PortRow: View {
    let binding: PortBinding
    let icon: NSImage
    let state: RowState
    let actions: RowActions

    var body: some View {
        HStack(spacing: 8) {
            Text(String(binding.port))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: Column.port, alignment: .leading)
            Text(binding.proto.rawValue.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(state.isSelected ? Color.white.opacity(0.8) : Color.secondary)
                .frame(width: Column.proto, alignment: .leading)
            AppIcon(image: icon)
            NameLabel(name: binding.name, detail: owner, isSelected: state.isSelected)
            Spacer(minLength: 6)
            Text(String(binding.pid))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(state.isSelected ? Color.white.opacity(0.8) : Color.secondary)
                .frame(width: Column.pid, alignment: .trailing)
            ExposureLabel(exposure: binding.exposure, addresses: binding.addresses, isSelected: state.isSelected)
                .frame(width: Column.exposure, alignment: .leading)
        }
        .foregroundStyle(state.isSelected ? Color.white : Color.primary)
        .modifier(RowChrome(state: state, actions: actions))
        .help("Closing this port means ending “\(binding.name)”, the process holding it")
        .contextMenu {
            TerminationMenuItems(actions: actions)
                .disabled(state.isProtected)
            Divider()
            CopyMenuItem(title: "Copy Port", text: String(binding.port))
            CopyMenuItem(title: "Copy PID", text: String(binding.pid))
            if let path = binding.path {
                RevealMenuItem(path: binding.appBundlePath ?? path)
            }
        }
    }

    private var owner: String? {
        binding.ownerName == NSUserName() ? nil : binding.ownerName
    }
}

struct PortColumnHeader: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text("Port").frame(width: Column.port, alignment: .leading)
            Text("Proto").frame(width: Column.proto, alignment: .leading)
            Text("Processes \(count)")
            Spacer(minLength: 6)
            Text("PID").frame(width: Column.pid, alignment: .trailing)
            Text("Reach").frame(width: Column.exposure, alignment: .leading)
        }
        .modifier(ColumnHeaderStyle())
        .help("Closing a port = ending the process holding it")
    }
}

private struct ExposureLabel: View {
    let exposure: PortExposure
    let addresses: [String]
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isSelected ? Color.white : color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.white : exposure == .allInterfaces ? Palette.warning : Color.secondary)
                .lineLimit(1)
        }
        .help(help)
    }

    private var title: String {
        switch exposure {
        case .loopback: "Local"
        case .allInterfaces: "LAN"
        case .specific: addresses.first ?? ""
        }
    }

    private var color: Color {
        switch exposure {
        case .loopback: Palette.memory
        case .allInterfaces: Palette.warning
        case .specific: Palette.user
        }
    }

    private var help: String {
        switch exposure {
        case .loopback: "Listens on 127.0.0.1 / ::1 only; other devices can't connect"
        case .allInterfaces: "Listens on all interfaces; other devices on the network may connect"
        case .specific: "Listens on \(addresses.joined(separator: ", "))"
        }
    }
}

/// Docked under the list: what's selected and how to end it.
struct SelectionActionBar: View {
    let name: String
    let pid: pid_t
    let icon: NSImage
    let isProtected: Bool
    let isConfirmingForceQuit: Bool
    let onQuit: () -> Void
    let onForceQuit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(image: icon)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("PID \(String(pid))")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if isProtected {
                Label("Critical system process, can't end", systemImage: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Button("Quit", action: onQuit)
                    .buttonStyle(FlatButtonStyle())
                    .help("Quit normally; apps can save their data first (⌘⌫)")
                Button(isConfirmingForceQuit ? "Confirm Force Quit" : "Force Quit", action: onForceQuit)
                    .buttonStyle(FlatButtonStyle(tint: Palette.critical, prominent: isConfirmingForceQuit))
                    .help("End the process immediately; unsaved data is lost (⌥⌘⌫, press twice)")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Palette.surface)
        .overlay(alignment: .top) { Hairline() }
    }
}

// MARK: - Shared row pieces

struct RowState {
    var isSelected: Bool
    var isHovering: Bool
    /// Critical system process that Dobby won't end.
    var isProtected: Bool
}

struct RowActions {
    let select: () -> Void
    let hover: (Bool) -> Void
    let quit: () -> Void
    /// Skips the second-press confirmation; used by the context menu.
    let forceQuit: () -> Void
}

private struct NameLabel: View {
    let name: String
    let detail: String?
    let isSelected: Bool

    var body: some View {
        // The detail (owning app / user) is shown only when it fits whole; the name never gives way to it.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                nameText
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            nameText
        }
    }

    private var nameText: some View {
        Text(name)
            .font(.system(size: 12))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

private struct RowChrome: ViewModifier {
    let state: RowState
    let actions: RowActions

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(state.isSelected ? Color.accentColor : state.isHovering ? Color.primary.opacity(0.05) : .clear)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: actions.select)
            .onHover(perform: actions.hover)
    }
}

private struct ColumnHeaderStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 22)
            .overlay(alignment: .bottom) { Hairline() }
    }
}

private struct AppIcon: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: 16, height: 16)
    }
}

private struct TerminationMenuItems: View {
    let actions: RowActions

    var body: some View {
        Button("Quit", action: actions.quit)
        Button("Force Quit", action: actions.forceQuit)
    }
}

private struct CopyMenuItem: View {
    let title: String
    let text: String

    var body: some View {
        Button(title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

private struct RevealMenuItem: View {
    let path: String

    var body: some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}
