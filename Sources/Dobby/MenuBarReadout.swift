import AppKit
import DobbyCore
import Observation

/// The "Show Stats in Menu Bar" setting.
@MainActor
@Observable
final class MenuBarStatsSettings {
    static let shared = MenuBarStatsSettings()

    var isEnabled: Bool {
        didSet { store.isEnabled = isEnabled }
    }
    @ObservationIgnored private let store = MenuBarStatsStore()

    private init() {
        isEnabled = store.isEnabled
    }
}

/// Draws the menu bar icon followed by iStat Menus–style "icon + number" readouts. Normally one template
/// image, so the system tints it for light, dark and highlighted menu bars. When memory pressure is high or
/// a new port is open to the network, those readouts turn orange; that needs a plain image whose colors are
/// resolved inside the drawing handler, which AppKit runs (and caches) per appearance, so each menu bar gets
/// its own label color without the caller observing appearance changes.
@MainActor
enum MenuBarReadout {
    static let appSymbol = "gauge.with.dots.needle.50percent"

    private static let height: CGFloat = 20
    private static let iconTextGap: CGFloat = 2
    private static let statGap: CGFloat = 7
    private static let leadingGap: CGFloat = 8
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    static let appIcon: NSImage = {
        let image = symbol(appSymbol, NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        image.accessibilityDescription = "Dobby"
        return image
    }()
    private static let statIcons: [String: NSImage] = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        return Dictionary(uniqueKeysWithValues: ["cpu", "memorychip", "network"].map { ($0, symbol($0, config)) })
    }()
    private static let minimumWidths: [MenuBarItems: CGFloat] = [
        .cpu: textWidth("88%"), .memory: textWidth("88%"), .ports: textWidth("88"),
    ]
    private static let networkFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let networkIcons = ["arrow.up", "arrow.down"].map {
        symbol($0, NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
    }
    // Separate number and unit columns keep both rows aligned as rates change.
    private static let networkValueWidth = ceil(("1024" as NSString).size(withAttributes: [.font: networkFont]).width)
    private static let networkUnitWidth = ceil(("MB/s" as NSString).size(withAttributes: [.font: networkFont]).width)
    private static let networkIconWidth = networkIcons.map(\.size.width).max() ?? 0
    private static let networkWidth = networkIconWidth + iconTextGap + networkValueWidth + 2 + networkUnitWidth

    static func image(for summary: MenuBarSummary, items: MenuBarItems) -> NSImage {
        let all: [(item: MenuBarItems, text: String, symbol: String, alert: Bool)] = [
            (.cpu, summary.cpu, "cpu", false),
            (.memory, summary.memory, "memorychip", summary.isMemoryUnderPressure),
            (.ports, summary.ports, "network", !summary.newNetworkPorts.isEmpty),
        ]
        let stats = all.filter { items.contains($0.item) }
        let alerting = stats.contains { $0.alert }
        let laidOut = stats.map { stat in
            (icon: statIcons[stat.symbol] ?? NSImage(), text: stat.text, alert: stat.alert,
             width: max(textWidth(stat.text), minimumWidths[stat.item] ?? 0))
        }
        let showsNetwork = items.contains(.network)
        let groupCount = laidOut.count + (showsNetwork ? 1 : 0)
        let statsWidth = laidOut.reduce(0) { $0 + $1.icon.size.width + iconTextGap + $1.width }
            + (showsNetwork ? networkWidth : 0) + statGap * CGFloat(max(groupCount - 1, 0))
        let width = ceil(appIcon.size.width + leadingGap + statsWidth)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            // Black for a template image; otherwise the current (menu bar) appearance's label color and orange.
            let normal = alerting ? NSColor.labelColor : .black
            let alert = alerting ? NSColor.systemOrange : .black
            var x: CGFloat = 0
            draw(appIcon, tint: alerting ? normal : nil, at: &x)
            x += leadingGap
            // Center the digits' cap height on the icons.
            let baseline = ((height - font.capHeight) / 2).rounded()
            for (index, stat) in laidOut.enumerated() {
                if index > 0 { x += statGap }
                let color = stat.alert ? alert : normal
                draw(stat.icon, tint: alerting ? color : nil, at: &x)
                x += iconTextGap
                let text = attributed(stat.text, color)
                text.draw(at: NSPoint(x: x + stat.width - text.size().width, y: baseline + font.descender))
                x += stat.width
            }
            if showsNetwork {
                if !laidOut.isEmpty { x += statGap }
                drawNetwork(summary, color: normal, at: x)
            }
            return true
        }
        image.isTemplate = !alerting
        image.accessibilityDescription = summary.description
        return image
    }

    private static func drawNetwork(_ summary: MenuBarSummary, color: NSColor, at x: CGFloat) {
        let secondary = color.withAlphaComponent(0.75)
        for (index, rate) in [summary.upload, summary.download].enumerated() {
            let centerY = height - (CGFloat(index) + 0.5) * height / 2
            var iconX = x
            draw(networkIcons[index], tint: secondary, at: &iconX, centerY: centerY)
            let parts = rate.split(separator: " ", maxSplits: 1)
            let value = NSAttributedString(string: String(parts.first ?? "–"), attributes: [.font: networkFont, .foregroundColor: color])
            let unit = NSAttributedString(string: parts.count > 1 ? String(parts[1]) : "", attributes: [.font: networkFont, .foregroundColor: secondary])
            let valueX = x + networkIconWidth + iconTextGap
            let baseline = (centerY - networkFont.capHeight / 2).rounded() + networkFont.descender
            value.draw(at: NSPoint(x: valueX + networkValueWidth - value.size().width, y: baseline))
            unit.draw(at: NSPoint(x: valueX + networkValueWidth + 2, y: baseline))
        }
    }

    private static func symbol(_ name: String, _ config: NSImage.SymbolConfiguration) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
    }

    /// Draws `icon` as is, or filled with `tint` (in a transparency layer, so only the icon's pixels change).
    private static func draw(_ icon: NSImage, tint: NSColor?, at x: inout CGFloat, centerY: CGFloat = height / 2) {
        let size = icon.size
        let rect = NSRect(x: x, y: (centerY - size.height / 2).rounded(), width: size.width, height: size.height)
        if let tint, let context = NSGraphicsContext.current?.cgContext {
            context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
            icon.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            context.endTransparencyLayer()
        } else {
            icon.draw(in: rect)
        }
        x += size.width
    }

    private static func attributed(_ text: String, _ color: NSColor = .black) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    private static func textWidth(_ text: String) -> CGFloat {
        ceil(attributed(text).size().width)
    }
}
