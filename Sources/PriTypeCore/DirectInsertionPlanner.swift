import Foundation

// MARK: - KeyEventDedup
//
// Some hosts (observed: KakaoTalk) deliver the SAME physical keyDown to the IME twice,
// which makes each backspace decompose two jamo and each character double up. We drop a
// keyDown that is an exact re-delivery of the immediately-preceding one. Distinguishing a
// re-delivery from legitimate input is safe because:
//   • auto-repeat events carry isARepeat=true (a real key HOLD) — never deduped here;
//   • a human cannot tap the same key twice within 50ms;
// so only a non-repeat same-keyCode event arriving <50ms after another non-repeat
// same-keyCode event is a machine duplicate. Pure + testable.

struct KeyDownSnapshot: Equatable {
    let timestamp: TimeInterval
    let keyCode: UInt16
    let isARepeat: Bool
    var characters: String? = nil
    var modifiers: UInt = 0
}

enum KeyEventDedup {
    /// Maximum gap to treat two identical non-repeat keyDowns as one physical event.
    static let duplicateWindow: TimeInterval = 0.05

    static func isDuplicate(_ event: KeyDownSnapshot, previous: KeyDownSnapshot?) -> Bool {
        guard let previous,
              !event.isARepeat, !previous.isARepeat,
              event.keyCode == previous.keyCode,
              event.characters == previous.characters,
              event.modifiers == previous.modifiers else { return false }
        let dt = event.timestamp - previous.timestamp
        return dt >= 0 && dt < duplicateWindow
    }
}

// MARK: - DirectInsertionPlanner
//
// Pure decision logic for the experimental Windows-style direct-insertion delivery
// (Phase 3 — see Docs/KoreanWindowsInputFeasibility.md). Extracted from the adapter
// so the read-modify-write math is unit-testable without a live IMKTextInput.
//
// In direct insertion there is NO marked text: the in-progress syllable is written
// into the document as REAL text and rewritten in place on each keystroke. The
// planner computes which range of already-inserted live-preedit text to replace, and
// what the new tracked live-preedit length becomes.

/// The plan for one in-place rewrite of the live preedit.
struct DirectInsertionPlan: Equatable {
    /// Range to pass to `insertText(_:replacementRange:)`. When `bailed` is true this
    /// is `{NSNotFound, 0}` (the adapter must NOT use it; it should fall back).
    let replaceRange: NSRange
    /// The new tracked UTF-16 length of the live preedit after the rewrite.
    let newLivePreeditLength: Int
    /// True when the client's selection range was unusable (no `TSMDocumentAccess`):
    /// the adapter must fall back to marked text rather than corrupt/strand text.
    let bailed: Bool
}

enum DirectInsertionPlanner {
    /// Same sanity ceiling used elsewhere to reject Chromium's garbage range values.
    static let maxReasonableLocation = 10_000_000

    static func isUsableCollapsedSelection(_ selection: NSRange) -> Bool {
        selection.location != NSNotFound
            && selection.location >= 0
            && selection.location < maxReasonableLocation
            && selection.length == 0
    }

    /// Identity guard for a tracked real-text preedit. The exact original range and
    /// its contents must still exist, and the caret must remain immediately after it.
    /// Looking only behind the current caret is insufficient: after a move to another
    /// identical string (ABA), it would authorize overwriting unrelated text.
    /// - Parameters:
    ///   - selectionRange: the client's current selection.
    ///   - liveRange: exact document range originally written by the adapter.
    ///   - actualSubstring: the document text currently at `liveRange` (nil if unreadable).
    ///   - expectedText: the string we last wrote as the live preedit.
    static func liveRegionIsVerified(
        selectionRange: NSRange,
        liveRange: NSRange,
        actualSubstring: String?,
        expectedText: String
    ) -> Bool {
        guard liveRange.location != NSNotFound,
              liveRange.location >= 0,
              liveRange.location < maxReasonableLocation,
              liveRange.length == expectedText.utf16.count,
              isUsableCollapsedSelection(selectionRange),
              selectionRange.location == NSMaxRange(liveRange) else { return false }
        return actualSubstring == expectedText
    }

    /// Compute the rewrite plan.
    /// - Parameters:
    ///   - cursorLocation: `client.selectedRange().location` (UTF-16 offset of caret).
    ///   - livePreeditLength: UTF-16 length of the live preedit currently in the document.
    ///   - textUTF16Count: UTF-16 length of the replacement text.
    ///   - keepingLive: true when the replacement text is itself a (new) live preedit
    ///     (`setMarkedText`); false when it is a finalized commit (`insertText`) that
    ///     becomes permanent and therefore tracks length 0.
    static func plan(
        cursorLocation: Int,
        livePreeditLength: Int,
        textUTF16Count: Int,
        keepingLive: Bool
    ) -> DirectInsertionPlan {
        let newLive = keepingLive ? textUTF16Count : 0

        let safe = cursorLocation != NSNotFound
            && cursorLocation < maxReasonableLocation
            && cursorLocation >= livePreeditLength

        guard safe else {
            return DirectInsertionPlan(
                replaceRange: NSRange(location: NSNotFound, length: 0),
                newLivePreeditLength: newLive,
                bailed: true
            )
        }

        return DirectInsertionPlan(
            replaceRange: NSRange(location: cursorLocation - livePreeditLength, length: livePreeditLength),
            newLivePreeditLength: newLive,
            bailed: false
        )
    }
}
