import Cocoa

/// Handles the double-space period in Korean composition
///
/// Gated on the macOS "Add period with double-space" preference
/// (`NSAutomaticPeriodSubstitutionEnabled`). English mode passes keys through, so
/// the host applies its own text conveniences there, as it does for ABC.
///
/// ## Usage
/// ```swift
/// let handler = TextConvenienceHandler()
/// let result = handler.handleDoubleSpacePeriod(delegate: myDelegate)
/// ```
public final class TextConvenienceHandler: @unchecked Sendable {
    private let isDoubleSpacePeriodEnabled: @Sendable () -> Bool
    
    // MARK: - State
    
    /// Track if last character was a space (for double-space detection)
    private var lastWasSpace: Bool = false
    
    /// Uptime of the last space key press (for double-space timing check).
    /// Uptime, not wall-clock time: a clock correction between two spaces must
    /// not make them look 0.45s apart, or together.
    private var lastSpaceTime: TimeInterval = -.infinity
    
    public init(
        isDoubleSpacePeriodEnabled: @escaping @Sendable () -> Bool = {
            ConfigurationManager.shared.doubleSpacePeriodEnabled
        }
    ) {
        self.isDoubleSpacePeriodEnabled = isDoubleSpacePeriodEnabled
    }
    
    // MARK: - Double-Space Period
    
    /// Result of double-space period handling
    public enum DoubleSpaceResult {
        /// Double-space was converted to period - event consumed
        case convertedToPeriod
        /// Normal space - event should be passed to system
        case normalSpace
    }
    
    /// Handle space key press for double-space period conversion
    ///
    /// - Parameters:
    ///   - buffer: The local text buffer to query and modify
    ///   - delegate: The delegate to modify text
    /// - Returns: Result indicating whether period conversion occurred
    public func handleDoubleSpacePeriod(buffer: inout String, delegate: HangulComposerDelegate) -> DoubleSpaceResult {
        let now = ProcessInfo.processInfo.systemUptime
        let isDoubleTap = (now - lastSpaceTime) < PriTypeConfig.doubleSpaceThreshold
        lastSpaceTime = now
        
        // Double-space period: Only if enabled, just typed space, AND fast enough
        if isDoubleSpacePeriodEnabled(), lastWasSpace, isDoubleTap,
           buffer.hasSuffix(" "),
           // Hangul syllables and jamo are letters (Unicode Lo).
           let preSpaceChar = buffer.dropLast().last,
           preSpaceChar.isLetter || preSpaceChar.isNumber {
            // The buffer says what was typed here, not where the caret is now: with
            // nothing marked, a click moves the caret and IMK says nothing. So the
            // space to be replaced, and the character that made it replaceable, must
            // still be the two characters in front of the caret — the host's answer,
            // taken now. `가␠` with the caret moved back behind the space is a
            // different place in the document, and gets an ordinary space instead.
            let expected = String(preSpaceChar) + " "
            switch delegate.replaceTextBeforeCursor(length: 1, with: ". ", verifying: expected) {
            case .issued:
                buffer.removeLast()
                buffer.append(". ")
                lastWasSpace = false
                DebugLogger.log("Double-space -> period (Context validated)")
                return .convertedToPeriod
            case .unavailable:
                // The host holds something else, or will not say what it holds. The
                // substitution is off, but the space the user pressed still has to
                // be typed: the caller inserts it on `.normalSpace`. Anything else
                // loses a keystroke in hosts that report no caret at all.
                DebugLogger.log("Double-space -> ordinary space (host could not confirm the target)")
                // The buffer no longer describes what is in front of the caret.
                buffer = ""
            }
        }
        
        // Normal space
        lastWasSpace = true
        return .normalSpace
    }
    
    /// Reset the space state (call when non-space character is typed)
    public func resetSpaceState() {
        lastWasSpace = false
    }
}
