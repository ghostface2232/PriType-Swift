import Cocoa
import Testing
@testable import PriTypeCore
import PriTypeIMKHarness

/// Regressions for the input-correctness defects found in the 2026-09-20 review
/// (the 2026-09-20 entry in `Docs/History.md`). Each test is the behaviour the fix owes the
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

    // MARK: 2 — A key pressed before a toggle keeps the mode it was pressed in

    @Test("A toggle that reaches main first does not claim an older key still in flight")
    func toggleDoesNotOvertakeAnOlderKey() async {
        let (harness, field) = start()
        defer { harness.finish() }
        // Pressed first, still travelling host → IMK.
        let older = harness.makeEvent(keyCode: 15, characters: "r")
        harness.toggleFromKeyMonitor()
        // Let the toggle's own main-queue block run before the key lands.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        let handled = field.controller.handle(older, client: field.client)
        if !handled { field.client.performHostAction(for: older) }
        #expect(field.client.text == "ㄱ", "It was pressed in Korean mode")
    }

    @Test("A key the host hands over after a toggle keeps the mode it was pressed in")
    func keyDeliveredLateKeepsItsPressTime() async {
        let (harness, field) = start()
        defer { harness.finish() }
        // R is pressed and seen by the key monitor; the toggle follows. The host
        // hands R to IMK only after that, stamped with the time it did so.
        let pressed = harness.clock
        InputModeCoordinator.shared.notePassedKey(keyCode: 15, at: pressed)
        harness.toggleFromKeyMonitor()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        let delivered = harness.makeEvent(keyCode: 15, characters: "r")
        #expect(delivered.timestamp > pressed)
        let handled = field.controller.handle(delivered, client: field.client)
        if !handled { field.client.performHostAction(for: delivered) }
        #expect(field.client.text == "ㄱ", "It was pressed in Korean mode")
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

    @Test("A host that holds the text decomposed still gets its period")
    func decomposedHostStillSubstitutes() {
        // AppKit and Blink both hand back decomposed Hangul — which is why
        // `precomposeSyllableBeforeCursor` exists at all. There, `가 ` is three
        // UTF-16 units, not two, and a window sized for the composed form reads
        // the middle of the syllable.
        let client = FakeTextClient()
        let adapter = MarkedTextAdapter(client: client, bundleId: client.bundleID)
        client.insertText("가 ".decomposedStringWithCanonicalMapping,
                          replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(client.text.utf16.count == 3, "the host holds it decomposed")

        #expect(adapter.replaceTextBeforeCursor(length: 1, with: ". ", verifying: "가 ") == .issued)
        #expect(client.text.precomposedStringWithCanonicalMapping == "가. ")
    }

    @Test("A decomposed host's moved caret is still refused")
    func decomposedHostStillRefusesAMovedCaret() {
        // The wider window must not become a licence to edit anywhere: the text in
        // front of the caret still has to be the text the substitution was computed
        // from, whatever form the host keeps it in.
        let client = FakeTextClient()
        let adapter = MarkedTextAdapter(client: client, bundleId: client.bundleID)
        client.insertText("가 나".decomposedStringWithCanonicalMapping,
                          replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(adapter.replaceTextBeforeCursor(length: 1, with: ". ", verifying: "가 ") == .unavailable)
        #expect(client.text.precomposedStringWithCanonicalMapping == "가 나")
    }

    // MARK: 5 — Changing the delivery mode ends the composition it was rendering

    private func makeSession(_ client: FakeTextClient, _ composer: HangulComposer) -> InputSession {
        let context = ClientContext(bundleId: client.bundleID, hasTextInputCapability: true,
                                    isLikelyDesktopArea: false, documentAccessSafe: true)
        return InputSession(client: client, context: context, composer: composer)
    }

    private func key(_ code: UInt16, _ characters: String,
                     _ composer: HangulComposer, _ session: InputSession) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        _ = composer.handle(event, delegate: session.adapter)
    }

    @Test("Turning direct insertion OFF mid-syllable does not re-insert what is already there")
    func directToMarkedWhileComposing() {
        let config = ConfigurationManager.shared
        let saved = config.experimentalDirectInsertion
        defer { config.experimentalDirectInsertion = saved }
        config.experimentalDirectInsertion = true

        let composer = HangulComposer()
        let client = FakeTextClient()
        let session = makeSession(client, composer)
        key(15, "r", composer, session)
        key(40, "k", composer, session)
        #expect(client.text == "가", "direct insertion writes it as real text")

        config.experimentalDirectInsertion = false
        session.ensureAdapterMatchesPolicy()
        key(4, "h", composer, session)
        #expect(client.text == "가ㅗ")
    }

    @Test("Turning direct insertion ON mid-syllable commits the marked text first")
    func markedToDirectWhileComposing() {
        let config = ConfigurationManager.shared
        let saved = config.experimentalDirectInsertion
        defer { config.experimentalDirectInsertion = saved }
        config.experimentalDirectInsertion = false

        let composer = HangulComposer()
        let client = FakeTextClient()
        let session = makeSession(client, composer)
        key(15, "r", composer, session)
        key(40, "k", composer, session)
        #expect(client.markedText == "가")

        config.experimentalDirectInsertion = true
        session.ensureAdapterMatchesPolicy()
        #expect(client.markedText == nil, "the marked composition was committed, not abandoned")
        #expect(client.text == "가")
        key(4, "h", composer, session)
        #expect(client.text == "가ㅗ")
    }

    @Test("A delivery mode that did not change leaves the composition alone")
    func unchangedPolicyKeepsComposing() {
        let composer = HangulComposer()
        let client = FakeTextClient()
        let session = makeSession(client, composer)
        key(15, "r", composer, session)
        session.ensureAdapterMatchesPolicy()
        key(40, "k", composer, session)
        #expect(client.markedText == "가", "one syllable, still composing")
        #expect(client.text == "가")
    }

    // MARK: 6 — Input never reaches the default Debug log

    @Test("A Hanja lookup leaves neither the word nor the candidate in the default Debug log")
    func hanjaLeavesNothingInTheLog() throws {
        let lines = Lines()
        DebugLogger.emittedLineObserver = { lines.record($0) }
        defer { DebugLogger.emittedLineObserver = nil }

        let (harness, field) = start()
        defer { harness.finish() }
        harness.type(Dubeolsik.keys(for: "대한민국"))
        harness.pressHanjaKey()
        let entry = try #require(harness.candidates.entries.first)
        harness.candidates.choose(1)
        #expect(field.client.text == entry.hanja)

        let logged = lines.snapshot.joined(separator: "\n")
        #expect(!logged.contains("대한민국"), "the word looked up")
        #expect(!logged.contains(entry.hanja), "the candidate chosen")
        #expect(!logged.contains(entry.meaning), "what the candidate means")
        #expect(logged.contains("[REDACTED]"), "the sensitive path is the one that ran")
    }

    /// Collects log lines from the logger's own queue-free observer callback.
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func record(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            lines.append(line)
        }
        var snapshot: [String] {
            lock.lock(); defer { lock.unlock() }
            return lines
        }
    }
}
