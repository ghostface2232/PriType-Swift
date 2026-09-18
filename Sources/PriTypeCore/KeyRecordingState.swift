import CoreGraphics

/// Shared by the event tap and the settings window's local fallback.
/// A modifier is ambiguous until released: it can still become a shortcut.
struct KeyRecordingState {
    struct RecordedKey: Equatable {
        let keyCode: Int64
        let modifiers: UInt64
    }

    private var heldModifiers: Set<Int64> = []
    private var singleModifier: Int64?
    private var completed = false

    mutating func consume(keyCode: Int64, flags: UInt64, isModifierChange: Bool) -> RecordedKey? {
        guard !completed else { return nil }
        let candidate: RecordedKey?
        if isModifierChange {
            if keyCode == 57 {
                // The UI explicitly rejects Caps Lock in favour of macOS switching.
                candidate = RecordedKey(keyCode: keyCode, modifiers: 0)
            } else if ModifierKeyState.isDown(keyCode, flags: flags) {
                if heldModifiers.insert(keyCode).inserted {
                    singleModifier = heldModifiers.count == 1 ? keyCode : nil
                }
                return nil
            } else {
                guard heldModifiers.remove(keyCode) != nil else { return nil }
                candidate = singleModifier == keyCode && heldModifiers.isEmpty
                    ? RecordedKey(keyCode: keyCode, modifiers: 0) : nil
                if heldModifiers.isEmpty { singleModifier = nil }
            }
        } else {
            // Any ordinary key makes the held modifiers part of a shortcut.
            // Their later releases must not produce a second standalone binding.
            singleModifier = nil
            let mask = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
                | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue
            candidate = RecordedKey(keyCode: keyCode, modifiers: flags & mask)
        }
        if let candidate {
            let binding = KeyBinding(keyCode: candidate.keyCode, modifiers: candidate.modifiers, displayName: "")
            // Invalid bare typing can be retried. Valid/cancel candidates are
            // latched so queued events cannot overwrite the first recording.
            completed = binding.isSafeGlobalBinding || candidate.keyCode == 53 || candidate.keyCode == 57
        }
        return candidate
    }
}
