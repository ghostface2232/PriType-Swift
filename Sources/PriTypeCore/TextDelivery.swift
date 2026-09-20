import Cocoa
import InputMethodKit

// MARK: - InputDeliveryMode

/// How composition output reaches the focused client.
enum InputDeliveryMode: Equatable {
    case immediate          // Finder desktop: defer, no marked window
    case directInsertion    // EXPERIMENTAL: real-text in-place rewrite
    case markedText         // Default: canonical marked-text composition
}

// MARK: - TextDeliveryPolicy

/// Single decision point for how composition is delivered to a client.
///
/// Default is canonical marked text. Direct insertion (experimental) is attempted in
/// every app when the flag is ON (and always for Hermes) — there is no per-app
/// allowlist. Two gates remain: the activation probe `documentAccessSafe` (apps that
/// cannot report a usable selection range, e.g. terminals, physically cannot do
/// in-place rewrites) and the Electron/browser denylist in `ClientCompatibilityPolicy`
/// (their selection reports lag the document). Both keep the marked-text path. Apps that pass the probe but misbehave at runtime degrade to
/// marked text via the adapter's caret-stability guard / bail path — so enabling it
/// everywhere never corrupts text, it just falls back where it can't work.
enum TextDeliveryPolicy {
    static func mode(for context: ClientContext) -> InputDeliveryMode {
        if context.shouldUseImmediateMode {
            return .immediate
        }
        let wantsDirectInsertion = ConfigurationManager.shared.experimentalDirectInsertion
            || ClientCompatibilityPolicy.prefersDirectInsertionForComposition(bundleId: context.bundleId)
        if wantsDirectInsertion,
           context.documentAccessSafe,
           !ClientCompatibilityPolicy.directInsertionDenied(bundleId: context.bundleId) {
            return .directInsertion
        }
        return .markedText
    }

    static func makeAdapter(for client: IMKTextInput, context: ClientContext) -> BaseClientAdapter {
        switch mode(for: context) {
        case .immediate:
            return ImmediateModeAdapter(client: client, bundleId: context.bundleId)
        case .directInsertion:
            DebugLogger.log("TextDeliveryPolicy: DirectInsertionAdapter (experimental) for \(context.bundleId)")
            return DirectInsertionAdapter(client: client, bundleId: context.bundleId)
        case .markedText:
            return MarkedTextAdapter(client: client, bundleId: context.bundleId)
        }
    }
}

// MARK: - PreeditUnderline

/// Marked-text attributes chosen to make the composition underline invisible
/// WHERE THE OS STILL HONORS IME ATTRIBUTES (the underline is pure decoration;
/// the marked range and commit semantics are untouched either way).
///
/// ⚠️ TRANSPORT REALITY on macOS 26 (measured 2026-06 with an NSTextInputClient
/// probe on the live IMK path, enumerating every payload we can send): underline
/// style 0 + `.clear`, single + alpha-1/255, `NSMarkedClauseSegment` 1…9 (every
/// TSM hilite category incl. kNoHilite), and even an attribute-LESS string ALL
/// arrive at the client as the same regenerated pair `NSUnderline=2 + accent
/// blue`. The receiving framework discards IME-provided styling and synthesizes
/// the system marked-text style — distinct categories that carry distinct styles
/// in `IMKInputController.mark(forStyle:at:)` dictionaries (e.g. style 3 → gray
/// U=3, style 4 → gray U=1) arrive indistinguishable, so the channel is fully
/// dead, not merely quantized. On macOS 26 NO setMarkedText attributes can hide
/// the composition underline, for any IME (Apple's Korean IME draws the same
/// underline). The only underline-free composition is to not use marked text at
/// all — `DirectInsertionAdapter` via `experimentalDirectInsertion`.
///
/// On older macOS the attributes pass through, and there no single set hides the
/// underline in every renderer — verified against the engine sources (Chromium
/// `render_widget_host_view_cocoa.mm` + `styleable_marker_painter.cc`, WebKit
/// `WebViewImpl.mm` + `TextBoxPainter.cpp`):
///
///                          AppKit      WebKit(Safari)   Blink(Chromium/Electron)
///   style 0                hidden      VISIBLE¹         VISIBLE (thin black)
///   style 1 + .clear       hidden      hidden²          VISIBLE (text color)³
///   style 1 + alpha 1/255  hidden      VISIBLE¹         hidden (painted at 0.4%)
///
/// ¹ WebKit/Blink check only the attribute's PRESENCE; the 0 value is ignored, and a
///   non-clear color is repainted in the system accent color by modern WebKit.
/// ² WebKit special-cases exactly `NSColor.clear` at extraction, and an alpha-0 color
///   is also skipped at paint (`Color::isVisible()`), so clear is doubly safe there.
/// ³ Blink substitutes the TEXT color for a fully transparent underline
///   (`StyleableMarker::UseTextColor`) — clear makes the underline VISIBLE there;
///   alpha 1/255 fails the exact-transparent compare and paints imperceptibly.
///
/// Omitting the attribute entirely is worse everywhere it matters: AppKit applies
/// its default marked-text style (underline) and WebKit falls back to an opaque
/// yellow composition highlight. Hence: always send the attribute, engine-tuned.
enum PreeditUnderline {
    static func attributes(forBundleId bundleId: String) -> [NSAttributedString.Key: Any] {
        switch ClientCompatibilityPolicy.compositionRenderer(bundleId: bundleId) {
        case .blink:
            return [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1.0 / 255.0)
            ]
        case .system:
            return [
                .underlineStyle: 0,
                .underlineColor: NSColor.clear
            ]
        }
    }
}

// MARK: - BaseClientAdapter

/// Base adapter class with common IMKTextInput operations
/// Subclasses override setMarkedText for different behaviors
class BaseClientAdapter: NSObject, HangulComposerDelegate {
    let client: IMKTextInput

    /// Host bundle id, for engine-tuned preedit styling.
    let bundleId: String

    /// Engine-tuned attributes for the composition preedit (effective only on
    /// macOS versions that honor IME attributes — see `PreeditUnderline`).
    let preeditAttributes: [NSAttributedString.Key: Any]

    /// The delivery mode this adapter implements. Used by `InputSession` to detect
    /// when the resolved policy no longer matches the live adapter (e.g. the
    /// experimental flag flipped mid-session) and the adapter must be rebuilt.
    var deliveryMode: InputDeliveryMode { .markedText }

    /// The last decomposed-syllable rewrite: where it happened and what it wrote.
    /// The NEXT Backspace finding that same syllable still ending at that same
    /// caret means the host applied neither the rewrite nor the delete that
    /// followed it: either its selection report lags (Chromium/Electron) or it
    /// ignored the replacement range and undid our insert itself. Rewriting again
    /// would re-insert text the host just deleted, so that Backspace is left to
    /// the host, which deletes a jamo as before.
    ///
    /// Only an immediately consecutive Backspace may be suppressed this way, and
    /// anything that moves the caret without a keystroke clears this, so a caret
    /// that merely comes back to the same offset still gets its rewrite.
    private var lastPrecomposed: (caret: Int, syllable: String)?

    /// How many rewrites in a row this host has been seen not to apply. A host
    /// that ignores replacement ranges edits at the caret instead and then deletes
    /// what it just inserted, so every rewrite is wasted AND swallows its
    /// Backspace. Two in a row stop the rewrite for this field: Backspace goes
    /// straight to the host, exactly as it did before this feature existed. A
    /// rewrite the host did apply clears the count, so a host that lagged once in
    /// a long editing session keeps its rewrites.
    private var unappliedRewrites = 0

    /// The refusal this host keeps repeating, and how many times in a row. Google
    /// Docs answers every query with "one character selected at offset 0" and an
    /// empty document, whatever the real caret is: it draws its own text and shows
    /// the input method an empty shell. Asking it again can never help, so the
    /// identical refusal, repeated, ends the questions for this field. Selections
    /// being deleted move with the text, so ordinary editing never looks like it.
    private var repeatedUnusableSelection: (range: NSRange, count: Int)?

    /// Whether the rewrite has given up on this field.
    private var precomposeIsHopeless: Bool {
        unappliedRewrites >= Self.unappliedRewriteLimit
            || (repeatedUnusableSelection?.count ?? 0) >= Self.unusableSelectionLimit
    }

    /// Two in a row are a pattern; one is a single slow moment in a healthy host.
    private static let unappliedRewriteLimit = 2

    /// The same unusable caret three times running is the host's fixed answer.
    private static let unusableSelectionLimit = 3

    /// Whether the caret sits right after text this input method wrote. Everything
    /// it writes is precomposed (`CompositionHelpers.convertAndNormalize`), so the
    /// character before the caret cannot be a decomposed syllable and the host need
    /// not be asked at all — which covers the most common Backspace of all, the one
    /// that undoes what was just typed. One Backspace consumes it: what stands
    /// before the deleted character is unknown again.
    ///
    /// Every write goes through `noteOwnOutput()`, and everything that moves the
    /// caret through `forgetLastPrecomposedSyllable()` — a key the composer sees, a
    /// click, a focus change. A caret moved with none of those (dropped text, a
    /// paste from the menu bar, a host moving its own caret) leaves this set, and
    /// costs that one Backspace its rewrite; the next one behaves again.
    private var caretFollowsOwnOutput = false

    init(client: IMKTextInput, bundleId: String) {
        self.client = client
        self.bundleId = bundleId
        self.preeditAttributes = PreeditUnderline.attributes(forBundleId: bundleId)
    }

    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        // Canonical IMK commit: pass NSNotFound so the host replaces the current
        // marked text automatically. This matches Apple's own input methods and is
        // what native hosts (e.g. KakaoTalk) expect. Passing an explicit marked
        // range here desynced KakaoTalk's composition (stranded marked text +
        // missing commit on focus loss).
        noteOwnOutput()
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }

    func setMarkedText(_ text: String) {
        // Default: no-op, subclasses override
    }

    func textBeforeCursor(length: Int) -> String? {
        let selRange = client.selectedRange()
        guard selRange.location != NSNotFound, selRange.location < 10000000 else { return nil } // Protect against Chromium garbage values

        let location = max(0, selRange.location - length)
        let actualLength = selRange.location - location
        guard actualLength > 0 else { return "" }

        let charRange = NSRange(location: location, length: actualLength)
        return client.attributedSubstring(from: charRange)?.string
    }

    /// Rewrite committed text the host still holds, after confirming it is there.
    ///
    /// Committed text carries no marked range, so IMK tells the input method nothing
    /// when the caret leaves it. The only thing that can stand in for that is the
    /// host's own answer, taken immediately before the edit: a collapsed caret, and
    /// the expected `context` still sitting in front of it. A host that answers with
    /// no caret, or with text that is not the text this edit was computed from, gets
    /// no edit at all — the caller inserts what the user actually typed instead.
    @discardableResult
    func replaceTextBeforeCursor(length: Int, with text: String, verifying context: String) -> TextReplacementResult {
        let contextLength = context.utf16.count
        guard length > 0, contextLength >= length else { return .unavailable }

        let selRange = client.selectedRange()
        guard DirectInsertionPlanner.isUsableCollapsedSelection(selRange),
              selRange.location >= contextLength else { return .unavailable }

        let contextRange = NSRange(location: selRange.location - contextLength, length: contextLength)
        // Unreadable is not the same as unchanged. A host that cannot show what it
        // holds cannot authorize an edit to it either.
        guard let actual = client.attributedSubstring(from: contextRange)?.string,
              actual.precomposedStringWithCanonicalMapping
                  == context.precomposedStringWithCanonicalMapping else {
            return .unavailable
        }

        let replacementRange = NSRange(location: selRange.location - length, length: length)
        noteOwnOutput()
        client.insertText(text, replacementRange: replacementRange)
        return .issued
    }

    /// Record that the caret now follows text this input method just wrote.
    /// EVERY write to the client from an adapter goes through here.
    func noteOwnOutput() {
        lastPrecomposed = nil
        caretFollowsOwnOutput = true
    }

    func forgetLastPrecomposedSyllable() {
        lastPrecomposed = nil
        caretFollowsOwnOutput = false
    }

    /// Give this host's rewrites another chance, and forget where the caret was.
    /// Called whenever the field may have changed: a click, a focus change, a
    /// composition finalized from outside the keystroke path.
    func resumePrecomposing() {
        unappliedRewrites = 0
        repeatedUnusableSelection = nil
        forgetLastPrecomposedSyllable()
    }

    /// Count a refusal, and say so once when the host is written off.
    private func noteRefusedCaret(_ selRange: NSRange) {
        if let repeated = repeatedUnusableSelection, repeated.range == selRange {
            repeatedUnusableSelection = (selRange, repeated.count + 1)
        } else {
            repeatedUnusableSelection = (selRange, 1)
        }
        if precomposeIsHopeless {
            DebugLogger.log("Precompose: \(bundleId) reports no usable caret; asking it no more")
        }
    }

    func precomposeSyllableBeforeCursor(followsBackspace: Bool) {
        guard !precomposeIsHopeless else { return }
        let previous = lastPrecomposed
        lastPrecomposed = nil

        // Deleting this input method's own output needs no questions asked.
        if caretFollowsOwnOutput {
            caretFollowsOwnOutput = false
            return
        }

        let selRange = client.selectedRange()

        // A host that cannot answer says so the same way every time. A caret that
        // is merely too close to the start of the document, or a selection being
        // deleted, is a real answer — counting those would switch the rewrite off
        // in a healthy host, for instance while holding Backspace to clear a field.
        let isRefusal = selRange.location == NSNotFound
            || selRange.location >= DirectInsertionPlanner.maxReasonableLocation
            || selRange.length > 0
        if isRefusal {
            noteRefusedCaret(selRange)
            return
        }
        repeatedUnusableSelection = nil

        // A selection is deleted whole; only a caret deletes by character.
        guard selRange.location >= 2 else { return }

        // Four units: a syllable of three jamo and the one before it.
        let start = max(0, selRange.location - 4)
        let range = NSRange(location: start, length: selRange.location - start)
        guard let before = client.attributedSubstring(from: range)?.string,
              before.utf16.count == range.length,
              let (length, syllable) = CompositionHelpers.decomposedSyllableSuffix(of: before) else { return }

        // The same syllable still ending at the same caret, one Backspace later:
        // the host took neither the rewrite nor the delete, so leave this one to it.
        // The memory stays armed: a host whose report lags by several events would
        // otherwise look untouched again on the NEXT Backspace and be rewritten —
        // re-inserting, at a stale range, text the host has already deleted.
        if followsBackspace, previous?.caret == selRange.location, previous?.syllable == syllable {
            lastPrecomposed = previous
            unappliedRewrites += 1
            if precomposeIsHopeless {
                DebugLogger.log("Precompose: \(bundleId) kept none of its rewrites; leaving Backspace alone")
            }
            return
        }

        // A rewrite the host applied takes the whole syllable with it, so the caret
        // comes back at least two units earlier. A host that dropped the rewrite and
        // deleted one jamo instead leaves it exactly one unit earlier, which is no
        // evidence of anything and must not clear the count.
        if let previous, selRange.location <= previous.caret - 2 {
            unappliedRewrites = 0
        }
        client.insertText(syllable, replacementRange: NSRange(location: selRange.location - length, length: length))
        lastPrecomposed = (caret: selRange.location, syllable: syllable)
    }
}

// MARK: - MarkedTextAdapter

/// Standard adapter with invisible-underline marked text for composition display
final class MarkedTextAdapter: BaseClientAdapter {
    override func setMarkedText(_ text: String) {
        // Canonical marked-text protocol, matching Apple's own input methods:
        // set the marked text directly with replacementRange = NSNotFound (an
        // empty string clears the composition). No visible underline on composing
        // Hangul (engine-tuned attributes — see `PreeditUnderline`). The previous
        // non-canonical path (clearing via insertText("") over an explicit marked
        // range) left native hosts like KakaoTalk in an inconsistent composition
        // state — a stranded/underlined preedit that never committed on focus loss.
        let attributed = NSAttributedString(string: text, attributes: preeditAttributes)
        client.setMarkedText(
            attributed,
            selectionRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }
}

// MARK: - ImmediateModeAdapter

/// Immediate mode adapter for non-text contexts (e.g., Finder desktop)
/// Skips setMarkedText to prevent floating composition window
final class ImmediateModeAdapter: BaseClientAdapter {
    override var deliveryMode: InputDeliveryMode { .immediate }
    // Inherits no-op setMarkedText from base class
}

// MARK: - DirectInsertionAdapter

/// EXPERIMENTAL (Phase 3): Windows-style direct insertion. There is no marked
/// text — the in-progress syllable is written as REAL text and rewritten in place
/// each keystroke. This isolates all direct-insertion state here so `HangulComposer`
/// stays unchanged: the composer keeps calling `insertText`/`setMarkedText` and this
/// adapter reinterprets them as in-place real-text rewrites.
///
/// Selected only when `experimentalDirectInsertion` is ON (or the host is Hermes),
/// the host is not on the `directInsertionDenied` denylist, AND the activation probe
/// found `documentAccessSafe`. OFF by default. See Docs/KoreanWindowsInputFeasibility.md.
final class DirectInsertionAdapter: BaseClientAdapter {
    override var deliveryMode: InputDeliveryMode { .directInsertion }

    /// Delivery state is explicit because finalization depends on where the preedit
    /// actually lives. In particular, `markedFallback` must use the canonical marked-
    /// text commit path; treating every DirectInsertionAdapter as "already real text"
    /// loses that fallback composition on focus or mode changes.
    enum State: Equatable {
        case idle
        case directLive(range: NSRange, text: String)
        case markedFallback
    }

    private(set) var state: State = .idle

    /// `prepareForInput()` validates a direct-live range immediately before the
    /// composer runs. Remember that validation for the one synchronous delegate call
    /// it produces so normal typing pays for one read-back, not two.
    private var preparedLiveRange: NSRange?

    /// Clear live-preedit tracking. Called by the session whenever composition
    /// ends out-of-band (focus loss, mouse-click commit, secure passthrough). Also
    /// re-arms direct insertion: a clean finalize lets a host that momentarily
    /// returned a bad selectionRange try direct insertion again.
    func resetPreeditTracking() {
        state = .idle
        preparedLiveRange = nil
    }

    var requiresMarkedTextFinalize: Bool {
        state == .markedFallback
    }

    /// Validate the identity of the real-text preedit before processing a new key.
    /// Both the stored document range and its contents must still match, and the
    /// selection must be the collapsed caret immediately after that exact range.
    ///
    /// Returns `true` when the caller must flush/reset the composer before handling
    /// the current key. The old real text is already committed in the document; the
    /// flush is engine-only and lets the current key begin a fresh composition.
    func prepareForInput() -> Bool {
        guard case let .directLive(range, text) = state else {
            preparedLiveRange = nil
            return false
        }

        let selection = client.selectedRange()
        let actual = client.attributedSubstring(from: range)?.string
        guard DirectInsertionPlanner.liveRegionIsVerified(
            selectionRange: selection,
            liveRange: range,
            actualSubstring: actual,
            expectedText: text
        ) else {
            state = .idle
            preparedLiveRange = nil
            DebugLogger.log("DirectInsertionAdapter: live range invalidated; committing existing real text and starting a new composition")
            return true
        }

        preparedLiveRange = range
        return false
    }

    private func renderMarkedFallback(_ text: String) {
        let attributed = NSAttributedString(string: text, attributes: preeditAttributes)
        client.setMarkedText(
            attributed,
            selectionRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    /// Replace the exact stored live-preedit range (if any) with `text` as REAL text.
    /// `keepingLive` means the replacement remains a tracked live preedit.
    private func rewriteLivePreedit(with text: String, keepingLive: Bool) {
        let tStart = CFAbsoluteTimeGetCurrent()
        let replacementRange: NSRange

        switch state {
        case let .directLive(range, expectedText):
            if preparedLiveRange == range {
                preparedLiveRange = nil
                replacementRange = range
            } else {
                // Delegate calls outside InputSession's keystroke pipeline still get
                // the same integrity guard. Never overwrite a range we cannot prove.
                let selection = client.selectedRange()
                let actual = client.attributedSubstring(from: range)?.string
                guard DirectInsertionPlanner.liveRegionIsVerified(
                    selectionRange: selection,
                    liveRange: range,
                    actualSubstring: actual,
                    expectedText: expectedText
                ) else {
                    state = .idle
                    rewriteLivePreedit(with: text, keepingLive: keepingLive)
                    return
                }
                replacementRange = range
            }

        case .idle:
            let selection = client.selectedRange()
            guard DirectInsertionPlanner.isUsableCollapsedSelection(selection) else {
                state = .markedFallback
                preparedLiveRange = nil
                renderMarkedFallback(text)
                DebugLogger.log("DirectInsertionAdapter: invalid selectedRange, falling back to marked text")
                return
            }
            replacementRange = NSRange(location: selection.location, length: 0)

        case .markedFallback:
            renderMarkedFallback(text)
            return
        }

        let tBeforeInsert = CFAbsoluteTimeGetCurrent()
        noteOwnOutput()
        client.insertText(text, replacementRange: replacementRange)
        let tEnd = CFAbsoluteTimeGetCurrent()

        if keepingLive, !text.isEmpty {
            state = .directLive(
                range: NSRange(location: replacementRange.location, length: text.utf16.count),
                text: text
            )
        } else {
            state = .idle
        }

        // Instrumentation: surface a slow rewrite with a per-IPC breakdown so latency
        // ("렉") can be pinpointed. Only logs the slow ones to avoid spam.
        let totalMs = (tEnd - tStart) * 1000
        if totalMs > 8 {
            DebugLogger.log(String(
                format: "DirectInsert SLOW total=%.1fms insert=%.1fms len=%d",
                totalMs, (tEnd - tBeforeInsert) * 1000, keepingLive ? text.utf16.count : 0))
        }
    }

    override func insertText(_ text: String) {
        if state == .markedFallback {
            super.insertText(text)   // base: NSNotFound auto-replaces marked text
            state = .idle
            preparedLiveRange = nil
            return
        }
        guard !text.isEmpty else { return }
        // A finalized insert replaces the live preedit (if any) and becomes permanent.
        // This is also why a hard commit cannot double-insert: committing the live
        // syllable rewrites the same region it already occupies.
        rewriteLivePreedit(with: text, keepingLive: false)
    }

    override func setMarkedText(_ text: String) {
        // No marked text in direct insertion: render the preedit as real text in place.
        rewriteLivePreedit(with: text, keepingLive: true)
    }

    override func replaceTextBeforeCursor(length: Int, with text: String, verifying context: String) -> TextReplacementResult {
        // Committed-text edit (e.g. double-space period); no live preedit involved.
        state = .idle
        preparedLiveRange = nil
        return super.replaceTextBeforeCursor(length: length, with: text, verifying: context)
    }

    override func precomposeSyllableBeforeCursor(followsBackspace: Bool) {
        // Shortening committed text shifts every tracked range after it.
        state = .idle
        preparedLiveRange = nil
        super.precomposeSyllableBeforeCursor(followsBackspace: followsBackspace)
    }
}
