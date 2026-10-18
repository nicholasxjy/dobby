// Draws Dobby's app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [output.icns] [preview.png]
// The panel in miniature, on the macOS icon grid (824pt rounded square on a 1024pt canvas).
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

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// A smooth curve through `points` (Catmull-Rom as cubic Béziers).
func smoothPath(through points: [CGPoint]) -> CGMutablePath {
    let path = CGMutablePath()
    path.move(to: points[0])
    for i in 0..<points.count - 1 {
        let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
        path.addCurve(
            to: p2,
            control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
            control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        )
    }
    return path
}

/// The panel in miniature: a white card on the accent blue, with the three vitals meters
/// (CPU user + system, memory, LAN + local ports) above a stacked CPU history graph.
func drawIcon(in ctx: CGContext) {
    // Canvas is 1024×1024, origin bottom-left; the tile follows the macOS icon grid.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = roundedRect(tile, 185)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.30))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x1F5FD6))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: the panel's accent blue, lighter at the top.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let background = CGGradient(colorsSpace: srgb, colors: [color(0x4D94FF), color(0x1A4FC4)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(roundedRect(tile.insetBy(dx: 2, dy: 2), 183))
    ctx.setStrokeColor(color(0xFFFFFF, 0.22))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    // The card.
    let card = CGRect(x: 214, y: 236, width: 596, height: 552)
    let cardPath = roundedRect(card, 76)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x0B2A6B, 0.45))
    ctx.addPath(cardPath)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Meters, like the tiles' segmented bars: CPU user + system, memory, LAN + local ports.
    let barX = card.minX + 64
    let barWidth = card.width - 128
    let barHeight: CGFloat = 42
    let meters: [[(CGFloat, CGColor)]] = [
        [(0.40, color(0x2F7CF6)), (0.17, color(0xE5484D))],
        [(0.66, color(0x2A9D68))],
        [(0.28, color(0xF08A12)), (0.40, color(0xC3C7D0))],
    ]
    for (row, segments) in meters.enumerated() {
        let y = card.maxY - 86 - CGFloat(row) * 72
        let track = CGRect(x: barX, y: y - barHeight / 2, width: barWidth, height: barHeight)
        ctx.saveGState()
        ctx.addPath(roundedRect(track, barHeight / 2))
        ctx.clip()
        ctx.setFillColor(color(0xE8EAF0))
        ctx.fill(track)
        var x = track.minX
        for (fraction, fill) in segments {
            let width = barWidth * fraction
            ctx.setFillColor(fill)
            ctx.fill(CGRect(x: x, y: track.minY, width: width, height: barHeight))
            x += width
        }
        ctx.restoreGState()
    }

    // History graph in the card's lower part, drawn like the panel's: tinted areas, solid lines, grid.
    let graph = CGRect(x: card.minX, y: card.minY, width: card.width, height: 262)
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()
    ctx.setFillColor(color(0xF3F5F9))
    ctx.fill(graph)
    ctx.setFillColor(color(0xDDE1E9))
    ctx.fill(CGRect(x: graph.minX, y: graph.maxY - 3, width: graph.width, height: 3))
    for level in [CGFloat(1) / 3, CGFloat(2) / 3] {
        ctx.fill(CGRect(x: graph.minX, y: graph.minY + graph.height * level - 1.5, width: graph.width, height: 3))
    }

    let total: [CGFloat] = [0.34, 0.40, 0.31, 0.46, 0.38, 0.52, 0.80, 0.50, 0.42, 0.55, 0.44, 0.58, 0.47]
    let user = total.map { $0 * 0.66 }
    func points(_ values: [CGFloat]) -> [CGPoint] {
        values.enumerated().map { i, v in
            CGPoint(x: graph.minX - 10 + CGFloat(i) / CGFloat(values.count - 1) * (graph.width + 20), y: graph.minY + graph.height * v)
        }
    }
    // Opaque tints (the line color over the graph background) so user covers system like a stacked graph.
    for (values, hex, tint) in [(total, UInt32(0xE5484D), UInt32(0xF5C6C9)), (user, UInt32(0x2F7CF6), UInt32(0xC4DAFD))] {
        let line = smoothPath(through: points(values))
        let area = line.mutableCopy()!
        area.addLine(to: CGPoint(x: graph.maxX + 10, y: graph.minY))
        area.addLine(to: CGPoint(x: graph.minX - 10, y: graph.minY))
        area.closeSubpath()
        ctx.addPath(area)
        ctx.setFillColor(color(tint))
        ctx.fillPath()
        ctx.addPath(line)
        ctx.setStrokeColor(color(hex))
        ctx.setLineWidth(12)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }
    ctx.restoreGState()
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
