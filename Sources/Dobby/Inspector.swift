import AppKit
import DobbyCore
import SwiftUI

/// What the details card shows for the selected process or port.
struct InspectorModel {
    struct Stat {
        let label: String
        let value: String
        var isWarning = false
    }

    enum NoteStyle {
        case path, plain, warning, critical
    }

    enum Action {
        case reveal(String)
        case openInBrowser(UInt16)
        case copy(label: String, text: String)
    }

    let pid: pid_t
    let name: String
    let icon: NSImage
    let title: String
    let subtitle: String
    let stats: [Stat]
    let note: String
    let noteStyle: NoteStyle
    let isProtected: Bool
    let isConfirmingForceQuit: Bool
    let actions: [Action]
}

extension InspectorModel {
    init(process row: ProcessUsage, icon: NSImage, ports: [PortBinding], isProtected: Bool, isConfirming: Bool) {
        let cpuHeat = Heat.forValue(row.cpuPercent, metric: .cpu)
        let memoryHeat = Heat.forValue(Double(row.memoryBytes), metric: .memory)
        var subtitle = "PID \(row.pid)"
        if let app = row.owningAppName { subtitle += " · part of \(app)" }
        var actions: [Action] = []
        if let path = row.path { actions.append(.reveal(row.appBundlePath ?? path)) }
        actions.append(.copy(label: "Copy PID", text: String(row.pid)))
        self.init(
            pid: row.pid,
            name: row.name,
            icon: icon,
            title: row.name,
            subtitle: subtitle,
            stats: [
                Stat(label: "CPU", value: UsageFormat.percent(row.cpuPercent), isWarning: cpuHeat != .normal),
                Stat(label: "Memory", value: UsageFormat.bytes(row.memoryBytes), isWarning: memoryHeat != .normal),
                Stat(label: "User", value: row.ownerName ?? "—"),
                Stat(label: "Ports", value: ports.isEmpty ? "None" : ports.map { ":\($0.port)" }.joined(separator: " ")),
            ],
            note: isConfirming ? "Sends SIGKILL right away. Unsaved work in \(row.name) is lost." : row.path ?? "Executable path unavailable",
            noteStyle: isConfirming ? .critical : .path,
            isProtected: isProtected,
            isConfirmingForceQuit: isConfirming,
            actions: actions
        )
    }

    init(port binding: PortBinding, icon: NSImage, otherPorts: [PortBinding], isProtected: Bool, isConfirming: Bool) {
        let isNetwork = binding.isNetworkReachable
        let others = otherPorts.map { ":\($0.port)" }
        let note: String
        if isConfirming {
            note = "Sends SIGKILL to \(binding.name)." + (others.isEmpty ? "" : " \(others.joined(separator: ", ")) closes too.")
        } else if isNetwork {
            note = "Other devices on your network can connect. Closing it quits \(binding.name)."
        } else {
            note = "Only apps on this Mac can connect. Closing it quits \(binding.name)."
        }
        var actions: [Action] = []
        if binding.proto == .tcp {
            actions.append(.openInBrowser(binding.port))
        } else if let path = binding.path {
            actions.append(.reveal(binding.appBundlePath ?? path))
        }
        actions.append(.copy(label: "Copy Port", text: String(binding.port)))
        self.init(
            pid: binding.pid,
            name: binding.name,
            icon: icon,
            title: "Port \(binding.port) · \(binding.proto.rawValue.uppercased())",
            subtitle: "Held by \(binding.name) · PID \(binding.pid)",
            stats: [
                Stat(label: "Reach", value: isNetwork ? "LAN" : "This Mac", isWarning: isNetwork),
                Stat(label: "Address", value: binding.addresses.map { $0 == "*" ? "All" : $0 }.joined(separator: ", ")),
                Stat(label: "User", value: binding.ownerName ?? "—"),
                Stat(label: "Also holds", value: others.isEmpty ? "None" : others.joined(separator: " ")),
            ],
            note: note,
            noteStyle: isConfirming ? .critical : isNetwork ? .warning : .plain,
            isProtected: isProtected,
            isConfirmingForceQuit: isConfirming,
            actions: actions
        )
    }
}

/// Docked under the list: what's selected, its numbers, and how to end it.
struct InspectorCard: View {
    let model: InspectorModel
    let monitor: ProcessMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                AppIcon(image: model.icon, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button {
                    monitor.selection = nil
                    monitor.portSelection = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Palette.fill))
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
                .accessibilityLabel("Close details")
            }

            HStack(alignment: .top, spacing: 8) {
                ForEach(model.stats, id: \.label) { stat in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stat.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(stat.value)
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(stat.isWarning ? Palette.warning : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("\(stat.label): \(stat.value)")
                }
            }
            .padding(.vertical, 7)
            .overlay(alignment: .top) { Hairline() }
            .overlay(alignment: .bottom) { Hairline() }

            Text(model.note)
                .font(model.noteStyle == .path ? .system(size: 10.5, design: .monospaced) : .system(size: 11))
                .foregroundStyle(noteColor)
                .lineLimit(model.noteStyle == .path ? 1 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .truncationMode(model.noteStyle == .path ? .middle : .tail)
                .help(model.note)

            if model.isProtected {
                Label("Protected: ending \(model.name) would crash macOS or log you out.", systemImage: "lock.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Palette.fill))
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(model.actions.enumerated()), id: \.offset) { _, action in
                        actionButton(action)
                    }
                    Spacer(minLength: 6)
                    Button("Quit") { monitor.quit(pid: model.pid, name: model.name) }
                        .buttonStyle(FlatButtonStyle())
                        .help("Quit normally; apps can save their data first (⌘⌫)")
                    Button(model.isConfirmingForceQuit ? "Confirm Force Quit" : "Force Quit") {
                        monitor.forceQuit(pid: model.pid, name: model.name)
                    }
                    .buttonStyle(FlatButtonStyle(tint: Palette.critical, prominent: model.isConfirmingForceQuit))
                    .help("End the process immediately; unsaved data is lost (⌥⌘⌫, press twice)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Palette.raised)
        )
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.border))
        .elevated(cornerRadius: 11, depth: 2)
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    private var noteColor: Color {
        switch model.noteStyle {
        case .path, .plain: .secondary
        case .warning: Palette.warning
        case .critical: Palette.critical
        }
    }

    private func actionButton(_ action: InspectorModel.Action) -> some View {
        let (symbol, help): (String, String) = switch action {
        case .reveal: ("folder", "Show in Finder")
        case .openInBrowser(let port): ("arrow.up.forward.square", "Open localhost:\(port) in the browser")
        case .copy(let label, _): ("doc.on.doc", label)
        }
        return Button {
            switch action {
            case .reveal(let path): Finder.reveal(path)
            case .openInBrowser(let port):
                if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
            case .copy(let label, let text):
                Pasteboard.copy(text)
                monitor.show("\(label.replacingOccurrences(of: "Copy ", with: "")) copied", isError: false)
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}
