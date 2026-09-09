import Testing
import Cocoa
@testable import PriTypeCore

@Suite("Event tap failure handoff")
struct EventTapFailureTrackerTests {
    @Test("Third disable hands off exactly once and never re-enables the tap")
    func oneShotHandoff() {
        var tracker = EventTapFailureTracker(maxRetries: 3, stableResetInterval: 60)

        #expect(tracker.recordDisable(at: 1) == .reenable(attempt: 1))
        #expect(tracker.recordDisable(at: 2) == .reenable(attempt: 2))
        #expect(tracker.recordDisable(at: 3) == .handoffToIOKit)
        #expect(tracker.recordDisable(at: 4) == .ignore)
        #expect(tracker.hasHandedOff)
    }

    @Test("A stable interval resets transient failure count")
    func stableIntervalReset() {
        var tracker = EventTapFailureTracker(maxRetries: 3, stableResetInterval: 60)

        #expect(tracker.recordDisable(at: 1) == .reenable(attempt: 1))
        #expect(tracker.recordDisable(at: 2) == .reenable(attempt: 2))
        #expect(tracker.recordDisable(at: 63) == .reenable(attempt: 1))
        #expect(!tracker.hasHandedOff)
    }

    @Test("A new CGEventTap lifecycle can recover independently")
    func lifecycleReset() {
        var tracker = EventTapFailureTracker(maxRetries: 1)
        #expect(tracker.recordDisable(at: 1) == .handoffToIOKit)

        tracker.reset()

        #expect(tracker.recordDisable(at: 2) == .handoffToIOKit)
    }
}

@Suite("Modifier physical state")
struct ModifierKeyStateTests {
    @Test("Right Command release is detected while Left Command stays held")
    func sidesAreIndependent() {
        let both: UInt64 = 0x100018
        #expect(ModifierKeyState.isDown(54, flags: both))
        #expect(!ModifierKeyState.isDown(54, flags: 0x100008))
        #expect(ModifierKeyState.isDown(55, flags: 0x100008))
        #expect(!ModifierKeyState.isDown(54, flags: 0))
    }

    @Test("Ordinary typing cannot become a global single-key binding")
    func rejectsTyping() {
        for code: Int64 in [0, 18, 49, 36, 51, 48, 117, 57, 63] {
            #expect(!KeyBinding(keyCode: code, modifiers: 0, displayName: "test").isSafeGlobalBinding)
        }
        #expect(!KeyBinding(keyCode: 0, modifiers: 0x20000, displayName: "Shift A").isSafeGlobalBinding)
        #expect(KeyBinding.defaultToggle.isSafeGlobalBinding)
        #expect(KeyBinding.defaultHanja.isSafeGlobalBinding)
        #expect(ToggleKey.controlSpace.asKeyBinding.isSafeGlobalBinding)
        #expect(KeyBinding(keyCode: 105, modifiers: 0, displayName: "F13").isSafeGlobalBinding)
    }
}

@Suite("Toggle recovery event sequences")
struct ToggleRecoveryEventTests {
    @Test("Lost right release never strips a left Command shortcut")
    func lostRelease() throws {
        let tap = RightCommandSuppressor()
        let press = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: true))
        press.flags = CGEventFlags(rawValue: 0x100010)
        #expect(tap.handleEvent(type: .flagsChanged, event: press,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true) == nil)
        _ = tap.handleEvent(type: .tapDisabledByTimeout, event: press,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true, recoveryFlags: 0)
        let shortcut = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        shortcut.flags = CGEventFlags(rawValue: 0x100008)
        #expect(tap.handleEvent(type: .keyDown, event: shortcut,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true) != nil)
        #expect(shortcut.flags.contains(.maskCommand))
        // A subsequent right press is recognized, rather than stuck in held state.
        #expect(tap.handleEvent(type: .flagsChanged, event: press,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true) == nil)
    }

    @Test("Holding both Commands preserves left shortcut semantics")
    func bothCommands() throws {
        let tap = RightCommandSuppressor()
        let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        key.flags = CGEventFlags(rawValue: 0x100018)
        _ = tap.handleEvent(type: .keyDown, event: key,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true)
        #expect(key.flags.contains(.maskCommand))
        #expect(!ModifierKeyState.isDown(54, flags: key.flags.rawValue))
        #expect(ModifierKeyState.isDown(55, flags: key.flags.rawValue))
        key.flags = CGEventFlags(rawValue: 0x100010)
        _ = tap.handleEvent(type: .keyDown, event: key,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true)
        #expect(!key.flags.contains(.maskCommand))
    }

    @Test("Later explicit mode selection invalidates a delayed old controller value")
    func oldModeCannotOverrideNewSelection() {
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let pending = DeferredInputMode(mode: .english, revision: composer.modeSelectionRevision)
        #expect(pending.resolve(currentRevision: composer.modeSelectionRevision) == .english)
        composer.setInputMode(.korean)
        #expect(pending.resolve(currentRevision: composer.modeSelectionRevision) == nil)
    }

    @Test("Applying a pending mode equal to the current one still retires older pendings")
    func sameModePendingStillBumpsRevision() throws {
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        #expect(composer.inputMode == .korean)
        // An old English value and a newer Korean value are both parked while
        // neither controller owns the engine, so both carry the same revision.
        let staleEnglish = DeferredInputMode(mode: .english, revision: composer.modeSelectionRevision)
        let recentKorean = DeferredInputMode(mode: .korean, revision: composer.modeSelectionRevision)

        // The newer controller activates first. Korean is already the current mode,
        // but applying it must still count as an explicit selection.
        let resolvedKorean = recentKorean.resolve(currentRevision: composer.modeSelectionRevision)
        #expect(resolvedKorean == .korean)
        composer.setInputMode(try #require(resolvedKorean))

        // The older controller activates afterwards; its English value is now stale.
        #expect(staleEnglish.resolve(currentRevision: composer.modeSelectionRevision) == nil)
        #expect(composer.inputMode == .korean)
    }
}
