import AppKit
import DobbyCore
import SwiftUI

/// Flat, opaque colors (iStat Menus–like) instead of translucent materials.
enum Palette {
    static let background = dynamic(light: 0xF4F4F6, dark: 0x1E1E20)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x2A2A2D)
    /// The details card floats above the list.
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x303034)
    static let hairline = dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.08)
    static let border = dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.14)
    static let fill = dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.06)
    static let hover = dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.05)
    static let track = dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.09)
    static let neutralBar = dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.30)
    static let user = dynamic(light: 0x2F7CF6, dark: 0x4F93FF)
    static let system = dynamic(light: 0xE5484D, dark: 0xFF6369)
    static let memory = dynamic(light: 0x2A9D68, dark: 0x3DD68C)
    /// Orange for text; darker in light mode so small text stays readable.
    static let warning = dynamic(light: 0xA85800, dark: 0xFFB224)
    /// Orange for bars, dots and fills.
    static let warningFill = dynamic(light: 0xE08A1E, dark: 0xFFB224)
    static let warningSoft = dynamic(light: 0xDB7A06, dark: 0xFFB224, alpha: 0.13)
    static let critical = dynamic(light: 0xC8292F, dark: 0xFF6369)
    static let criticalSoft = dynamic(light: 0xE5484D, dark: 0xFF6369, alpha: 0.13)
    static let accentSoft = Color.accentColor.opacity(0.13)

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
        case .normal: Palette.neutralBar
        case .elevated: Palette.warningFill
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

/// A fixed-width usage bar; no GeometryReader, so it stays cheap in long lists.
struct MiniBar: View {
    let fraction: Double
    let color: Color
    var track: Color = Palette.track
    var width: CGFloat = 32

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        Capsule()
            .fill(track)
            .frame(width: width, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(color).frame(width: clamped > 0 ? max(width * clamped, 3) : 0, height: 4)
            }
    }
}

/// Segments of a whole (user + system CPU, LAN + local ports) as one thin bar.
struct SegmentedMeter: View {
    struct Segment {
        let fraction: Double
        let color: Color
    }

    let segments: [Segment]

    var body: some View {
        Canvas { context, size in
            context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.track))
            var x: CGFloat = 0
            for segment in segments {
                let width = size.width * CGFloat(min(max(segment.fraction, 0), 1))
                context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(segment.color))
                x += width
            }
        }
        .frame(height: 4)
    }
}

/// One of the three headline tiles that double as the view switcher.
struct VitalTile: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String
    var detailColor: Color = .secondary
    let segments: [SegmentedMeter.Segment]
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                    Text(title)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                Text(value)
                    .font(.system(size: 19, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                SegmentedMeter(segments: segments)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.surface)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.border))
                        .elevated(cornerRadius: 9)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A small rounded label: "Admin helper on", "Paused", "LAN".
struct Badge: View {
    let text: String
    var symbol: String?
    var foreground: Color = .secondary
    var background: Color = Palette.fill

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)) }
            Text(text)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background(Capsule().fill(background))
        .fixedSize()
    }
}

/// A shortcut key drawn as a keycap in the footer hints.
struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(height: 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(Palette.fill))
    }
}

/// A segmented control drawn flat: the chosen segment is a raised white pill.
struct PillSegments<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var symbol: String?
        var isBusy = false
    }

    let options: [Option]
    let selection: Value
    var height: CGFloat = 28
    var fillsWidth = false
    let select: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    select(option.value)
                } label: {
                    HStack(spacing: 4) {
                        if option.isBusy {
                            ProgressView().controlSize(.mini)
                        } else if let symbol = option.symbol {
                            Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
                        }
                        Text(option.title)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 9)
                    .frame(maxWidth: fillsWidth ? .infinity : nil, maxHeight: .infinity)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Palette.surface)
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.hairline))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 7).fill(Palette.fill))
    }
}

extension View {
    /// A soft drop shadow made of offset, unblurred layers. Blurred `.shadow` needs offscreen buffers
    /// (about 18 MB for the panel), which a menu bar utility shouldn't spend on looks.
    func elevated(cornerRadius: CGFloat, depth: CGFloat = 1) -> some View {
        background {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius + 1, style: .continuous)
                    .fill(Color.black.opacity(0.035))
                    .padding(-1)
                    .offset(y: 2 * depth)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.05))
                    .offset(y: depth)
            }
        }
    }
}

/// Plain icon or text button that dims while pressed. (No hover tint: `@State` is a macro that the
/// Command Line Tools can't expand, and this project builds without Xcode.)
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Rectangle())
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
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.hairline))
    }
}

/// Small flat push button; `prominent` fills it with the tint.
struct FlatButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? Color.white : tint)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(prominent ? tint : Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(prominent ? Color.clear : Palette.border)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// The panel's outline; the window is transparent, so this clip defines its corners and shadow.
enum PanelChrome {
    static let cornerRadius: CGFloat = 14
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
