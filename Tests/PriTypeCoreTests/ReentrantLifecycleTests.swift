import Cocoa
import Testing
@testable import PriTypeCore
import PriTypeIMKHarness

/// IMK delivering `deactivateServer`/`activateServer` while `handle()` is inside a
/// synchronous call into the host. Observed on macOS 27 (2026-09-24): a key typed
/// right after clicking into TextEdit got both nested inside `insertText("한")`,
/// and 한글 came out as 한ㅡㄹ.
@Suite("Re-entrant IMK lifecycle calls", .serialized)
@MainActor
struct ReentrantLifecycleTests {
    private func start(bundleID: String = "com.pritype.imk-harness") -> (IMKHarness, IMKHarness.Field) {
        PriTypeInputController.resetSystemModeTracking()
        let harness = IMKHarness()
        let field = harness.makeField(bundleID: bundleID)
        harness.focus(field)
        return (harness, field)
    }

    @Test("A deactivation and reactivation nested in the commit keep the next jamo")
    func churnInsideCommit() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("gks")
        harness.churnFocus(of: field, during: .insertText)
        harness.type("rmf")
        #expect(field.client.text == "한글", "not 한ㅡㄹ")
        #expect(field.client.markedText == "글")
        #expect(!field.client.calls.contains { if case .dropped = $0 { return true } else { return false } },
                "nothing is sent while the host is not taking edits")
    }

    @Test("A reactivation that arrives after the key marks the syllable the host dropped")
    func reactivationAfterKey() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("gks")
        harness.churnFocus(of: field, during: .insertText, nestedActivation: false)
        harness.type("r")
        #expect(field.client.calls.last == .dropped("ㄱ"), "the host was not taking edits")
        #expect(field.client.text == "한")
        harness.completeActivation(field)
        #expect(field.client.markedText == "ㄱ")
        harness.type("mf")
        #expect(field.client.text == "한글")
    }

    @Test("A key for the same field before any reactivation carries on the composition")
    func keyBeforeReactivation() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("gks")
        harness.churnFocus(of: field, during: .insertText, nestedActivation: false)
        harness.type("r")
        field.client.ignoresEdits = false   // the host is back, IMK never says so
        harness.type("mf")
        #expect(field.client.text == "한글")
        #expect(field.client.markedText == "글")
    }

    @Test("With no reactivation, the held deactivation commits the syllable the host still shows")
    func heldDeactivationTimesOut() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("gks")
        harness.churnFocus(of: field, during: .insertText, nestedActivation: false, dropsEdits: false)
        harness.type("r")
        #expect(field.client.markedText == "ㄱ")
        harness.runDeferredDeactivations()
        #expect(field.client.text == "한ㄱ")
        #expect(field.client.markedText == nil)
        #expect(!PriTypeInputController.sharedComposer.hasActiveComposition)
    }

    @Test("A syllable the host kept on resigning is not committed a second time")
    func heldDeactivationHostKeptSyllable() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("gk")
        harness.churnFocus(of: field, during: .setMarkedText, nestedActivation: false)
        harness.type("s")                  // 한 is marked, then focus really leaves
        field.client.unmarkText()          // the host resigns, keeping it as text
        field.client.ignoresEdits = false  // a duplicate would now land
        field.client.clearLog()
        harness.runDeferredDeactivations()
        #expect(field.client.text == "한", "not 한한")
        #expect(field.client.calls.isEmpty)
        #expect(!PriTypeInputController.sharedComposer.hasActiveComposition)
    }

    @Test("A syllable a resigned host dropped does not follow focus to the next field")
    func heldDeactivationHostDroppedSyllable() {
        let (harness, first) = start()
        defer { harness.finish() }
        harness.type("gks")
        harness.churnFocus(of: first, during: .insertText, nestedActivation: false)
        harness.type("r")                  // the host takes no edits from here on
        harness.runDeferredDeactivations()
        // Nothing reaches a host that stopped taking edits when the deactivation
        // arrived; a prompt commit would have been dropped the same way.
        #expect(first.client.text == "한")
        #expect(!PriTypeInputController.sharedComposer.hasActiveComposition)
        let second = harness.makeField(bundleID: "com.pritype.imk-harness.other")
        harness.activateAhead(second)
        harness.type("rk")
        #expect(second.client.text == "가")
    }

    @Test("A field switch behind the same client leaves the old composition out of the new field")
    func fieldSwitchBehindSameClient() {
        let (harness, field) = start()
        defer { harness.finish() }
        field.client.insertText("메모 ", replacementRange: NSRange(location: NSNotFound, length: 0))
        harness.type("gks")
        harness.switchField(of: field, to: "검색", during: .insertText)
        harness.type("r")                  // 한 commits into 메모, then focus moves
        #expect(field.client.text == "검색", "the ㄱ typed in 메모 stays out of 검색")
        #expect(field.client.markedText == nil)
        #expect(!PriTypeInputController.sharedComposer.hasActiveComposition)
        harness.type("rk")
        #expect(field.client.text == "검색가")
    }

    @Test("A field switch behind the same client, seen by the next key, also drops the old composition")
    func fieldSwitchSeenByNextKey() {
        let (harness, field) = start()
        defer { harness.finish() }
        field.client.insertText("메모 ", replacementRange: NSRange(location: NSNotFound, length: 0))
        harness.type("gks")
        harness.churnFocus(of: field, during: .insertText, nestedActivation: false)
        harness.type("r")
        field.client.ignoresEdits = false
        field.client.showOtherField("검색")
        harness.type("k")
        #expect(field.client.text == "검색ㅏ", "not 검색가 from the ㄱ typed in 메모")
    }

    @Test("A real focus change nested in the commit finishes the key, then commits into the old field")
    func nestedFocusChange() {
        let (harness, first) = start()
        defer { harness.finish() }
        let second = harness.makeField(bundleID: "com.pritype.imk-harness.other")
        harness.type("gks")
        harness.moveFocus(from: first, to: second, during: .insertText)
        harness.type("r")
        #expect(first.client.text == "한ㄱ")
        #expect(first.client.markedText == nil)
        #expect(second.client.text.isEmpty)
        harness.type("rk")
        #expect(second.client.markedText == "가")
        #expect(first.client.text == "한ㄱ")
    }

    @Test("A syllable the host committed itself during the churn is not typed twice")
    func hostCommittedDuringChurn() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("g")
        harness.churnFocus(of: field, during: .setMarkedText, nestedActivation: false)
        harness.type("k")
        field.client.ignoresEdits = false
        field.client.unmarkText()
        harness.completeActivation(field)
        #expect(field.client.text == "하")
        #expect(field.client.markedText == nil)
        harness.type("s")
        #expect(field.client.text == "하ㄴ", "not 하하ㄴ")
    }

    @Test("A syllable the host dropped is marked again, even after the same syllable")
    func hostDroppedSameSyllable() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("rkr")
        harness.churnFocus(of: field, during: .setMarkedText, nestedActivation: false)
        harness.type("k")                  // commits 가, marks the second 가
        field.client.ignoresEdits = false
        field.client.discardMarkedText()
        #expect(field.client.text == "가")
        harness.completeActivation(field)
        #expect(field.client.text == "가가")
        #expect(field.client.markedText == "가")
    }

    @Test("Text already before the caret is not mistaken for a syllable the host committed")
    func existingTextIsNotTheSyllable() {
        let (harness, field) = start()
        defer { harness.finish() }
        field.client.insertText("가", replacementRange: NSRange(location: NSNotFound, length: 0))
        harness.type("r")
        harness.churnFocus(of: field, during: .setMarkedText, nestedActivation: false)
        harness.type("k")                  // marks 가 after the 가 already there
        field.client.ignoresEdits = false
        field.client.discardMarkedText()
        harness.completeActivation(field)
        #expect(field.client.text == "가가")
        #expect(field.client.markedText == "가")
    }

    @Test("A churn inside the first key's context analysis keeps one session (direct insertion)")
    func churnInsideAnalysisDirectInsertion() {
        let (harness, field) = start(bundleID: "com.nousresearch.hermes")
        defer { harness.finish() }
        // The analysis asks for the attributes only under a Secure Input warning.
        field.client.reportsGlobalSecureInput = true
        harness.churnFocus(of: field, during: .validAttributes)
        harness.type("gks")
        #expect(field.client.attributeQueries > 0, "the churn ran inside the analysis")
        #expect(field.client.text == "한", "not ㅎ한 from a second session's adapter")
        harness.type("rmf")
        #expect(field.client.text == "한글")
    }

    @Test("A churn inside the first key's context analysis composes normally (marked text)")
    func churnInsideAnalysisMarkedText() {
        let (harness, field) = start()
        defer { harness.finish() }
        field.client.reportsGlobalSecureInput = true
        harness.churnFocus(of: field, during: .validAttributes)
        harness.type("gksrmf")
        #expect(field.client.attributeQueries > 0, "the churn ran inside the analysis")
        #expect(field.client.text == "한글")
        #expect(field.client.markedText == "글")
    }
}
