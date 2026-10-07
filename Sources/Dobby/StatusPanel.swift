import AppKit
import DobbyCore
import SwiftUI

/// Menu bar icon plus our own borderless panel. Unlike MenuBarExtra's window, the panel has no system
/// glass backdrop, so its outline (and shadow) is exactly the content's rounded shape.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: StatusPanel
    /// Clicking the icon while open first resigns the panel's key status; don't reopen on that same click.
    private var lastHidden = Date.distantPast

    init(monitor: ProcessMonitor, theme: ThemeSettings) {
        let hosting = NSHostingView(rootView: ContentView(monitor: monitor, theme: theme))
        hosting.setFrameSize(hosting.fittingSize)
        panel = StatusPanel(size: hosting.fittingSize)
        panel.contentView = hosting
        super.init()
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Dobby")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: .leftMouseDown)
        }
    }

    @objc private func toggle() {
        if panel.isVisible {
            hide()
        } else if Date().timeIntervalSince(lastHidden) > 0.25 {
            show()
        }
    }

    private func show() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let bounds = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        panel.setFrame(PanelPlacement.frame(for: panel.frame.size, under: anchor, within: bounds), display: false)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        // The shadow follows the content's alpha, so recompute it once the rounded content has drawn.
        Task { @MainActor [panel] in panel.invalidateShadow() }
    }

    private func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        lastHidden = Date()
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

final class StatusPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    // Borderless windows can't become key by default; the search field needs it.
    override var canBecomeKey: Bool { true }

    /// Esc that nothing in the panel handled (no selection, empty search) closes it.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
