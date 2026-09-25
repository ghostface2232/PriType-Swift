import Cocoa
import Testing
@testable import PriTypeCore

private enum HIDUsage {
    static let a: UInt32 = 0x04
    static let space: UInt32 = 0x2C
    static let f13: UInt32 = 0x68
    static let leftControl: UInt32 = 0xE0
    static let leftShift: UInt32 = 0xE1
    static let rightOption: UInt32 = 0xE6
    static let rightCommand: UInt32 = 0xE7
}

private let f13Binding = KeyBinding(keyCode: 105, modifiers: 0, displayName: "F13")
private let rightCommandBinding = KeyBinding(keyCode: 54, modifiers: 0, displayName: "Right Command")
private let rightOptionBinding = KeyBinding(keyCode: 61, modifiers: 0, displayName: "Right Option")
private let controlSpaceBinding = KeyBinding(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue,
                                             displayName: "Control Space")
private let optionSpaceBinding = KeyBinding(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue,
                                            displayName: "Option Space")

private final class ShortcutActions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) { lock.withLock { values.append(value) } }
    var snapshot: [String] { lock.withLock { values } }
}

/// The IOKit fallback must honour the same binding contract as the CGEventTap
/// path in `ShortcutRoutingTests`; it previously understood modifier keys only,
/// so an ordinary or combo binding went dead once IOKit took over.
@Suite("IOKit shortcut routing")
struct IOKitShortcutRoutingTests {

    /// Modifier-toggle cases below describe tap mode, which is where they differ
    /// from the CGEventTap's default; press mode has its own tests.
    private func press(_ state: inout HIDShortcutState, _ usage: UInt32, _ pressed: Bool,
                       device: UInt64 = 1, toggle: KeyBinding, hanja: KeyBinding,
                       toggleEnabled: Bool = true, trigger: ToggleTrigger = .tapAlone,
                       paused: Bool = false, at now: TimeInterval = 0) -> HIDShortcutState.Action? {
        state.consume(usage: usage, pressed: pressed, device: device, toggle: toggle, hanja: hanja,
                      toggleEnabled: toggleEnabled, trigger: trigger, paused: paused, at: now)
    }

    @Test("In press mode a modifier toggles on key down, like the event tap")
    func pressModeTogglesOnDown() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.rightCommand, true, toggle: rightCommandBinding,
                      hanja: rightOptionBinding, trigger: .press) == .toggle)
        #expect(press(&state, HIDUsage.rightCommand, false, toggle: rightCommandBinding,
                      hanja: rightOptionBinding, trigger: .press) == nil)
        // Used in a shortcut it has already toggled; IOKit cannot hold the key back.
        #expect(press(&state, HIDUsage.rightCommand, true, toggle: rightCommandBinding,
                      hanja: rightOptionBinding, trigger: .press, at: 1) == .toggle)
        #expect(press(&state, HIDUsage.a, true, toggle: rightCommandBinding,
                      hanja: rightOptionBinding, trigger: .press, at: 1.1) == nil)
        #expect(press(&state, HIDUsage.rightCommand, false, toggle: rightCommandBinding,
                      hanja: rightOptionBinding, trigger: .press, at: 1.2) == nil)
    }

    @Test("The Hanja key pressed during a toggle tap cancels the tap")
    func hanjaCancelsTap() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.rightCommand, true, toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.rightOption, true, toggle: rightCommandBinding, hanja: rightOptionBinding) == .hanja)
        #expect(press(&state, HIDUsage.rightOption, false, toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.rightCommand, false, toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
    }

    @Test("A tap held past the limit is a hesitation, not a toggle")
    func longHoldIsNotATap() {
        var state = HIDShortcutState()
        let limit = ModifierTapDetector.maxHold
        #expect(press(&state, HIDUsage.rightCommand, true, toggle: rightCommandBinding,
                      hanja: rightOptionBinding, at: 0) == nil)
        #expect(press(&state, HIDUsage.rightCommand, false, toggle: rightCommandBinding,
                      hanja: rightOptionBinding, at: limit + 0.1) == nil)
        #expect(press(&state, HIDUsage.rightCommand, true, toggle: rightCommandBinding,
                      hanja: rightOptionBinding, at: 5) == nil)
        #expect(press(&state, HIDUsage.rightCommand, false, toggle: rightCommandBinding,
                      hanja: rightOptionBinding, at: 5 + limit - 0.1) == .toggle)
    }

    @Test("With Hanja conversion off, the Hanja key triggers nothing")
    func hanjaOff() {
        var state = HIDShortcutState()
        #expect(state.consume(usage: HIDUsage.rightOption, pressed: true, device: 1,
                              toggle: rightCommandBinding, hanja: rightOptionBinding,
                              hanjaEnabled: false, at: 0) == nil)
        #expect(state.consume(usage: HIDUsage.rightOption, pressed: false, device: 1,
                              toggle: rightCommandBinding, hanja: rightOptionBinding,
                              hanjaEnabled: false, at: 0.1) == nil)
        #expect(state.consume(usage: HIDUsage.rightOption, pressed: true, device: 1,
                              toggle: rightCommandBinding, hanja: rightOptionBinding,
                              hanjaEnabled: true, at: 1) == .hanja)
    }

    @Test("A standalone ordinary key toggles on its own key down")
    func ordinaryKeyToggles() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.f13, true, toggle: f13Binding, hanja: rightOptionBinding) == .toggle)
        #expect(press(&state, HIDUsage.f13, false, toggle: f13Binding, hanja: rightOptionBinding) == nil)
    }

    @Test("Repeated taps of an ordinary key keep toggling")
    func ordinaryKeyTapsRepeat() {
        var state = HIDShortcutState()
        var actions: [HIDShortcutState.Action?] = []
        for _ in 0..<3 {
            actions.append(press(&state, HIDUsage.f13, true, toggle: f13Binding, hanja: rightOptionBinding))
            actions.append(press(&state, HIDUsage.f13, false, toggle: f13Binding, hanja: rightOptionBinding))
        }
        #expect(actions == [.toggle, nil, .toggle, nil, .toggle, nil])
    }

    @Test("Auto-repeat while a key is held fires once")
    func autoRepeatFiresOnce() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.f13, true, toggle: f13Binding, hanja: rightOptionBinding) == .toggle)
        #expect(press(&state, HIDUsage.f13, true, toggle: f13Binding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.f13, true, toggle: f13Binding, hanja: rightOptionBinding) == nil)
    }

    @Test("A combo binding needs its modifier held")
    func comboRequiresModifier() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.space, true, toggle: controlSpaceBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.space, false, toggle: controlSpaceBinding, hanja: rightOptionBinding) == nil)

        #expect(press(&state, HIDUsage.leftControl, true, toggle: controlSpaceBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.space, true, toggle: controlSpaceBinding, hanja: rightOptionBinding) == .toggle)
    }

    @Test("A combo binding fires only on exactly its modifiers")
    func comboNeedsExactModifiers() {
        var state = HIDShortcutState()
        // ⌃⌥Space is macOS's "next input source", not the ⌃Space binding.
        #expect(press(&state, HIDUsage.leftControl, true, toggle: controlSpaceBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.leftShift, true, toggle: controlSpaceBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.space, true, toggle: controlSpaceBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.space, false, toggle: controlSpaceBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.leftShift, false, toggle: controlSpaceBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.space, true, toggle: controlSpaceBinding, hanja: rightOptionBinding) == .toggle)
    }

    @Test("Different modifiers on Space dispatch the matching action")
    func sharedPhysicalKey() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.rightOption, true, toggle: controlSpaceBinding, hanja: optionSpaceBinding) == nil)
        #expect(press(&state, HIDUsage.space, true, toggle: controlSpaceBinding, hanja: optionSpaceBinding) == .hanja)
        #expect(press(&state, HIDUsage.space, false, toggle: controlSpaceBinding, hanja: optionSpaceBinding) == nil)
        #expect(press(&state, HIDUsage.rightOption, false, toggle: controlSpaceBinding, hanja: optionSpaceBinding) == nil)

        #expect(press(&state, HIDUsage.leftControl, true, toggle: controlSpaceBinding, hanja: optionSpaceBinding) == nil)
        #expect(press(&state, HIDUsage.space, true, toggle: controlSpaceBinding, hanja: optionSpaceBinding) == .toggle)
    }

    @Test("An identical binding fires once, with toggle priority")
    func identicalBindings() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.f13, true, toggle: f13Binding, hanja: f13Binding) == .toggle)
    }

    @Test("A modifier binding toggles on release, not on press")
    func modifierTogglesOnRelease() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.rightCommand, true, toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.rightCommand, false, toggle: rightCommandBinding, hanja: rightOptionBinding) == .toggle)
    }

    @Test("A modifier used in a shortcut does not toggle on release")
    func modifierComboDoesNotToggle() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.rightCommand, true, toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.a, true, toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.a, false, toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.rightCommand, false, toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
    }

    @Test("A modifier held across the tap does not block the toggle")
    func chordedModifierStillToggles() {
        var state = HIDShortcutState()
        // Shift+RightCommand is not a shortcut, so a capital letter mid-word must
        // not silently disable 한/영 switching the way the tap path never does.
        #expect(press(&state, HIDUsage.leftShift, true, toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.rightCommand, true, toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.rightCommand, false, toggle: rightCommandBinding, hanja: rightOptionBinding) == .toggle)
        #expect(press(&state, HIDUsage.leftShift, false, toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
    }

    @Test("A modifier pressed after the tap does not cancel it")
    func laterModifierDoesNotCancelTap() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.rightCommand, true, toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.leftShift, true, toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.leftShift, false, toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.rightCommand, false, toggle: rightCommandBinding, hanja: rightOptionBinding) == .toggle)
    }

    @Test("Unplugging a keyboard releases the keys it held")
    func deviceRemovalReleasesHeldKeys() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.a, true, device: 7,
                      toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        state.handleDeviceRemoval()
        // The stale `A` must no longer count as an ordinary key held down.
        #expect(press(&state, HIDUsage.rightCommand, true, device: 1,
                      toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.rightCommand, false, device: 1,
                      toggle: rightCommandBinding, hanja: rightOptionBinding) == .toggle)
    }

    @Test("A held key outliving the expiry window stops blocking the toggle")
    func staleOrdinaryKeyStopsBlockingToggle() {
        var state = HIDShortcutState()
        let stale = HIDShortcutState.holdExpiry + 1
        // The key-up for `A` never arrives — the host took the keyboard away
        // mid-press. Without expiry this wedges the toggle permanently.
        #expect(press(&state, HIDUsage.a, true, toggle: rightCommandBinding, hanja: rightOptionBinding,
                      at: 0) == nil)
        #expect(press(&state, HIDUsage.rightCommand, true, toggle: rightCommandBinding,
                      hanja: rightOptionBinding, at: stale) == nil)
        #expect(press(&state, HIDUsage.rightCommand, false, toggle: rightCommandBinding,
                      hanja: rightOptionBinding, at: stale) == .toggle)
    }

    @Test("A stale modifier no longer satisfies a combo binding")
    func staleModifierDoesNotSatisfyCombo() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.leftControl, true, toggle: controlSpaceBinding,
                      hanja: rightOptionBinding, at: 0) == nil)
        // Otherwise every bare Space would switch the input source while typing.
        #expect(press(&state, HIDUsage.space, true, toggle: controlSpaceBinding,
                      hanja: rightOptionBinding, at: HIDShortcutState.holdExpiry + 1) == nil)
    }

    @Test("A modifier held inside the expiry window still satisfies a combo")
    func recentModifierStillSatisfiesCombo() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.leftControl, true, toggle: controlSpaceBinding,
                      hanja: rightOptionBinding, at: 0) == nil)
        #expect(press(&state, HIDUsage.space, true, toggle: controlSpaceBinding,
                      hanja: rightOptionBinding, at: HIDShortcutState.holdExpiry - 1) == .toggle)
    }

    @Test("A tap whose own key went stale does not toggle on release")
    func staleTapDoesNotToggle() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.rightCommand, true, toggle: rightCommandBinding,
                      hanja: rightOptionBinding, at: 0) == nil)
        #expect(press(&state, HIDUsage.rightCommand, false, toggle: rightCommandBinding,
                      hanja: rightOptionBinding, at: HIDShortcutState.holdExpiry + 1) == nil)
    }

    @Test("A modifier hanja key is debounced")
    func modifierHanjaIsDebounced() {
        var state = HIDShortcutState()
        let debounce = HIDShortcutState.hanjaDebounce
        #expect(press(&state, HIDUsage.rightOption, true, toggle: f13Binding,
                      hanja: rightOptionBinding, at: 0) == .hanja)
        #expect(press(&state, HIDUsage.rightOption, false, toggle: f13Binding,
                      hanja: rightOptionBinding, at: debounce / 4) == nil)
        // A duplicate DOWN would dismiss the candidate window that just opened.
        #expect(press(&state, HIDUsage.rightOption, true, toggle: f13Binding,
                      hanja: rightOptionBinding, at: debounce / 2) == nil)
        #expect(press(&state, HIDUsage.rightOption, false, toggle: f13Binding,
                      hanja: rightOptionBinding, at: debounce / 2) == nil)
        #expect(press(&state, HIDUsage.rightOption, true, toggle: f13Binding,
                      hanja: rightOptionBinding, at: debounce + 0.1) == .hanja)
    }

    @Test("An ordinary hanja key is not debounced")
    func ordinaryHanjaIsNotDebounced() {
        var state = HIDShortcutState()
        // The CGEventTap path debounces its flagsChanged branch only, so an
        // ordinary or combo binding must stay responsive on both monitors.
        #expect(press(&state, HIDUsage.rightOption, true, toggle: f13Binding,
                      hanja: optionSpaceBinding, at: 0) == nil)
        #expect(press(&state, HIDUsage.space, true, toggle: f13Binding,
                      hanja: optionSpaceBinding, at: 0) == .hanja)
        #expect(press(&state, HIDUsage.space, false, toggle: f13Binding,
                      hanja: optionSpaceBinding, at: 0.05) == nil)
        #expect(press(&state, HIDUsage.space, true, toggle: f13Binding,
                      hanja: optionSpaceBinding, at: 0.1) == .hanja)
    }

    @Test("Every bare-bindable key has a HID usage")
    func mappingCoversBareBindableKeys() {
        for keyCode in Int64(0)...127 {
            let binding = KeyBinding(keyCode: keyCode, modifiers: 0, displayName: "k\(keyCode)")
            guard binding.isSafeGlobalBinding else { continue }
            #expect(HIDKeyMapping.usages[keyCode] != nil, "keyCode \(keyCode) has no HID usage")
        }
    }

    @Test("A key on another keyboard also cancels a pending modifier tap")
    func otherKeyboardCancelsPendingTap() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.rightCommand, true, device: 1,
                      toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.a, true, device: 2,
                      toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.rightCommand, false, device: 1,
                      toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
    }

    @Test("Unplugging a keyboard mid-press emits no phantom toggle")
    func deviceRemovalDropsPendingTap() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.rightCommand, true, device: 7,
                      toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        state.handleDeviceRemoval()
        #expect(press(&state, HIDUsage.rightCommand, false, device: 7,
                      toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
    }

    @Test("A keyboard still attached keeps working after another is unplugged")
    func otherKeyboardRecoversAfterRemoval() {
        var state = HIDShortcutState()
        // Clearing every press is deliberate: identifying which keyboard went
        // away would need the removal and input callbacks to agree on identity.
        #expect(press(&state, HIDUsage.rightCommand, true, device: 2,
                      toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        state.handleDeviceRemoval()
        #expect(press(&state, HIDUsage.rightCommand, true, device: 2,
                      toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.rightCommand, false, device: 2,
                      toggle: rightCommandBinding, hanja: rightOptionBinding) == .toggle)
    }

    @Test("Rebinding mid-press drops the pending tap")
    func rebindingDropsPendingTap() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.rightCommand, true, toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.rightCommand, false, toggle: f13Binding, hanja: rightOptionBinding) == nil)
    }

    @Test("A paused monitor emits nothing and drops the pending tap")
    func pausedEmitsNothing() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.rightCommand, true, toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.a, true, toggle: rightCommandBinding, hanja: rightOptionBinding,
                      paused: true) == nil)
        #expect(press(&state, HIDUsage.rightCommand, false, toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.f13, true, toggle: f13Binding, hanja: rightOptionBinding, paused: true) == nil)
    }

    @Test("A disabled toggle still routes hanja")
    func disabledToggleStillRoutesHanja() {
        var state = HIDShortcutState()
        #expect(press(&state, HIDUsage.f13, true, toggle: f13Binding, hanja: rightOptionBinding,
                      toggleEnabled: false) == nil)
        #expect(press(&state, HIDUsage.f13, false, toggle: f13Binding, hanja: rightOptionBinding,
                      toggleEnabled: false) == nil)
        #expect(press(&state, HIDUsage.rightOption, true, toggle: f13Binding, hanja: rightOptionBinding,
                      toggleEnabled: false) == .hanja)
    }

    @Test("The manager dispatches an ordinary-key toggle to its callback")
    func managerDispatchesOrdinaryKeyToggle() async {
        let manager = IOKitManager()
        let actions = ShortcutActions()
        manager.onRightCommandToggle = { _ in actions.record("toggle") }
        manager.onRightOptionHanja = { _ in actions.record("hanja") }

        manager.handleKeyboardEvent(usage: HIDUsage.f13, pressed: true, toggle: f13Binding,
                                    hanja: rightOptionBinding, toggleEnabled: true, paused: false)
        manager.handleKeyboardEvent(usage: HIDUsage.rightOption, pressed: true, toggle: f13Binding,
                                    hanja: rightOptionBinding, toggleEnabled: true, paused: false)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(actions.snapshot == ["toggle", "hanja"])
    }

    @Test("A hardware key is handed over with the time it was pressed")
    func managerReportsThePressTime() async {
        let manager = IOKitManager()
        let times = PressTimes()
        manager.onRightCommandToggle = { times.record($0) }

        let pressedAt: TimeInterval = 12_345.5
        manager.handleKeyboardEvent(usage: HIDUsage.f13, pressed: true, eventTime: pressedAt,
                                    toggle: f13Binding, hanja: rightOptionBinding,
                                    toggleEnabled: true, paused: false)
        // The hand-over hops to main, so the toggle is not performed inside the
        // IOHID value callback.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(times.snapshot == [pressedAt],
                "the fallback can only order against a keystroke if it says when the key was pressed")
    }

    @Test("The fallback times its rules by the keys' own clock, not the wall clock")
    func rulesUseEventTime() async {
        let manager = IOKitManager()
        let actions = ShortcutActions()
        manager.onRightOptionHanja = { _ in actions.record("hanja") }
        // Two Hanja presses a second apart by their HID stamps, delivered back to
        // back. The debounce is half a second; a clock read at delivery would see
        // them as simultaneous (and a wall clock stepped back, as later still).
        for (pressedAt, pressed) in [(100.0, true), (100.1, false), (101.0, true), (101.1, false)] {
            manager.handleKeyboardEvent(usage: HIDUsage.rightOption, pressed: pressed, eventTime: pressedAt,
                                        toggle: f13Binding, hanja: rightOptionBinding,
                                        toggleEnabled: true, paused: false)
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(actions.snapshot == ["hanja", "hanja"])
    }

    @Test("A HID timestamp converts onto NSEvent's clock")
    func hidTimestampsAreUptimeSeconds() {
        // Both are mach absolute time since boot, which is what makes them
        // comparable with a keystroke's own timestamp.
        let now = ProcessInfo.processInfo.systemUptime
        let converted = IOKitManager.uptimeSeconds(fromMachAbsolute: mach_absolute_time())
        #expect(abs(converted - now) < 1, "converted \(converted) against uptime \(now)")

        // An event with no time of its own is treated as pressed now, not in 1970.
        let synthetic = IOKitManager.uptimeSeconds(fromMachAbsolute: 0)
        #expect(abs(synthetic - now) < 1)
    }

    /// Records the press times a callback was handed.
    private final class PressTimes: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [TimeInterval] = []
        func record(_ time: TimeInterval) { lock.withLock { times.append(time) } }
        var snapshot: [TimeInterval] { lock.withLock { times } }
    }
}
