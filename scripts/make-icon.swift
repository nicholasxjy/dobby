// Draws Dobby's app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [output.icns] [preview.png]
// A gauge echoing the menu bar symbol, on the macOS icon grid (824pt rounded square on a 1024pt canvas).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
    let ca = a.components!, cb = b.components!
    return CGColor(srgbRed: ca[0] + (cb[0] - ca[0]) * t, green: ca[1] + (cb[1] - ca[1]) * t, blue: ca[2] + (cb[2] - ca[2]) * t, alpha: 1)
}

/// Green → yellow → red along the dial, like the usage bars in the panel.
func dialColor(_ t: CGFloat) -> CGColor {
    let stops = [color(0x34C759), color(0xFFCC00), color(0xFF9500), color(0xFF3B30)]
    let scaled = min(max(t, 0), 1) * CGFloat(stops.count - 1)
    let i = min(Int(scaled), stops.count - 2)
    return mix(stops[i], stops[i + 1], scaled - CGFloat(i))
}

func drawIcon(in ctx: CGContext) {
    // Canvas is 1024×1024, origin bottom-left.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x161B33))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: deep indigo gradient, lighter at the top.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let background = CGGradient(colorsSpace: srgb, colors: [color(0x3B4A8C), color(0x141A33)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft glow behind the dial.
    let glow = CGGradient(colorsSpace: srgb, colors: [color(0x6E8BFF, 0.28), color(0x6E8BFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0, endCenter: CGPoint(x: 512, y: 470), endRadius: 420, options: [])
    ctx.restoreGState()

    // Hairline highlight along the tile's edge.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.14))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    let center = CGPoint(x: 512, y: 450)
    let radius: CGFloat = 275
    let startAngle = CGFloat.pi * 7 / 6 // 210°, lower left
    let sweep = CGFloat.pi * 4 / 3 // 240°, clockwise to lower right
    func angle(_ t: CGFloat) -> CGFloat { startAngle - sweep * t }
    func point(_ t: CGFloat, _ r: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle(t)) * r, y: center.y + sin(angle(t)) * r)
    }

    // Track.
    ctx.setLineCap(.round)
    ctx.setLineWidth(64)
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.addArc(center: center, radius: radius, startAngle: angle(0), endAngle: angle(1), clockwise: true)
    ctx.strokePath()

    // Level: colored arc to 62%, drawn as short overlapping segments to blend the colors.
    let level: CGFloat = 0.62
    let segments = 120
    for i in 0..<segments {
        let t0 = level * CGFloat(i) / CGFloat(segments)
        let t1 = level * CGFloat(i + 1) / CGFloat(segments)
        ctx.setStrokeColor(dialColor(t1 / 0.85))
        ctx.setLineCap(i == 0 ? .round : .butt)
        ctx.addArc(center: center, radius: radius, startAngle: angle(t0), endAngle: angle(min(t1 + 0.004, level)), clockwise: true)
        ctx.strokePath()
    }

    // Tick dots inside the dial, like the menu bar symbol.
    for i in 0...8 {
        let t = CGFloat(i) / 8
        let p = point(t, radius - 92)
        ctx.setFillColor(color(0xFFFFFF, t <= level ? 0.85 : 0.35))
        ctx.fillEllipse(in: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28))
    }

    // Needle: a tapered blade from the hub toward the level.
    let a = angle(level)
    let tip = point(level, radius - 120)
    let back = CGPoint(x: center.x - cos(a) * 40, y: center.y - sin(a) * 40)
    let side = CGPoint(x: -sin(a) * 26, y: cos(a) * 26)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x000000, 0.4))
    ctx.move(to: tip)
    ctx.addLine(to: CGPoint(x: center.x + side.x, y: center.y + side.y))
    ctx.addLine(to: back)
    ctx.addLine(to: CGPoint(x: center.x - side.x, y: center.y - side.y))
    ctx.closePath()
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.fillEllipse(in: CGRect(x: center.x - 50, y: center.y - 50, width: 100, height: 100))
    ctx.restoreGState()
    ctx.setFillColor(color(0x2A3566))
    ctx.fillEllipse(in: CGRect(x: center.x - 20, y: center.y - 20, width: 40, height: 40))
}

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Could not write \(url.path)") }
}

let args = CommandLine.arguments
let output = URL(fileURLWithPath: args.count > 1 ? args[1] : "Resources/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    writePNG(render(pixels: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(render(pixels: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
if args.count > 2 {
    writePNG(render(pixels: 1024), to: URL(fileURLWithPath: args[2]))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
