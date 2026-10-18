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
/// a new port is open to the network, those readouts turn orange; that needs a plain image drawn in
/// colors resolved for `appearance` (the menu bar's), so the caller redraws it when the appearance changes.
@MainActor
enum MenuBarReadout {
    static let appSymbol = "gauge.with.dots.needle.50percent"

    private static let height: CGFloat = 18
    private static let iconTextGap: CGFloat = 2
    private static let statGap: CGFloat = 7
    private static let leadingGap: CGFloat = 8

    static func image(for summary: MenuBarSummary, items: MenuBarItems, appearance: NSAppearance?) -> NSImage {
        // Slots are at least two digits wide and numbers sit right-aligned, so typical changes don't shift the bar.
        let all: [(item: MenuBarItems, symbol: String, text: String, minimum: String, alert: Bool)] = [
            (.cpu, "cpu", summary.cpu, "88%", false),
            (.memory, "memorychip", summary.memory, "88%", summary.isMemoryUnderPressure),
            (.ports, "network", summary.ports, "88", !summary.newNetworkPorts.isEmpty),
        ]
        let stats = all.filter { items.contains($0.item) }
        let colors = palette(alerting: appearance != nil && stats.contains { $0.alert }, appearance: appearance)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let appIcon = symbol(appSymbol, NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        let statConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let laidOut = stats.map { stat in
            let color = stat.alert ? colors.alert : colors.normal
            return (icon: symbol(stat.symbol, statConfig), color: color, text: attributed(stat.text, font, color),
                    width: max(textWidth(stat.text, font), textWidth(stat.minimum, font)))
        }
        let statsWidth = laidOut.reduce(0) { $0 + $1.icon.size.width + iconTextGap + $1.width } + statGap * CGFloat(max(laidOut.count - 1, 0))
        let width = ceil(appIcon.size.width + leadingGap + statsWidth)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            draw(appIcon, color: colors.normal, at: &x)
            x += leadingGap
            for (index, stat) in laidOut.enumerated() {
                if index > 0 { x += statGap }
                draw(stat.icon, color: stat.color, at: &x)
                x += iconTextGap
                let text = stat.text
                // Center the digits' cap height on the icons.
                let baseline = ((height - font.capHeight) / 2).rounded()
                text.draw(at: NSPoint(x: x + stat.width - text.size().width, y: baseline + font.descender))
                x += stat.width
            }
            return true
        }
        image.isTemplate = !colors.isResolved
        image.accessibilityDescription = summary.description
        return image
    }

    /// Black for a template image; otherwise the menu bar's label color and orange, resolved now.
    private static func palette(alerting: Bool, appearance: NSAppearance?) -> (normal: NSColor, alert: NSColor, isResolved: Bool) {
        guard alerting, let appearance else { return (.black, .black, false) }
        var colors: (NSColor, NSColor) = (.black, .black)
        appearance.performAsCurrentDrawingAppearance {
            colors = (NSColor.labelColor.usingColorSpace(.sRGB) ?? .black, NSColor.systemOrange.usingColorSpace(.sRGB) ?? .orange)
        }
        return (colors.0, colors.1, true)
    }

    private static func symbol(_ name: String, _ config: NSImage.SymbolConfiguration) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
    }

    private static func draw(_ icon: NSImage, color: NSColor, at x: inout CGFloat) {
        let size = icon.size
        let rect = NSRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
        if color == .black {
            icon.draw(in: rect)
        } else {
            NSImage(size: size, flipped: false) { bounds in
                icon.draw(in: bounds)
                color.set()
                bounds.fill(using: .sourceAtop)
                return true
            }.draw(in: rect)
        }
        x += size.width
    }

    private static func attributed(_ text: String, _ font: NSFont, _ color: NSColor = .black) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    private static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        ceil(attributed(text, font).size().width)
    }
}
