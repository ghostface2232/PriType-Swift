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
    ///   - checkHangul: If true, also checks for Hangul characters before space
    /// - Returns: Result indicating whether period conversion occurred
    public func handleDoubleSpacePeriod(buffer: inout String, delegate: HangulComposerDelegate, checkHangul: Bool = false) -> DoubleSpaceResult {
        let now = ProcessInfo.processInfo.systemUptime
        let isDoubleTap = (now - lastSpaceTime) < PriTypeConfig.doubleSpaceThreshold
        lastSpaceTime = now
        
        // Double-space period: Only if enabled, just typed space, AND fast enough
        if isDoubleSpacePeriodEnabled() && lastWasSpace && isDoubleTap {
            // Check context to confirm valid double-space condition
            if buffer.hasSuffix(" ") {
                let preSpaceChar = buffer.dropLast().last
                if let lastChar = preSpaceChar {
                    let isValidChar = lastChar.isLetter || lastChar.isNumber || (checkHangul && isHangul(lastChar))
                    if isValidChar {
                        // Valid double-space condition - replace space with period
                        delegate.replaceTextBeforeCursor(length: 1, with: ". ")
                        buffer.removeLast()
                        buffer.append(". ")
                        lastWasSpace = false
                        DebugLogger.log("Double-space -> period (Context validated)")
                        return .convertedToPeriod
                    }
                }
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

    // MARK: - Helpers
    
    /// Checks if a character is a Hangul syllable or Jamo
    public func isHangul(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        let val = scalar.value
        // Hangul Syllables: AC00-D7A3
        // Hangul Compatibility Jamo: 3130-318F
        // Hangul Jamo: 1100-11FF
        return (val >= 0xAC00 && val <= 0xD7A3) ||
               (val >= 0x3130 && val <= 0x318F) ||
               (val >= 0x1100 && val <= 0x11FF)
    }
}
