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

// MARK: - The Accessibility chain's time budget

/// The caret the Hanja window opens at is resolved through a chain of synchronous
/// Accessibility round trips, on the main thread every app's typing runs through.
/// A per-call timeout bounds one call; the chain makes up to seven.
@Suite("Accessibility time budget")
struct AXDeadlineTests {
    private typealias Deadline = CursorRectResolver.AXDeadline
    private let perCall = CursorRectResolver.accessibilityTimeout

    @Test("A fresh budget gives the first call its full per-call timeout")
    func fullBudgetGivesThePerCallLimit() {
        let deadline = Deadline(budget: 1.0, now: 100)
        #expect(deadline.nextTimeout(perCall: perCall, now: 100) == perCall)
    }

    @Test("A call late in the chain gets only what is left, not the per-call limit")
    func lateCallsGetWhatRemains() {
        let deadline = Deadline(budget: 1.0, now: 100)
        // 0.8s of the budget already spent by earlier calls.
        #expect(deadline.nextTimeout(perCall: perCall, now: 100.8) == Float(0.2))
    }

    @Test("A spent budget makes no further calls")
    func spentBudgetStopsTheChain() {
        let deadline = Deadline(budget: 1.0, now: 100)
        #expect(deadline.nextTimeout(perCall: perCall, now: 101.0) == nil)
        #expect(deadline.nextTimeout(perCall: perCall, now: 105.0) == nil)
    }

    @Test("What is left never rounds down to the framework's default")
    func neverHandsOutZero() {
        let deadline = Deadline(budget: 1.0, now: 100)
        // AXUIElementSetMessagingTimeout reads 0 as "use the default" — about six
        // seconds, the very thing the budget exists to prevent. A sliver of budget
        // must end the chain rather than buy one unbounded call.
        #expect(deadline.nextTimeout(perCall: perCall, now: 100.999) == nil)
        for spent in stride(from: 0.0, through: 1.2, by: 0.001) {
            if let timeout = deadline.nextTimeout(perCall: perCall, now: 100 + spent) {
                #expect(timeout >= Deadline.minimumTimeout, "handed out \(timeout) after \(spent)s")
                #expect(timeout <= perCall)
            }
        }
    }

    @Test("Seven calls at the per-call limit cannot outlast the budget")
    func theChainCannotAddUpPastTheBudget() {
        // The chain's longest path: systemWide focus, focused app, its focused
        // element, selected range, bounds for range, position, size.
        let deadline = Deadline(budget: CursorRectResolver.accessibilityBudget, now: 100)
        var now: TimeInterval = 100
        var spent: TimeInterval = 0
        var calls = 0
        while let timeout = deadline.nextTimeout(perCall: perCall, now: now), calls < 7 {
            // Every call is a host that never answers, so each one costs its timeout.
            spent += TimeInterval(timeout)
            now += TimeInterval(timeout)
            calls += 1
        }
        #expect(spent <= CursorRectResolver.accessibilityBudget,
                "a hung host cost \(spent)s over \(calls) calls")
        #expect(spent < 7 * TimeInterval(perCall), "which is what per-call limits alone allowed")
    }
}
