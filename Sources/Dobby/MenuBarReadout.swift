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

/// Draws the menu bar icon followed by iStat Menus–style "icon + number" readouts, as one template image
/// so the system tints it for light, dark and highlighted menu bars.
@MainActor
enum MenuBarReadout {
    static let appSymbol = "gauge.with.dots.needle.50percent"

    private static let height: CGFloat = 18
    private static let iconTextGap: CGFloat = 2
    private static let statGap: CGFloat = 7
    private static let leadingGap: CGFloat = 8

    static func image(for summary: MenuBarSummary) -> NSImage {
        // Slots are at least two digits wide and numbers sit right-aligned, so typical changes don't shift the bar.
        let stats: [(symbol: String, text: String, minimum: String)] = [
            ("cpu", summary.cpu, "88%"),
            ("memorychip", summary.memory, "88%"),
            ("network", summary.ports, "88"),
        ]
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let appIcon = symbol(appSymbol, NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        let statConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let laidOut = stats.map { stat in
            (icon: symbol(stat.symbol, statConfig), text: attributed(stat.text, font),
             width: max(textWidth(stat.text, font), textWidth(stat.minimum, font)))
        }
        let statsWidth = laidOut.reduce(0) { $0 + $1.icon.size.width + iconTextGap + $1.width } + statGap * CGFloat(laidOut.count - 1)
        let width = ceil(appIcon.size.width + leadingGap + statsWidth)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            draw(appIcon, at: &x)
            x += leadingGap
            for (index, stat) in laidOut.enumerated() {
                if index > 0 { x += statGap }
                draw(stat.icon, at: &x)
                x += iconTextGap
                let text = stat.text
                // Center the digits' cap height on the icons.
                let baseline = ((height - font.capHeight) / 2).rounded()
                text.draw(at: NSPoint(x: x + stat.width - text.size().width, y: baseline + font.descender))
                x += stat.width
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = summary.description
        return image
    }

    private static func symbol(_ name: String, _ config: NSImage.SymbolConfiguration) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
    }

    private static func draw(_ icon: NSImage, at x: inout CGFloat) {
        let size = icon.size
        icon.draw(in: NSRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height))
        x += size.width
    }

    private static func attributed(_ text: String, _ font: NSFont) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
    }

    private static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        ceil(attributed(text, font).size().width)
    }
}
