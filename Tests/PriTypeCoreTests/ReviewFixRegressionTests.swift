import Cocoa
import Testing
@testable import PriTypeCore
import PriTypeIMKHarness

/// Regressions for the input-correctness defects found in the 2026-09-20 review
/// (`Docs/CodeReview-2026-09-20.md`). Each test is the behaviour the fix owes the
/// user, phrased the way the user meets it: what they typed, what the document
/// holds afterwards.
///
/// Serialized and synchronous on main, like the rest of the IMK harness tests:
/// every controller shares one composer.
@Suite("Review fixes 2026-09-20", .serialized)
@MainActor
struct ReviewFixRegressionTests {

    private func start() -> (IMKHarness, IMKHarness.Field) {
        PriTypeInputController.resetSystemModeTracking()
        let harness = IMKHarness()
        let field = harness.makeField()
        harness.focus(field)
        return (harness, field)
    }

    // MARK: 1 — A fast second press of the same key is a second press

    @Test("Two presses of one key 30 ms apart both arrive")
    func rapidRepeatedKeySurvives() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.keyInterval = 0.03
        harness.type("rr")
        harness.click()
        #expect(field.client.text == "ㄱㄱ")
    }

    @Test("A fast repeated Backspace deletes twice")
    func rapidRepeatedBackspace() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type(Dubeolsik.keys(for: "가나다"))
        harness.click()
        #expect(field.client.text == "가나다")
        harness.keyInterval = 0.01
        harness.press(.backspace)
        harness.press(.backspace)
        #expect(field.client.text == "가", "Both backspaces are real presses, 10 ms apart")
    }

    @Test("The same event delivered twice is still handled once")
    func exactRedeliveryIsStillSuppressed() {
        let (harness, field) = start()
        defer { harness.finish() }
        // One physical press, handed to the input method twice — the very same
        // event, so the very same timestamp. This is the KakaoTalk case.
        let event = harness.makeEvent(keyCode: 15, characters: "r")
        #expect(field.controller.handle(event, client: field.client))
        #expect(field.controller.handle(event, client: field.client))
        harness.click()
        #expect(field.client.text == "ㄱ")
    }
    // MARK: 3 — The double-space substitution edits the space it meant to edit

    @Test("A space typed after the caret moved back does not eat the character before it")
    func doubleSpaceAfterSilentCaretMove() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("rk ")
        #expect(field.client.text == "가 ")
        // A click with nothing marked: IMK tells the input method nothing.
        field.client.placeCaret(at: 1)
        harness.press(.space)
        #expect(field.client.text == "가  ", "가 is still there, and the space was typed")
    }

    @Test("An undisturbed double space still becomes a period")
    func doubleSpaceStillWorks() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("rk  ")
        #expect(field.client.text == "가. ")
    }
    // MARK: 4 — A space the substitution cannot make is still a space

    @Test("A host that reports no caret gets the space, not nothing")
    func noSpaceLostWhenTheCaretIsUnavailable() {
        let convenience = TextConvenienceHandler(isDoubleSpacePeriodEnabled: { true })
        let client = FakeTextClient()
        let adapter = MarkedTextAdapter(client: client, bundleId: client.bundleID)
        var buffer = "가"
        _ = convenience.handleDoubleSpacePeriod(buffer: &buffer, delegate: adapter)
        buffer += " "
        client.select(NSRange(location: NSNotFound, length: 0))
        #expect(convenience.handleDoubleSpacePeriod(buffer: &buffer, delegate: adapter) == .normalSpace)
    }

    @Test("Chromium's garbage caret is not a licence to edit")
    func garbageCaretIsUnavailable() {
        let client = FakeTextClient()
        let adapter = MarkedTextAdapter(client: client, bundleId: client.bundleID)
        client.insertText("가 ", replacementRange: NSRange(location: NSNotFound, length: 0))
        client.select(NSRange(location: 99_999_999, length: 0))
        #expect(adapter.replaceTextBeforeCursor(length: 1, with: ". ", verifying: "가 ") == .unavailable)
        #expect(client.text == "가 ")
    }

    @Test("A selection is not a caret, and is not replaced")
    func selectionIsUnavailable() {
        let client = FakeTextClient()
        let adapter = MarkedTextAdapter(client: client, bundleId: client.bundleID)
        client.insertText("가 ", replacementRange: NSRange(location: NSNotFound, length: 0))
        client.select(NSRange(location: 0, length: 2))
        #expect(adapter.replaceTextBeforeCursor(length: 1, with: ". ", verifying: "가 ") == .unavailable)
        #expect(client.text == "가 ")
    }

    @Test("The confirmed target is replaced")
    func confirmedTargetIsReplaced() {
        let client = FakeTextClient()
        let adapter = MarkedTextAdapter(client: client, bundleId: client.bundleID)
        client.insertText("가 ", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(adapter.replaceTextBeforeCursor(length: 1, with: ". ", verifying: "가 ") == .issued)
        #expect(client.text == "가. ")
    }
}
