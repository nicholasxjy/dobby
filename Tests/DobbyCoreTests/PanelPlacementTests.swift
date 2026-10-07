import CoreGraphics
import Testing
@testable import DobbyCore

/// Screen coordinates are bottom-left origin, like AppKit's.
@Suite struct PanelPlacementTests {
    let size = CGSize(width: 400, height: 580)
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1056) // visible frame, below the menu bar

    @Test func hangsCenteredBelowTheStatusItem() {
        let anchor = CGRect(x: 900, y: 1056, width: 30, height: 24)
        #expect(PanelPlacement.frame(for: size, under: anchor, within: screen) == CGRect(x: 715, y: 471, width: 400, height: 580))
    }

    @Test func staysInsideTheRightAndLeftEdges() {
        let right = PanelPlacement.frame(for: size, under: CGRect(x: 1885, y: 1056, width: 30, height: 24), within: screen)
        #expect(right.maxX == 1912)
        let left = PanelPlacement.frame(for: size, under: CGRect(x: 2, y: 1056, width: 30, height: 24), within: screen)
        #expect(left.minX == 8)
    }

    @Test func respectsSecondaryScreenOrigin() {
        let external = CGRect(x: 1920, y: 0, width: 1440, height: 875)
        let frame = PanelPlacement.frame(for: size, under: CGRect(x: 3340, y: 875, width: 30, height: 24), within: external)
        #expect(frame.maxX == external.maxX - 8)
        #expect(frame.maxY == 870)
    }

    @Test func neverHangsBelowTheScreenBottom() {
        let short = CGRect(x: 0, y: 0, width: 1280, height: 500)
        let frame = PanelPlacement.frame(for: size, under: CGRect(x: 600, y: 500, width: 30, height: 24), within: short)
        #expect(frame.minY == 0)
    }
}
