import Foundation

// MARK: - HangulComposerDelegate Protocol

/// Protocol for receiving text composition events from `HangulComposer`
///
/// Implement this protocol to receive callbacks when the composer needs to
/// insert finalized text or update the in-progress composition (marked text).
///
/// ## Example Implementation
/// ```swift
/// class MyDelegate: HangulComposerDelegate {
///     func insertText(_ text: String) {
///         textView.insertText(text)
///     }
///     func setMarkedText(_ text: String) {
///         textView.setMarkedText(text)
///     }
/// }
/// ```
public protocol HangulComposerDelegate: AnyObject {
    /// Called when finalized text should be inserted
    /// - Parameter text: The text to insert (already composed Hangul syllables)
    func insertText(_ text: String)

    /// Called when the in-progress composition text should be displayed
    /// - Parameter text: The preedit text (incomplete Hangul being composed)
    func setMarkedText(_ text: String)
    
    /// Returns the text immediately before the current cursor position
    /// - Parameter length: Maximum length of text to retrieve
    /// - Returns: The text before cursor, or nil if unavailable
    func textBeforeCursor(length: Int) -> String?
    
    /// Replaces text before the cursor with new text, but only after the host has
    /// confirmed that the text still standing there is the text meant to be edited.
    ///
    /// Used for features like the double-space period, which rewrite text that was
    /// committed earlier. Committed text has no marked range, so the caret can move
    /// away from it — a click, a drag, the host's own scripting — without the input
    /// method ever hearing of it, and an edit aimed at where the text used to be
    /// would fall on whatever took its place.
    ///
    /// - Parameters:
    ///   - length: Number of UTF-16 units to replace, counting back from the caret.
    ///   - text: The new text to insert.
    ///   - context: The exact text expected immediately before the caret, whose last
    ///     `length` UTF-16 units are the ones to be replaced. Wider than the
    ///     replacement on purpose: the character before a space is what made the
    ///     substitution valid, so it has to be the same character still.
    /// - Returns: `.issued` when the edit was sent to the host, `.unavailable` when
    ///   the host could not confirm the text (no usable caret, nothing readable) or
    ///   confirmed something else. The caller must fall back to ordinary input on
    ///   `.unavailable`; the keystroke must not simply disappear.
    func replaceTextBeforeCursor(length: Int, with text: String, verifying context: String) -> TextReplacementResult

    /// Called just before a Backspace goes to the host with nothing composing.
    /// Rewrites a decomposed (NFD) syllable before the caret as its precomposed
    /// form, so the host deletes the syllable instead of its last jamo.
    /// - Parameter followsBackspace: whether the key before this one was also a
    ///   Backspace. Only then can an unchanged caret mean the host ignored the
    ///   previous rewrite rather than the user having moved back there.
    func precomposeSyllableBeforeCursor(followsBackspace: Bool)

    /// Forget which rewrite was last attempted. Called when something other than a
    /// keystroke (a click, focus loss) may have moved the caret.
    /// (No default: a delivery path that silently ignored these would lose the
    /// rewrite, or keep a stale one, with nothing to show for it.)
    func forgetLastPrecomposedSyllable()

    /// Called when the keystroke moves to another field of the same client, which
    /// may answer where the last one refused. Gives up what was remembered and
    /// lets a host the rewrite had written off be tried again.
    func resumePrecomposing()
}

// MARK: - TextReplacementResult

/// Whether an edit to already-committed text reached the host.
///
/// `.issued` means the edit was sent, not that the host applied it: IMK's
/// `insertText` answers nothing at all. It says only that everything the input
/// method can check did check out.
public enum TextReplacementResult: Sendable, Equatable {
    /// The target was confirmed and the replacement was sent to the host.
    case issued
    /// The host reports no usable caret, no readable text, or different text than
    /// the one meant to be edited. Nothing was written.
    case unavailable
}

// MARK: - InputMode Enum

/// Input mode for the Hangul composer
///
/// The composer can operate in two modes:
/// - `korean`: Processes keystrokes as Hangul input
/// - `english`: Passes keystrokes through unchanged
public enum InputMode: Sendable {
    /// Korean input mode - keystrokes are processed as Hangul
    case korean
    /// English input mode - keystrokes pass through to system
    case english
    
    /// Returns the opposite mode (korean ↔ english)
    public var toggled: InputMode {
        switch self {
        case .korean: return .english
        case .english: return .korean
        }
    }
}
