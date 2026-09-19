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

    // MARK: attributes(forCharacterIndex:)

    /// A field whose firstRect fails and whose caret sits after "요한한한 ".
    private func chromeLikeField() -> FakeTextClient {
        let field = FakeTextClient(bundleID: "com.google.Chrome")
        field.insertText("요한한한 ", replacementRange: NSRange(location: NSNotFound, length: 0))
        field.caretRect = unreported
        return field
    }

    @Test("A host whose firstRect fails is asked for index 0 before its document index")
    func attributesIndexZeroFirst() {
        CursorRectResolver.lastKnownCursorRect = nil
        defer { CursorRectResolver.lastKnownCursorRect = nil }
        // Google Docs, measured: index 0 is the caret; any later index is one
        // fixed spot near the window's corner.
        let docs = chromeLikeField()
        let caret = NSRect(x: 400, y: 400, width: 1, height: 21)
        let windowCorner = NSRect(x: 200, y: 300, width: 1, height: 19)
        docs.lineRectForIndex = { $0 == 0 ? caret : windowCorner }
        #expect(CursorRectResolver.resolve(client: docs, accessibility: { nil }) == caret)
    }

    @Test("A host that answers only by document index still gets the previous character")
    func attributesDocumentIndexFallback() {
        CursorRectResolver.lastKnownCursorRect = nil
        defer { CursorRectResolver.lastKnownCursorRect = nil }
        let field = chromeLikeField()
        let previousCharacter = NSRect(x: 420, y: 400, width: 1, height: 18)
        field.lineRectForIndex = { $0 == 4 ? previousCharacter : .zero }
        #expect(CursorRectResolver.resolve(client: field, accessibility: { nil }) == previousCharacter)
    }

    // MARK: Accessibility coordinates
    //
    // The layout reported with the bug: a MacBook's built-in display is primary
    // (1710×1112), and a 2560×1440 external display sits above it. In
    // Accessibility coordinates (top-left of the primary, y down) the external
    // display spans y -1440…0.

    private let builtIn = NSRect(x: 0, y: 0, width: 1710, height: 1112)
    private let external = NSRect(x: 232, y: 1112, width: 2560, height: 1440)

    @Test("A caret on a display above the primary one converts onto that display")
    func caretAbovePrimary() {
        let caret = CursorRectResolver.appKitRect(
            fromAX: CGRect(x: 800, y: -700, width: 2, height: 20), primaryHeight: builtIn.height)
        #expect(caret == NSRect(x: 800, y: 1792, width: 2, height: 20))
        #expect(external.contains(caret.origin))
        #expect(CursorRectResolver.isValidCursorRect(caret, screens: [builtIn, external]))
    }

    @Test("Chromium's y-only bounds place the caret on a display above the primary one")
    func chromiumPartialAbovePrimary() throws {
        let caret = try #require(CursorRectResolver.chromiumPartialCaret(
            CGRect(x: 0, y: -700, width: 0, height: 0), elementX: 600, primaryHeight: builtIn.height))
        #expect(caret == NSRect(x: 600, y: 1794, width: 0, height: 18))
        #expect(CursorRectResolver.isValidCursorRect(caret, screens: [builtIn, external]))
    }

    @Test("Chromium's y-only bounds still work on the primary display")
    func chromiumPartialOnPrimary() throws {
        let caret = try #require(CursorRectResolver.chromiumPartialCaret(
            CGRect(x: 0, y: 500, width: 0, height: 0), elementX: 300, primaryHeight: builtIn.height))
        #expect(caret == NSRect(x: 300, y: 594, width: 0, height: 18))
        #expect(builtIn.contains(caret.origin))
    }

    @Test("Bounds without a y, or with a size, are not Chromium's partial answer")
    func notChromiumPartial() {
        let height = builtIn.height
        #expect(CursorRectResolver.chromiumPartialCaret(.zero, elementX: 300, primaryHeight: height) == nil)
        #expect(CursorRectResolver.chromiumPartialCaret(
            CGRect(x: 0, y: 0.5, width: 0, height: 0), elementX: 300, primaryHeight: height) == nil)
        #expect(CursorRectResolver.chromiumPartialCaret(
            CGRect(x: 10, y: 500, width: 2, height: 20), elementX: 300, primaryHeight: height) == nil)
    }
}
