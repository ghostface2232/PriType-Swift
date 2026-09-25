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

@Suite("Hanja candidate key routing", .serialized)
struct HanjaCandidateRoutingTests {
    @Test("Candidate keys are consumed, arrows close and pass, the rest is left alone")
    func routes() {
        typealias W = HanjaCandidateWindow
        #expect(W.route(keyCode: 53, flags: [], pageCandidates: 9) == .consume(digit: nil))      // Esc
        #expect(W.route(keyCode: 36, flags: [], pageCandidates: 9) == .consume(digit: nil))      // Return
        #expect(W.route(keyCode: 125, flags: [], pageCandidates: 9) == .consume(digit: nil))     // ↓
        #expect(W.route(keyCode: 18, flags: [], pageCandidates: 9) == .consume(digit: 1))        // 1
        #expect(W.route(keyCode: 25, flags: [], pageCandidates: 9) == .consume(digit: 9))        // 9
        #expect(W.route(keyCode: 92, flags: [], pageCandidates: 9) == .consume(digit: 9))        // keypad 9
        #expect(W.route(keyCode: 123, flags: [], pageCandidates: 9) == .dismissAndPass)          // ←
        #expect(W.route(keyCode: 124, flags: [], pageCandidates: 9) == .dismissAndPass)          // →
        #expect(W.route(keyCode: 15, flags: [], pageCandidates: 9) == .ignore)                   // r
        #expect(W.route(keyCode: 18, flags: .maskShift, pageCandidates: 9) == .ignore)           // !
        #expect(W.route(keyCode: 53, flags: .maskCommand, pageCandidates: 9) == .ignore)         // ⌘Esc
    }

    @Test("A digit past the page's last candidate closes the window and reaches the app")
    func digitBeyondPagePasses() {
        typealias W = HanjaCandidateWindow
        #expect(W.route(keyCode: 20, flags: [], pageCandidates: 3) == .consume(digit: 3))    // 3
        #expect(W.route(keyCode: 21, flags: [], pageCandidates: 3) == .dismissAndPass)       // 4
        #expect(W.route(keyCode: 92, flags: [], pageCandidates: 3) == .dismissAndPass)       // keypad 9
        #expect(W.route(keyCode: 53, flags: [], pageCandidates: 3) == .consume(digit: nil))  // Esc
    }

    @Test("The event tap consumes Escape and passes the arrows only while candidates show")
    func tapRoutesOnlyWhileShowing() throws {
        let tap = RightCommandSuppressor()
        defer { HanjaCandidateWindow.setShownPageCandidates(0) }
        func keyDown(_ code: CGKeyCode) throws -> CGEvent {
            let e = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
            e.flags = []
            return e
        }
        HanjaCandidateWindow.setShownPageCandidates(9)
        #expect(tap.handleEvent(type: .keyDown, event: try keyDown(53), toggle: .defaultToggle,
                                hanja: .defaultHanja, toggleEnabled: true, excludedOverride: false) == nil)
        #expect(tap.handleEvent(type: .keyDown, event: try keyDown(123), toggle: .defaultToggle,
                                hanja: .defaultHanja, toggleEnabled: true, excludedOverride: false) != nil)
        HanjaCandidateWindow.setShownPageCandidates(0)
        #expect(tap.handleEvent(type: .keyDown, event: try keyDown(53), toggle: .defaultToggle,
                                hanja: .defaultHanja, toggleEnabled: true, excludedOverride: false) != nil)
    }
}

@Suite("Hanja candidate reading")
struct HanjaCandidateReadingTests {
    @Test("The reading shows only where the Hanja's length does not say what it replaces")
    func readingOnlyWhenLengthsDiffer() {
        func shows(_ hangul: String, _ hanja: String) -> Bool {
            HanjaCandidateWindow.showsReading(for: HanjaEntry(hangul: hangul, hanja: hanja, meaning: ""))
        }
        #expect(!shows("대한민국", "大韓民國"))
        #expect(!shows("국", "國"))
        #expect(!shows("ㅁ", "♥"), "a jamo symbol stands for its one jamo")
        #expect(shows("가가와현", "香川縣"), "five syllables replaced by three characters")
        #expect(shows("구천", "龜川洞"))
    }

    @Test("Every entry the dictionary maps other than one to one shows its reading")
    func dictionaryMismatchesShowReading() throws {
        HanjaManager.shared.loadIfNeeded()
        let mismatched = [("가가와현", "香川縣"), ("가고시마현", "鹿児島縣"), ("나가사키현", "長崎縣")]
        for (hangul, hanja) in mismatched {
            let entries = HanjaManager.shared.search(key: hangul)
            let entry = try #require(entries.first { $0.hanja == hanja }, "\(hangul) → \(hanja) is in hanja.dat")
            #expect(HanjaCandidateWindow.showsReading(for: entry))
        }
    }
}
