import AppKit
import DobbyCore
import SwiftUI

/// Development aid: `DOBBY_SNAPSHOT=out.png Dobby` renders the panel to a PNG and exits.
/// Optional: DOBBY_SNAPSHOT_TAB=memory|ports|menubar (menubar: the status item readout instead of the panel), DOBBY_SNAPSHOT_SELECT=<row index>, DOBBY_SNAPSHOT_THEME=system|light|dark,
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
        case "menubar":
            monitor.showsMenuBarStats = true
            Task {
                try? await Task.sleep(for: .seconds(env["DOBBY_SNAPSHOT_WAIT"].flatMap(Double.init) ?? 2.6))
                writeMenuBar(monitor.menuBarSummary, to: output)
            }
            return true
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

    /// The template readout tinted as on a light or dark menu bar, at 2x.
    private static func writeMenuBar(_ summary: MenuBarSummary, to output: String) {
        let readout = MenuBarReadout.image(for: summary)
        let isDark = (NSApp.appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let padding: CGFloat = 10
        let size = NSSize(width: readout.size.width + padding * 2, height: 24)
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { exit(1) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (isDark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSRect(origin: .zero, size: size).fill()
        let tinted = NSImage(size: readout.size, flipped: false) { rect in
            readout.draw(in: rect)
            (isDark ? NSColor.white : NSColor.black).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(at: NSPoint(x: padding, y: (size.height - readout.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        exit(0)
    }
}
