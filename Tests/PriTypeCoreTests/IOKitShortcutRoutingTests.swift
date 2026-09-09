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

    private func press(_ state: inout HIDShortcutState, _ usage: UInt32, _ pressed: Bool,
                       device: UInt64 = 1, toggle: KeyBinding, hanja: KeyBinding,
                       toggleEnabled: Bool = true, paused: Bool = false) -> HIDShortcutState.Action? {
        state.consume(usage: usage, pressed: pressed, device: device, toggle: toggle, hanja: hanja,
                      toggleEnabled: toggleEnabled, paused: paused)
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
        state.removeDevice(7)
        // The stale `A` must no longer count as an ordinary key held down.
        #expect(press(&state, HIDUsage.rightCommand, true, device: 1,
                      toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
        #expect(press(&state, HIDUsage.rightCommand, false, device: 1,
                      toggle: rightCommandBinding, hanja: rightOptionBinding) == .toggle)
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
        state.removeDevice(7)
        #expect(press(&state, HIDUsage.rightCommand, false, device: 7,
                      toggle: rightCommandBinding, hanja: rightOptionBinding) == nil)
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
        manager.onRightCommandToggle = { actions.record("toggle") }
        manager.onRightOptionHanja = { actions.record("hanja") }

        manager.handleKeyboardEvent(usage: HIDUsage.f13, pressed: true, toggle: f13Binding,
                                    hanja: rightOptionBinding, toggleEnabled: true, paused: false)
        manager.handleKeyboardEvent(usage: HIDUsage.rightOption, pressed: true, toggle: f13Binding,
                                    hanja: rightOptionBinding, toggleEnabled: true, paused: false)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(actions.snapshot == ["toggle", "hanja"])
    }
}
