import DobbyCore
import SwiftUI

/// Settings shown inside the panel in place of the list (gear button or ⌘,; Back or Esc returns).
struct SettingsView: View {
    let monitor: ProcessMonitor
    @Bindable var theme: ThemeSettings
    @Bindable private var menuBarStats = MenuBarStatsSettings.shared
    @Bindable private var preferences = PreferencesSettings.shared
    private let launchAtLogin = LaunchAtLoginSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    appearance
                    menuBar
                    general
                    systemProcesses
                }
                .padding(12)
            }
            footer
        }
    }

    private var header: some View {
        ZStack {
            Text("Settings").font(.system(size: 13, weight: .semibold))
            HStack {
                Button {
                    monitor.isShowingSettings = false
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text("Back")
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                }
                .buttonStyle(IconButtonStyle())
                .help("Back (Esc)")
                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: Sections

    private var appearance: some View {
        SettingsSection(title: "Appearance") {
            PillSegments(
                options: AppTheme.allCases.map { .init(value: $0, title: $0.title) },
                selection: theme.theme,
                fillsWidth: true
            ) { theme.theme = $0 }
        }
    }

    private var menuBar: some View {
        SettingsSection(title: "Menu bar") {
            Card {
                Row {
                    LabeledSwitch(title: "Show stats next to the icon", isOn: $menuBarStats.isEnabled)
                }
                if menuBarStats.isEnabled {
                    VStack(alignment: .leading, spacing: 10) {
                        preview
                        HStack(spacing: 6) {
                            Text("Items").foregroundStyle(.secondary)
                            Spacer()
                            itemToggle(.cpu, "CPU")
                            itemToggle(.memory, "Memory")
                            itemToggle(.ports, "Ports")
                        }
                        .font(.system(size: 12))
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                Hairline()
                Row(detail: "Turns the ports count orange when a process starts listening on the network.") {
                    LabeledSwitch(title: "Flag new LAN ports", isOn: $preferences.flagsNewNetworkPorts)
                }
                .disabled(!menuBarStats.isEnabled || !preferences.menuBarItems.contains(.ports))
            }
        }
    }

    /// The real readout, drawn the way the menu bar will show it.
    private var preview: some View {
        HStack {
            Spacer()
            if preferences.menuBarItems.isEmpty {
                Text("Only the icon is shown").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Image(nsImage: MenuBarReadout.image(for: monitor.menuBarSummary, items: preferences.menuBarItems))
                    .renderingMode(.template)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.fill))
        .accessibilityLabel("Menu bar preview: \(monitor.menuBarSummary.description)")
    }

    private func itemToggle(_ item: MenuBarItems, _ title: String) -> some View {
        let isOn = preferences.menuBarItems.contains(item)
        return Button {
            if isOn { preferences.menuBarItems.remove(item) } else { preferences.menuBarItems.insert(item) }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(isOn ? Palette.accentSoft : .clear))
                .overlay(Capsule().strokeBorder(isOn ? .clear : Palette.border))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private var general: some View {
        SettingsSection(title: "General") {
            Card {
                Row {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledSwitch(title: "Launch at login", isOn: Binding(
                            get: { launchAtLogin.state != .off },
                            set: { enabled in
                                if let notice = launchAtLogin.setEnabled(enabled) { monitor.show(notice.text, isError: notice.isError) }
                            }
                        ))
                        if launchAtLogin.state == .needsApproval {
                            HStack(spacing: 6) {
                                Label("Waiting for approval", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Palette.warning)
                                Button("Open Login Items…") { launchAtLogin.openLoginItems() }
                                    .buttonStyle(.link)
                            }
                            .font(.system(size: 11))
                        }
                    }
                }
                Hairline()
                Row {
                    HStack {
                        Text("Refresh every")
                        Spacer()
                        PillSegments(
                            options: RefreshInterval.allCases.map { .init(value: $0, title: "\($0.seconds) s") },
                            selection: preferences.refreshInterval,
                            height: 24
                        ) { preferences.refreshInterval = $0 }
                        .fixedSize()
                    }
                }
            }
        }
    }

    private var systemProcesses: some View {
        SettingsSection(title: "System processes") {
            Card {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "shield")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        (Text("Admin helper: ") + Text(helperState).fontWeight(.semibold))
                            .font(.system(size: 12.5))
                        Text("Starts when you choose All users. Runs as root only until you switch back or quit Dobby. launchd, kernel_task, WindowServer and loginwindow can never be ended.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var helperState: String {
        switch monitor.systemAccess {
        case .on: "Running"
        case .requesting: "Starting…"
        case .off: "Off"
        }
    }

    private var footer: some View {
        HStack {
            Text("Dobby \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Text("Quit Dobby")
                    Text("⌘Q").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(FlatButtonStyle())
            .keyboardShortcut("q")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 40)
        .overlay(alignment: .top) { Hairline() }
    }
}

// MARK: - Layout pieces

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
    }
}

/// A title with a small switch at the trailing edge.
private struct LabeledSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

private struct Row<Content: View>: View {
    var detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content
                .font(.system(size: 12.5))
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 44)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
