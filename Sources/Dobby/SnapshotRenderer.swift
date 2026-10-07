import AppKit
import DobbyCore
import SwiftUI

/// Development aid: `DOBBY_SNAPSHOT=out.png Dobby` renders the panel to a PNG and exits.
/// Optional: DOBBY_SNAPSHOT_TAB=memory|ports, DOBBY_SNAPSHOT_SELECT=<row index>, DOBBY_SNAPSHOT_THEME=system|light|dark,
/// DOBBY_SNAPSHOT_WAIT=<seconds before capture>.
@MainActor
enum SnapshotRenderer {
    /// Returns true when a snapshot was requested (the app exits once it's written).
    static func runIfRequested() -> Bool {
        let env = Foundation.ProcessInfo.processInfo.environment
        guard let output = env["DOBBY_SNAPSHOT"] else { return false }

        if let theme = env["DOBBY_SNAPSHOT_THEME"].flatMap(AppTheme.init(rawValue:)) {
            ThemeSettings.shared.persists = false
            ThemeSettings.shared.theme = theme
        }
        let monitor = ProcessMonitor()
        switch env["DOBBY_SNAPSHOT_TAB"] {
        case "memory": monitor.tab = .memory
        case "ports": monitor.tab = .ports
        default: break
        }
        monitor.start()

        Task {
            // Longer waits let the history graphs fill in.
            try? await Task.sleep(for: .seconds(env["DOBBY_SNAPSHOT_WAIT"].flatMap(Double.init) ?? 2.6))
            if let index = env["DOBBY_SNAPSHOT_SELECT"].flatMap(Int.init) {
                if monitor.tab == .ports, monitor.portRows.indices.contains(index) {
                    monitor.portSelection = monitor.portRows[index].id
                } else if monitor.rows.indices.contains(index) {
                    monitor.selection = monitor.rows[index].pid
                }
            }
            try? await Task.sleep(for: .milliseconds(400))

            let hosting = NSHostingView(rootView: ContentView(monitor: monitor, theme: ThemeSettings.shared))
            hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 580)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(500))

            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
            exit(0)
        }
        return true
    }
}
