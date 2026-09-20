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
}
