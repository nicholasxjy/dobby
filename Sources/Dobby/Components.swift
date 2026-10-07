import AppKit
import DobbyCore
import SwiftUI

/// Flat, opaque colors (iStat Menus–like) instead of translucent materials.
enum Palette {
    static let background = dynamic(light: 0xF4F4F5, dark: 0x1C1C1E)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x262628)
    static let hairline = dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.09)
    static let border = dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.16)
    static let user = dynamic(light: 0x2F7CF6, dark: 0x4F93FF)
    static let system = dynamic(light: 0xE5484D, dark: 0xFF6369)
    static let memory = dynamic(light: 0x2A9D68, dark: 0x3DD68C)
    static let warning = dynamic(light: 0xDB7A06, dark: 0xFFB224)
    static let critical = system

    private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha
            )
        })
    }
}

/// Color severity for a usage value.
enum Heat {
    case normal, elevated, high

    static func forValue(_ value: Double, metric: Metric) -> Heat {
        switch metric {
        case .cpu: value >= 80 ? .high : value >= 25 ? .elevated : .normal
        case .memory: value >= Double(2 << 30) ? .high : value >= Double(512 << 20) ? .elevated : .normal
        }
    }

    var barColor: Color {
        switch self {
        case .normal: Color.secondary.opacity(0.5)
        case .elevated: Palette.warning
        case .high: Palette.critical
        }
    }

    var textColor: Color {
        switch self {
        case .normal: .primary
        case .elevated: Palette.warning
        case .high: Palette.critical
        }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1)
    }
}

struct MiniBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.hairline)
                Rectangle()
                    .fill(color)
                    .frame(width: max(geometry.size.width * min(max(fraction, 0), 1), fraction > 0 ? 1 : 0))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 1))
    }
}

/// Flat text tabs with an underline; each tab also carries its live total.
struct TabStrip: View {
    struct Item {
        let tab: ProcessMonitor.Tab
        let title: String
        let value: String
        let shortcut: KeyEquivalent
    }

    let items: [Item]
    @Binding var selection: ProcessMonitor.Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tab) { item in
                let isSelected = item.tab == selection
                Button {
                    selection = item.tab
                } label: {
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(item.value)
                                .font(.system(size: 11.5, weight: .regular).monospacedDigit())
                        }
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 33)
                        Rectangle()
                            .fill(isSelected ? Color.accentColor : .clear)
                            .frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(item.shortcut, modifiers: .command)
                .help("切换到\(item.title)（⌘\(String(item.shortcut.character))）")
            }
        }
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// Stacked area history graph, newest sample at the right edge.
struct HistoryGraph: View {
    struct Series {
        let values: [Double]
        let color: Color
    }

    /// Bottom series first; each is stacked on the ones before it.
    let series: [Series]
    let capacity: Int

    var body: some View {
        Canvas { context, size in
            for level in [0.25, 0.5, 0.75] {
                var grid = Path()
                let y = (size.height * (1 - level)).rounded() + 0.5
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(grid, with: .color(Palette.hairline), lineWidth: 1)
            }

            let count = series.map(\.values.count).min() ?? 0
            guard count > 1 else { return }
            let step = size.width / CGFloat(max(capacity - 1, 1))
            func x(_ index: Int) -> CGFloat { size.width - CGFloat(count - 1 - index) * step }
            func y(_ value: Double) -> CGFloat { size.height * (1 - CGFloat(min(max(value, 0), 1))) }

            var baseline = [Double](repeating: 0, count: count)
            for item in series {
                let values = item.values.suffix(count)
                let top = zip(baseline, values).map { $0 + $1 }

                var area = Path()
                area.move(to: CGPoint(x: x(0), y: y(baseline[0])))
                for index in 0..<count { area.addLine(to: CGPoint(x: x(index), y: y(top[index]))) }
                for index in (0..<count).reversed() { area.addLine(to: CGPoint(x: x(index), y: y(baseline[index]))) }
                area.closeSubpath()
                context.fill(area, with: .color(item.color.opacity(0.45)))

                var line = Path()
                line.move(to: CGPoint(x: x(0), y: y(top[0])))
                for index in 1..<count { line.addLine(to: CGPoint(x: x(index), y: y(top[index]))) }
                context.stroke(line, with: .color(item.color), lineWidth: 1.2)
                baseline = top
            }
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.hairline))
    }
}

/// One "● label ........ value" line of a summary column.
struct StatLine: View {
    let color: Color?
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(spacing: 5) {
            if let color {
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 7, height: 7)
            }
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(valueColor)
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }
}

/// Small flat push button; `prominent` fills it with the tint.
struct FlatButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(prominent ? Color.white : tint)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(prominent ? tint : Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(prominent ? Color.clear : Palette.border)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// The panel's outline; the window is transparent, so this clip defines its corners and shadow.
enum PanelChrome {
    static let cornerRadius: CGFloat = 18
    static let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
}

/// Reports whether the hosting window is on screen. The panel keeps its content alive between
/// openings, so onAppear/onDisappear can't be relied on to pause sampling.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return report(false) }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: window)
            }
            windowChanged(nil)
        }

        @objc private func windowChanged(_ notification: Notification?) {
            guard let window, notification?.name != NSWindow.willCloseNotification else { return report(false) }
            report(window.isVisible && window.occlusionState.contains(.visible))
        }

        private func report(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(visible)
        }
    }
}
