import Cocoa
import Testing
@testable import PriTypeCore

@Suite("Hanja panel position")
struct HanjaPanelPositionTests {
    let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    let panel = NSSize(width: 320, height: 200)

    @Test("Below the line and right of the syllable, clear of both")
    func belowAndRight() {
        let caret = NSRect(x: 500, y: 600, width: 17, height: 23)
        let origin = HanjaCandidateWindow.panelOrigin(caret: caret, panelSize: panel, visibleFrame: screen)
        #expect(origin.x == caret.maxX + HanjaCandidateWindow.horizontalGap)
        #expect(!NSRect(origin: origin, size: panel).intersects(caret))
    }

    @Test("Clears the drawn text when the reported rect sits one line above it")
    func clearsShiftedGlyph() {
        // Measured in Notes: reported y 1874–1897, text drawn about one glyph
        // height lower. The panel must cover neither.
        let reported = NSRect(x: 1571, y: 1874, width: 17, height: 23)
        let drawn = reported.offsetBy(dx: 0, dy: -reported.height)
        let dell = NSRect(x: 232, y: 1112, width: 2560, height: 1440)
        let origin = HanjaCandidateWindow.panelOrigin(caret: reported, panelSize: panel, visibleFrame: dell)
        let frame = NSRect(origin: origin, size: panel)
        #expect(!frame.intersects(drawn))
        #expect(!frame.intersects(reported))
        #expect(frame.maxY == drawn.minY - HanjaCandidateWindow.verticalGap)
    }

    @Test("No room below flips above the line without covering it")
    func flipsAbove() {
        let caret = NSRect(x: 500, y: 100, width: 17, height: 23)
        let origin = HanjaCandidateWindow.panelOrigin(caret: caret, panelSize: panel, visibleFrame: screen)
        #expect(origin.y == caret.maxY + HanjaCandidateWindow.verticalGap)
        let frame = NSRect(origin: origin, size: panel)
        #expect(!frame.intersects(caret))
        #expect(!frame.intersects(caret.offsetBy(dx: 0, dy: -caret.height)))
    }

    @Test("Clamped to the right edge of the screen")
    func clampsRight() {
        let caret = NSRect(x: 1900, y: 600, width: 17, height: 23)
        let origin = HanjaCandidateWindow.panelOrigin(caret: caret, panelSize: panel, visibleFrame: screen)
        #expect(origin.x + panel.width == screen.maxX)
    }

    @Test("Works on a display with negative coordinates")
    func negativeDisplay() {
        let left = NSRect(x: -2560, y: 0, width: 2560, height: 1440)
        let caret = NSRect(x: -1200, y: 700, width: 17, height: 23)
        let origin = HanjaCandidateWindow.panelOrigin(caret: caret, panelSize: panel, visibleFrame: left)
        #expect(origin.x == caret.maxX + HanjaCandidateWindow.horizontalGap)
        #expect(left.contains(NSRect(origin: origin, size: panel)))
    }
}
