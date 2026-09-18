import Testing
import Cocoa
import InputMethodKit
@testable import PriTypeCore

// MARK: - Direct Insertion (Phase 3, experimental) Tests
//
// Validates the Windows-style direct-insertion delivery logic without a live
// IMKTextInput: the pure DirectInsertionPlanner, the commit-before-mark ordering the
// model relies on, and an end-to-end simulation through a fake client that applies the
// same plan the real DirectInsertionAdapter would.

@Suite("DirectInsertionPlanner")
struct DirectInsertionPlannerTests {

    @Test("Preedit update replaces the live region and tracks new length")
    func preeditUpdate() {
        // cursor at 5, live preedit "가가" (2 utf16) -> replace {3,2} with new preedit "각" (1)
        let plan = DirectInsertionPlanner.plan(
            cursorLocation: 5, livePreeditLength: 2, textUTF16Count: 1, keepingLive: true)
        #expect(!plan.bailed)
        #expect(plan.replaceRange == NSRange(location: 3, length: 2))
        #expect(plan.newLivePreeditLength == 1)
    }

    @Test("Commit replaces the live region and resets tracked length to 0")
    func commitFinalizes() {
        let plan = DirectInsertionPlanner.plan(
            cursorLocation: 5, livePreeditLength: 2, textUTF16Count: 2, keepingLive: false)
        #expect(!plan.bailed)
        #expect(plan.replaceRange == NSRange(location: 3, length: 2))
        #expect(plan.newLivePreeditLength == 0, "Committed text is permanent, not live")
    }

    @Test("First keystroke (no live preedit) inserts at cursor")
    func firstKeystroke() {
        let plan = DirectInsertionPlanner.plan(
            cursorLocation: 0, livePreeditLength: 0, textUTF16Count: 1, keepingLive: true)
        #expect(!plan.bailed)
        #expect(plan.replaceRange == NSRange(location: 0, length: 0))
        #expect(plan.newLivePreeditLength == 1)
    }

    @Test("Bails on NSNotFound cursor (no document access)")
    func bailsOnNSNotFound() {
        let plan = DirectInsertionPlanner.plan(
            cursorLocation: NSNotFound, livePreeditLength: 1, textUTF16Count: 1, keepingLive: true)
        #expect(plan.bailed)
        #expect(plan.replaceRange.location == NSNotFound)
    }

    @Test("Bails on Chromium-garbage cursor location")
    func bailsOnGarbage() {
        let plan = DirectInsertionPlanner.plan(
            cursorLocation: 20_000_000, livePreeditLength: 1, textUTF16Count: 1, keepingLive: true)
        #expect(plan.bailed)
    }

    @Test("Bails when live length exceeds cursor (would delete real text)")
    func bailsWhenLiveExceedsCursor() {
        let plan = DirectInsertionPlanner.plan(
            cursorLocation: 0, livePreeditLength: 2, textUTF16Count: 1, keepingLive: true)
        #expect(plan.bailed, "Cannot delete 2 chars when caret is at 0")
    }
}

// MARK: - Caret-stability guard (prevents click/arrow corruption)

@Suite("DirectInsertion caret-stability guard")
struct DirectInsertionStabilityTests {

    @Test("No tracking ⇒ always safe")
    func nothingTracked() {
        #expect(DirectInsertionPlanner.isUsableCollapsedSelection(NSRange(location: 5, length: 0)))
    }

    @Test("Read-back matches the tracked preedit ⇒ verified")
    func matchVerified() {
        // doc "...가", caret right after the live "가" (len 1), read-back == "가"
        #expect(DirectInsertionPlanner.liveRegionIsVerified(
            selectionRange: NSRange(location: 3, length: 0),
            liveRange: NSRange(location: 2, length: 1),
            actualSubstring: "가", expectedText: "가"))
    }

    @Test("Caret moved to an identical string (ABA) ⇒ NOT verified")
    func forwardMoveRejected() {
        // The text behind the new caret is also "가", but it is not the exact range
        // originally written by the adapter.
        #expect(!DirectInsertionPlanner.liveRegionIsVerified(
            selectionRange: NSRange(location: 5, length: 0),
            liveRange: NSRange(location: 2, length: 1),
            actualSubstring: "가", expectedText: "가"))
    }

    @Test("Caret moved BEFORE the live region (cursor < len) ⇒ NOT verified")
    func backwardMoveRejected() {
        #expect(!DirectInsertionPlanner.liveRegionIsVerified(
            selectionRange: NSRange(location: 0, length: 0),
            liveRange: NSRange(location: 2, length: 1),
            actualSubstring: "가", expectedText: "가"))
    }

    @Test("Unreadable region (nil) ⇒ NOT verified")
    func unreadableRejected() {
        #expect(!DirectInsertionPlanner.liveRegionIsVerified(
            selectionRange: NSRange(location: 3, length: 0),
            liveRange: NSRange(location: 2, length: 1),
            actualSubstring: nil, expectedText: "가"))
    }

    @Test("NSNotFound / garbage caret ⇒ NOT verified")
    func garbageCaretRejected() {
        #expect(!DirectInsertionPlanner.liveRegionIsVerified(
            selectionRange: NSRange(location: NSNotFound, length: 0),
            liveRange: NSRange(location: 2, length: 1),
            actualSubstring: "가", expectedText: "가"))
        #expect(!DirectInsertionPlanner.liveRegionIsVerified(
            selectionRange: NSRange(location: 20_000_000, length: 0),
            liveRange: NSRange(location: 2, length: 1),
            actualSubstring: "가", expectedText: "가"))
    }
}

// MARK: - Adapter/session integration with a fake IMKTextInput

final class FakeIMKTextInput: NSObject, IMKTextInput {
    private(set) var document: String
    private(set) var markedText = ""
    private(set) var insertCalls: [(String, NSRange)] = []
    var selection: NSRange

    init(document: String = "") {
        self.document = document
        self.selection = NSRange(location: document.utf16.count, length: 0)
    }

    func replaceDocument(_ text: String, selection: NSRange) {
        document = text
        self.selection = selection
    }

    func insertText(_ string: Any!, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        insertCalls.append((text, replacementRange))

        if replacementRange.location == NSNotFound {
            // Canonical marked-text commit. The fake keeps marked text outside the
            // real document until this operation, then inserts it at the caret. When
            // the host selection is invalid, append deterministically for assertions.
            let location = selection.location == NSNotFound ? document.utf16.count : selection.location
            replaceUTF16(range: NSRange(location: location, length: 0), with: text)
            markedText = ""
        } else {
            replaceUTF16(range: replacementRange, with: text)
        }
    }

    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }

    func selectedRange() -> NSRange { selection }
    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count)
    }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= document.utf16.count else { return nil }
        let units = Array(document.utf16)[range.location..<NSMaxRange(range)]
        return NSAttributedString(string: String(decoding: units, as: UTF16.self))
    }
    func length() -> Int { document.utf16.count }
    func characterIndex(
        for point: NSPoint,
        tracking mappingMode: IMKLocationToOffsetMappingMode,
        inMarkedRange: UnsafeMutablePointer<ObjCBool>?
    ) -> Int { NSNotFound }
    func attributes(
        forCharacterIndex index: Int,
        lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>?
    ) -> [AnyHashable: Any]? { nil }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
    func selectMode(_ modeIdentifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String! { "com.nousresearch.hermes" }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { true }
    func uniqueClientIdentifierString() -> String! { "fake-imk-client" }
    func string(from range: NSRange, actualRange: NSRangePointer?) -> String! {
        actualRange?.pointee = range
        return attributedSubstring(from: range)?.string
    }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        return .zero
    }

    private func replaceUTF16(range: NSRange, with text: String) {
        var units = Array(document.utf16)
        guard range.location >= 0, NSMaxRange(range) <= units.count else { return }
        units.replaceSubrange(range.location..<NSMaxRange(range), with: text.utf16)
        document = String(decoding: units, as: UTF16.self)
        selection = NSRange(location: range.location + text.utf16.count, length: 0)
    }
}

@Suite("Direct insertion session state")
struct DirectInsertionSessionTests {
    private func makeSession() -> (HangulComposer, FakeIMKTextInput, InputSession) {
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let client = FakeIMKTextInput()
        let context = ClientContext(
            bundleId: "com.nousresearch.hermes",
            hasTextInputCapability: true,
            isLikelyDesktopArea: false,
            documentAccessSafe: true
        )
        return (composer, client, InputSession(client: client, context: context, composer: composer))
    }

    @Test("Backspace decomposition stops at the committed boundary")
    func backspaceStopsAtCommittedBoundary() {
        // Exercised against the REAL DirectInsertionAdapter (not a mock mirror),
        // so the adapter's live-range tracking and state machine are covered.
        let (composer, client, session) = makeSession()
        #expect(session.adapter is DirectInsertionAdapter)

        // Commit 가 with a space, then start a fresh syllable on top of it.
        for (char, code): (String, UInt16) in [("r", 15), ("k", 40)] {
            _ = composer.handle(TestEventFactory.keyEvent(char: char, keyCode: code)!, delegate: session.adapter)
        }
        _ = composer.handle(TestEventFactory.keyEvent(char: " ", keyCode: KeyCode.space)!, delegate: session.adapter)
        let committed = client.document
        #expect(committed == "가 ", "setup produced '\(committed)'")

        let callsAfterCommit = client.insertCalls.count
        for (char, code): (String, UInt16) in [("s", 1), ("k", 40)] {  // ㄴ, 나
            _ = composer.handle(TestEventFactory.keyEvent(char: char, keyCode: code)!, delegate: session.adapter)
        }
        #expect(client.document == committed + "나")

        // Decompose the live syllable away. The committed prefix must survive, and
        // the adapter must only ever rewrite its own tracked live range — any write
        // reaching further back would show up as a replacement spanning it.
        #expect(composer.handle(TestEventFactory.keyEvent(char: "\u{7F}", keyCode: KeyCode.backspace)!, delegate: session.adapter))
        #expect(client.document == committed + "ㄴ", "got '\(client.document)'")
        #expect(composer.handle(TestEventFactory.keyEvent(char: "\u{7F}", keyCode: KeyCode.backspace)!, delegate: session.adapter))
        #expect(client.document == committed, "preedit removal must not eat committed text; got '\(client.document)'")
        #expect(!composer.hasActiveComposition)

        // Every write the adapter made after the commit must start at or after the
        // committed boundary. A destructive implementation that deleted committed
        // text would land a replacement range reaching in front of it — the
        // assertion the previous mock-based version could not actually make.
        let writesDuringComposition = client.insertCalls.dropFirst(callsAfterCommit)
        #expect(!writesDuringComposition.isEmpty, "adapter performed no writes")
        for (text, range) in writesDuringComposition {
            #expect(range.location != NSNotFound,
                    "direct insertion must target an explicit range, wrote '\(text)'")
            #expect(range.location >= committed.utf16.count,
                    "write '\(text)' at \(range) reached into committed text")
        }

        // With no preedit left the key passes through to the host rather than
        // PriType deleting committed text itself.
        #expect(!composer.handle(TestEventFactory.keyEvent(char: "\u{7F}", keyCode: KeyCode.backspace)!, delegate: session.adapter))
        #expect(client.document == committed, "got '\(client.document)'")
    }

    @Test("Invalid selection commits old real text and finalizes fallback on mode/focus changes")
    func invalidSelectionFallbackFinalize() {
        for reason in [CompositionFinalizeReason.modeTransition, .appDeactivate] {
            let (composer, client, session) = makeSession()
            _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: session.adapter)
            #expect(client.document == "ㄱ")
            #expect(session.adapter is DirectInsertionAdapter)

            client.selection = NSRange(location: NSNotFound, length: 0)
            session.prepareForInput()
            _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: session.adapter)

            #expect(client.document == "ㄱ", "The previous real preedit must remain committed exactly once")
            #expect(client.markedText == "ㅏ", "The current key must start a fresh marked fallback")
            #expect(session.finalize(reason: reason))
            #expect(client.document == "ㄱㅏ", "Finalization must commit marked fallback instead of dropping it")
            #expect(client.markedText.isEmpty)
        }
    }

    @Test("Caret move to identical text never rewrites the ABA location")
    func identicalTextCaretMove() {
        let (composer, client, session) = makeSession()
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: session.adapter)
        #expect(client.document == "ㄱ")

        client.replaceDocument("ㄱxㄱ", selection: NSRange(location: 3, length: 0))
        session.prepareForInput()
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: session.adapter)

        #expect(client.document == "ㄱxㄱㅏ")
        #expect(!client.document.contains("가"), "The identical text at the new caret is not the live range")
    }

    @Test("Direct-live focus finalization does not duplicate real text")
    func directLiveFinalize() {
        let (composer, client, session) = makeSession()
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: session.adapter)

        #expect(session.finalize(reason: .appDeactivate))
        #expect(client.document == "ㄱ")
        #expect(client.insertCalls.count == 1)
    }
}

// MARK: - Electron/Chromium denylist (direct insertion physically impossible)

@Suite("DirectInsertion denylist")
struct DirectInsertionDenylistTests {

    @Test("Electron / browser hosts are denied")
    func electronDenied() {
        for id in [
            "com.anthropic.claudefordesktop",
            "com.microsoft.VSCode",
            "com.tinyspeck.slackmacgap",
            "com.google.Chrome",
            "org.mozilla.firefox",
            "com.apple.Safari"
        ] {
            #expect(ClientCompatibilityPolicy.directInsertionDenied(bundleId: id), "should deny \(id)")
        }
    }

    @Test("Keyword heuristic catches unlisted Electron/Chromium wrappers")
    func keywordHeuristic() {
        #expect(ClientCompatibilityPolicy.directInsertionDenied(bundleId: "com.example.MyElectronApp"))
        #expect(ClientCompatibilityPolicy.directInsertionDenied(bundleId: "org.chromium.Chromium"))
        #expect(ClientCompatibilityPolicy.directInsertionDenied(bundleId: "com.vendor.someChromeThing"))
    }

    @Test("Native AppKit hosts are NOT denied")
    func nativeAllowed() {
        for id in [
            "com.kakao.KakaoTalkMac",
            "com.apple.Notes",
            "com.apple.TextEdit",
            "com.apple.dt.Xcode"
        ] {
            #expect(!ClientCompatibilityPolicy.directInsertionDenied(bundleId: id), "should allow \(id)")
        }
    }
}

// MARK: - Duplicate keyDown suppression

@Suite("KeyEventDedup")
struct KeyEventDedupTests {
    private func snap(_ t: TimeInterval, _ code: UInt16, _ repeat_: Bool = false) -> KeyDownSnapshot {
        KeyDownSnapshot(timestamp: t, keyCode: code, isARepeat: repeat_)
    }

    @Test("Exact re-delivery (same timestamp, same key) is a duplicate")
    func exactDuplicate() {
        #expect(KeyEventDedup.isDuplicate(snap(100.0, 51), previous: snap(100.0, 51)))
    }

    @Test("Re-delivery within the window is a duplicate")
    func withinWindow() {
        #expect(KeyEventDedup.isDuplicate(snap(100.02, 51), previous: snap(100.0, 51)))
    }

    @Test("Outside the window is NOT a duplicate (human double-tap)")
    func outsideWindow() {
        #expect(!KeyEventDedup.isDuplicate(snap(100.2, 51), previous: snap(100.0, 51)))
    }

    @Test("Different keyCode is never a duplicate (fast typing)")
    func differentKey() {
        #expect(!KeyEventDedup.isDuplicate(snap(100.01, 40), previous: snap(100.0, 51)))
    }

    @Test("Auto-repeat events are never treated as duplicates")
    func autoRepeatExempt() {
        // new is a repeat
        #expect(!KeyEventDedup.isDuplicate(snap(100.01, 51, true), previous: snap(100.0, 51, false)))
        // previous was a repeat (held key)
        #expect(!KeyEventDedup.isDuplicate(snap(100.01, 51, false), previous: snap(100.0, 51, true)))
    }

    @Test("Different characters or modifiers survive the dedup window")
    func differentInput() {
        let previous = KeyDownSnapshot(timestamp: 100, keyCode: 0, isARepeat: false, characters: "a", modifiers: 0)
        let shifted = KeyDownSnapshot(timestamp: 100.01, keyCode: 0, isARepeat: false, characters: "A", modifiers: 0x20000)
        #expect(!KeyEventDedup.isDuplicate(shifted, previous: previous))
    }

    @Test("No previous event ⇒ not a duplicate")
    func noPrevious() {
        #expect(!KeyEventDedup.isDuplicate(snap(100.0, 51), previous: nil))
    }
}

// MARK: - Commit-before-mark ordering invariant (marked-text mode)

@Suite("Commit-before-mark ordering")
struct CommitBeforeMarkOrderingTests {

    /// On a syllable boundary (받침 migration), the previous syllable must be
    /// committed via insertText BEFORE the new syllable is shown via setMarkedText.
    /// This is the load-bearing invariant for both the Windows-feel marked path and
    /// the experimental direct-insertion path.
    @Test("받침 migration commits previous syllable before marking the new one")
    func migrationOrdering() {
        let statusBar = MockStatusBar()
        let composer = HangulComposer(statusBar: statusBar, configuration: MockConfiguration())
        let delegate = MockComposerDelegate()

        // Type 안 (ㅇ ㅏ ㄴ)
        _ = composer.handle(TestEventFactory.keyEvent(char: "d", keyCode: 2)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "s", keyCode: 1)!, delegate: delegate)

        // Reset the call log, then trigger migration with ㅏ: 안 + ㅏ -> 아 + 나
        delegate.orderedCalls = []
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: delegate)

        #expect(delegate.orderedCalls == ["insert:아", "mark:나"],
                "Expected commit(아) before mark(나), got \(delegate.orderedCalls)")
    }
}

// MARK: - End-to-end direct insertion simulation

/// Models a text field under direct insertion: maintains real document text + the
/// live-preedit length, applying the SAME DirectInsertionPlanner the real
/// DirectInsertionAdapter uses, with the caret pinned at end-of-document.
final class FakeDirectInsertionClient: HangulComposerDelegate {
    private(set) var document = ""
    private var livePreeditLength = 0

    private func rewrite(_ text: String, keepingLive: Bool) {
        let cursor = document.utf16.count
        let plan = DirectInsertionPlanner.plan(
            cursorLocation: cursor,
            livePreeditLength: livePreeditLength,
            textUTF16Count: text.utf16.count,
            keepingLive: keepingLive)
        guard !plan.bailed else { return }
        var units = Array(document.utf16)
        let start = plan.replaceRange.location
        let end = start + plan.replaceRange.length
        units.replaceSubrange(start..<end, with: Array(text.utf16))
        document = String(decoding: units, as: UTF16.self)
        livePreeditLength = plan.newLivePreeditLength
    }

    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        rewrite(text, keepingLive: false)
    }
    func setMarkedText(_ text: String) {
        rewrite(text, keepingLive: true)
    }
    func textBeforeCursor(length: Int) -> String? { nil }
    func replaceTextBeforeCursor(length: Int, with text: String) {
        livePreeditLength = 0
        var units = Array(document.utf16)
        guard units.count >= length else { return }
        units.removeLast(length)
        units.append(contentsOf: Array(text.utf16))
        document = String(decoding: units, as: UTF16.self)
    }
}

@Suite("Direct insertion end-to-end")
struct DirectInsertionEndToEndTests {

    private func makeComposer() -> (HangulComposer, FakeDirectInsertionClient) {
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        return (composer, FakeDirectInsertionClient())
    }

    @Test("받침 migration + space produces clean real text with no duplication")
    func migrationThenSpace() {
        let (composer, client) = makeComposer()
        // 안 + ㅏ -> 아 나, then space commits the live 나
        for (char, code): (String, UInt16) in [("d", 2), ("k", 40), ("s", 1), ("k", 40)] {
            _ = composer.handle(TestEventFactory.keyEvent(char: char, keyCode: code)!, delegate: client)
        }
        #expect(client.document == "아나", "Got '\(client.document)'")

        _ = composer.handle(TestEventFactory.keyEvent(char: " ", keyCode: KeyCode.space)!, delegate: client)
        #expect(client.document == "아나 ", "Space must not duplicate the live syllable; got '\(client.document)'")
    }

    @Test("Escape removes the in-progress syllable that was written as real text")
    func escapeRemovesLivePreedit() {
        let (composer, client) = makeComposer()
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: client) // ㄱ
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: client) // 가
        #expect(client.document == "가")

        _ = composer.handle(TestEventFactory.keyEvent(char: "\u{1B}", keyCode: KeyCode.escape)!, delegate: client)
        #expect(client.document == "", "Escape must delete the live preedit; got '\(client.document)'")
    }

    @Test("Backspace decomposes the live syllable in place")
    func backspaceDecomposes() {
        let (composer, client) = makeComposer()
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: client) // ㄱ
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: client) // 가
        #expect(client.document == "가")

        _ = composer.handle(TestEventFactory.keyEvent(char: "\u{7F}", keyCode: KeyCode.backspace)!, delegate: client)
        #expect(client.document == "ㄱ", "Backspace should leave ㄱ in place; got '\(client.document)'")
    }

    @Test("Two committed syllables accumulate correctly")
    func twoSyllables() {
        let (composer, client) = makeComposer()
        // 가 (r,k) space 나 (s,k)  -> "가 나"
        for (char, code): (String, UInt16) in [("r", 15), ("k", 40)] {
            _ = composer.handle(TestEventFactory.keyEvent(char: char, keyCode: code)!, delegate: client)
        }
        _ = composer.handle(TestEventFactory.keyEvent(char: " ", keyCode: KeyCode.space)!, delegate: client)
        for (char, code): (String, UInt16) in [("s", 1), ("k", 40)] {
            _ = composer.handle(TestEventFactory.keyEvent(char: char, keyCode: code)!, delegate: client)
        }
        #expect(client.document == "가 나", "Got '\(client.document)'")
    }
}

@Suite("Legacy client focus recovery")
struct LegacyClientFocusRecoveryTests {
    @Test("Empty supported attributes survive activation and repeated context refresh")
    func reactivationKeepsKoreanWorking() {
        let client = FakeIMKTextInput()
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let session = InputSession(client: client,
            context: ClientContextDetector.analyzeForActivation(client: client), composer: composer)
        #expect(session.context.bundleId == client.bundleIdentifier())
        for _ in 0..<3 {
            session.markContextStale()
            session.refreshContext(ClientContextDetector.analyze(client: client))
            #expect(!session.context.hasTextInputCapability)
            #expect(!SecureInputPolicy.shouldPassThrough(SecureInputSignals(
                bundleId: session.context.bundleId,
                hasTextInputCapability: session.context.hasTextInputCapability,
                hasInvalidSelection: false, hasGlobalSecureInput: false)))
            composer.setInputMode(.english)
            composer.setInputMode(.korean)
            #expect(composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: session.adapter))
            #expect(composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: session.adapter))
            #expect(composer.hasActiveComposition)
            session.finalize(reason: .deactivateServer)
        }
        #expect(client.document == "가가가")
    }
}
