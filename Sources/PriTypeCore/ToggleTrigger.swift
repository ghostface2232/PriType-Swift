import Foundation

/// When a toggle key that is a lone modifier (right ⌘, right Option, …) switches
/// the input mode. Ordinary keys and combinations always switch on key down.
public enum ToggleTrigger: String, Sendable, CaseIterable {
    /// Switch the moment the key goes down. The key is swallowed, so it no longer
    /// works as a modifier: right ⌘ + C types "c" instead of copying.
    case press
    /// Switch when the key is released without any other key or a click in
    /// between. Held with another key, it stays an ordinary modifier (right ⌘ + C
    /// copies), at the cost of switching on release instead of press.
    case tapAlone
}

/// Tells a lone tap of a modifier from its use in a shortcut. Shared by the
/// CGEventTap and IOKit monitors so both apply the same rule.
struct ModifierTapDetector {
    /// Held longer than this, the press is a hesitation rather than a tap: the
    /// user reached for a shortcut and let go. Karabiner-Elements' `to_if_alone`
    /// uses the same default, which is what most users of this setting came from.
    static let maxHold: TimeInterval = 1.0

    private var pressedAt: TimeInterval?

    var isPending: Bool { pressedAt != nil }

    mutating func press(at time: TimeInterval) {
        pressedAt = time
    }

    /// Another key or a click happened while the modifier was down.
    mutating func interrupt() {
        pressedAt = nil
    }

    /// Whether this release completes a tap. Ends the press either way.
    mutating func release(at time: TimeInterval) -> Bool {
        defer { pressedAt = nil }
        guard let pressedAt else { return false }
        return time - pressedAt <= Self.maxHold
    }
}
