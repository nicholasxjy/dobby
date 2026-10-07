import CoreGraphics

/// Where the menu bar panel goes: centered under its status item, kept inside the screen's visible frame.
public enum PanelPlacement {
    public static func frame(
        for size: CGSize,
        under anchor: CGRect,
        within bounds: CGRect,
        gap: CGFloat = 5,
        margin: CGFloat = 8
    ) -> CGRect {
        let x = min(max(anchor.midX - size.width / 2, bounds.minX + margin), bounds.maxX - margin - size.width)
        let y = max(anchor.minY - gap - size.height, bounds.minY)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
