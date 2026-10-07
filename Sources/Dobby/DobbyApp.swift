import AppKit
import SwiftUI

@main
struct DobbyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar icon and panel are managed by StatusPanelController; SwiftUI just needs a scene.
        MenuBarExtra("Dobby", systemImage: "gauge.with.dots.needle.50percent", isInserted: .constant(false)) {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: StatusPanelController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu bar only, even when launched without the bundle's LSUIElement (e.g. `swift run`).
        NSApp.setActivationPolicy(.accessory)
        ThemeSettings.shared.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SnapshotRenderer.runIfRequested() { return }
        panelController = StatusPanelController(monitor: ProcessMonitor(), theme: ThemeSettings.shared)
    }
}
