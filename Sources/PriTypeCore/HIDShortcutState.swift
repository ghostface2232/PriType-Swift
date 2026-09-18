import CoreGraphics
import Foundation

/// Physical keyboard-page usages (IOHIDUsageTables.h) corresponding to macOS
/// virtual key positions (HIToolbox/Events.h). Characters/layouts are irrelevant.
enum HIDKeyMapping {
    static let usages: [Int64: UInt32] = [
        0: 0x04, 1: 0x16, 2: 0x07, 3: 0x09, 4: 0x0B, 5: 0x0A,
        6: 0x1D, 7: 0x1B, 8: 0x06, 9: 0x19, 10: 0x64, 11: 0x05,
        12: 0x14, 13: 0x1A, 14: 0x08, 15: 0x15, 16: 0x1C, 17: 0x17,
        18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 22: 0x23, 23: 0x22,
        24: 0x2E, 25: 0x26, 26: 0x24, 27: 0x2D, 28: 0x25, 29: 0x27,
        30: 0x30, 31: 0x12, 32: 0x18, 33: 0x2F, 34: 0x0C, 35: 0x13,
        36: 0x28, 37: 0x0F, 38: 0x0D, 39: 0x34, 40: 0x0E, 41: 0x33,
        42: 0x31, 43: 0x36, 44: 0x38, 45: 0x11, 46: 0x10, 47: 0x37,
        48: 0x2B, 49: 0x2C, 50: 0x35, 51: 0x2A, 53: 0x29,
        54: 0xE7, 55: 0xE3, 56: 0xE1, 57: 0x39, 58: 0xE2,
        59: 0xE0, 60: 0xE5, 61: 0xE6, 62: 0xE4,
        64: 0x6C, 65: 0x63, 67: 0x55, 69: 0x57, 71: 0x53,
        75: 0x54, 76: 0x58, 78: 0x56, 79: 0x6D, 80: 0x6E, 81: 0x67,
        82: 0x62, 83: 0x59, 84: 0x5A, 85: 0x5B, 86: 0x5C,
        87: 0x5D, 88: 0x5E, 89: 0x5F, 90: 0x6F, 91: 0x60, 92: 0x61,
        93: 0x89, 94: 0x87, 95: 0x85, 96: 0x3E, 97: 0x3F,
        98: 0x40, 99: 0x3C, 100: 0x41, 101: 0x42, 102: 0x91,
        103: 0x44, 104: 0x90, 105: 0x68, 106: 0x6B, 107: 0x69,
        109: 0x43, 110: 0x65, 111: 0x45, 113: 0x6A, 114: 0x49, 115: 0x4A,
        116: 0x4B, 117: 0x4C, 118: 0x3D, 119: 0x4D, 120: 0x3B,
        121: 0x4E, 122: 0x3A, 123: 0x50, 124: 0x4F, 125: 0x51, 126: 0x52
    ]

    static func modifierMask(for usage: UInt32) -> UInt64 {
        switch usage {
        case 0xE0, 0xE4: return CGEventFlags.maskControl.rawValue
        case 0xE1, 0xE5: return CGEventFlags.maskShift.rawValue
        case 0xE2, 0xE6: return CGEventFlags.maskAlternate.rawValue
        case 0xE3, 0xE7: return CGEventFlags.maskCommand.rawValue
        default: return 0
        }
    }
}

/// The IOKit fallback's shortcut rules, matching the CGEventTap path.
///
/// A lone-modifier toggle follows `ToggleTrigger`: on press, or on a tap with no
/// other key (`ModifierTapDetector`, the same rule the tap uses). IOKit observes
/// keys but cannot suppress them, so in press mode the modifier still reaches the
/// app: right ⌘ + C both switches and copies, where the tap would type "c".
/// Ordinary shortcut keys fire on their first down transition.
struct HIDShortcutState {
    enum Action: Equatable { case toggle, hanja }
    private struct Key: Hashable { let device: UInt64; let usage: UInt32 }

    /// A key that is merely held emits no further HID reports, so a held entry
    /// this old is far likelier to be a key-up the stream dropped than a finger
    /// still on the key. The value stream is interrupted whenever the host takes
    /// the keyboard away mid-press — a screen lock, a fast user switch, a secure
    /// input field. Without this the CGEventTap path's per-event reconciliation
    /// against `event.flags` has no counterpart here, and one lost key-up wedges
    /// the monitor permanently: a stuck ordinary key blocks every later tap, and
    /// a stuck modifier makes its bare trigger key match a combo binding.
    static let holdExpiry: TimeInterval = 30

    /// A duplicate hanja trigger does not reopen the candidate window, it closes
    /// it — `triggerHanjaLookup` toggles. The CGEventTap path has debounced this
    /// since v2.3.0 because Right Option can report several DOWN transitions in
    /// quick succession; mirror it so a fallback monitor cannot resurrect the
    /// open-then-immediately-dismiss bug. Ordinary keys are left alone there too.
    static let hanjaDebounce: TimeInterval = 0.5

    private var held: [Key: TimeInterval] = [:]
    private var pendingToggle: Key?
    private var toggleTap = ModifierTapDetector()
    private var lastBindings: [KeyBinding] = []
    private var lastHanja: TimeInterval?

    static func timestamp() -> TimeInterval { Date().timeIntervalSinceReferenceDate }

    /// Drop every press when any keyboard is unplugged. Per-device cleanup would
    /// need the removal callback's device to resolve to the same identity as the
    /// input callback's, which cannot be verified without physically detaching a
    /// keyboard, so do not depend on it: clearing everything needs no such match.
    /// The cost is that unplugging one keyboard forgets what another was holding,
    /// which the next transition on that keyboard restores. Disconnection is not
    /// a release and must never complete a toggle, so the pending tap goes too.
    mutating func handleDeviceRemoval() {
        held.removeAll()
        pendingToggle = nil
        toggleTap.interrupt()
    }

    mutating func consume(usage: UInt32, pressed: Bool, device: UInt64 = 0,
                          toggle: KeyBinding, hanja: KeyBinding,
                          toggleEnabled: Bool = true, hanjaEnabled: Bool = true,
                          trigger: ToggleTrigger = .press, paused: Bool = false,
                          at now: TimeInterval = HIDShortcutState.timestamp()) -> Action? {
        expireStaleHolds(before: now - Self.holdExpiry)
        if lastBindings != [toggle, hanja] {
            pendingToggle = nil
            lastBindings = [toggle, hanja]
        }
        let key = Key(device: device, usage: usage)
        let transitioned = pressed
            ? held.updateValue(now, forKey: key) == nil
            : held.removeValue(forKey: key) != nil
        if paused || !toggleEnabled { pendingToggle = nil }
        guard !paused, transitioned else { return nil }
        let flags = held.keys.reduce(UInt64(0)) { $0 | HIDKeyMapping.modifierMask(for: $1.usage) }
        if !pressed {
            guard toggleEnabled, pendingToggle == key else { return nil }
            pendingToggle = nil
            return toggleTap.release(at: now) ? .toggle : nil
        }

        // Any second ordinary key cancels a pending standalone modifier tap,
        // including a key on another keyboard. This retains native Command
        // shortcut behavior. A chorded modifier is not a shortcut on its own, so
        // Shift held across the tap must not cancel it.
        if HIDKeyMapping.modifierMask(for: usage) == 0 {
            pendingToggle = nil
            toggleTap.interrupt()
        }
        func matches(_ binding: KeyBinding) -> Bool {
            HIDKeyMapping.usages[binding.keyCode] == usage
                && flags & binding.modifiers == binding.modifiers
        }
        if toggleEnabled && matches(toggle) {
            if toggle.isModifierKey && trigger == .tapAlone {
                // Only an ordinary key already held disqualifies the tap; other
                // modifiers do not, as on the CGEventTap path.
                if held.keys.allSatisfy({ HIDKeyMapping.modifierMask(for: $0.usage) != 0 }) {
                    pendingToggle = key
                    toggleTap.press(at: now)
                }
                return nil
            }
            return .toggle
        }
        guard hanjaEnabled, matches(hanja) else { return nil }
        if hanja.isModifierKey, let last = lastHanja, now - last < Self.hanjaDebounce { return nil }
        lastHanja = now
        return .hanja
    }

    private mutating func expireStaleHolds(before cutoff: TimeInterval) {
        guard held.contains(where: { $0.value < cutoff }) else { return }
        held = held.filter { $0.value >= cutoff }
        // A tap whose own key expired is no longer a tap.
        if let pending = pendingToggle, held[pending] == nil { pendingToggle = nil }
    }
}
