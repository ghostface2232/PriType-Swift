import Cocoa
import Testing
@testable import PriTypeCore
import PriTypeIMKHarness

/// Where the Hanja candidates open when a client cannot report its caret.
/// Serialized: the resolver remembers the last position in static state.
@Suite("Cursor rect resolution", .serialized)
@MainActor
struct CursorRectResolverTests {
    private let unreported = NSRect.zero

    @Test("A client that cannot report its caret gets its own last position")
    func sameClientReusesItsPosition() {
        CursorRectResolver.lastKnownCursorRect = nil
        defer { CursorRectResolver.lastKnownCursorRect = nil }
        let docs = FakeTextClient(bundleID: "com.google.Chrome")
        let caret = docs.caretRect
        #expect(CursorRectResolver.resolve(client: docs, accessibility: { nil }) == caret)
        docs.caretRect = unreported
        #expect(CursorRectResolver.resolve(client: docs, accessibility: { nil }) == caret)
    }

    @Test("Another client's last position is never used")
    func otherClientsPositionIsNotReused() {
        CursorRectResolver.lastKnownCursorRect = nil
        defer { CursorRectResolver.lastKnownCursorRect = nil }
        // TextEdit on the built-in display answered; then Docs, on the other
        // display, cannot. The candidates must not open at TextEdit's caret.
        let textEdit = FakeTextClient(bundleID: "com.apple.TextEdit")
        let textEditCaret = textEdit.caretRect
        _ = CursorRectResolver.resolve(client: textEdit, accessibility: { nil })

        let docs = FakeTextClient(bundleID: "com.google.Chrome")
        docs.caretRect = unreported
        let fromAccessibility = NSRect(x: 900, y: 1800, width: 2, height: 20)
        #expect(CursorRectResolver.resolve(client: docs, accessibility: { fromAccessibility }) == fromAccessibility)

        CursorRectResolver.lastKnownCursorRect = (ObjectIdentifier(textEdit), textEditCaret)
        #expect(CursorRectResolver.resolve(client: docs, accessibility: { nil }) != textEditCaret,
                "with nothing else, the mouse beats another client's caret")
    }
}
