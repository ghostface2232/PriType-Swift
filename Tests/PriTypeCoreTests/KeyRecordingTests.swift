import Cocoa
import Testing
import os
@testable import PriTypeCore

@Suite("Key recording state")
struct KeyRecordingTests {
    @Test("Control followed by Space records the combination, not Control")
    func recordsShortcut() {
        var state = KeyRecordingState()
        #expect(state.consume(keyCode: 59, flags: 0x40001, isModifierChange: true) == nil)
        #expect(state.consume(keyCode: 49, flags: 0x40001, isModifierChange: false)
            == .init(keyCode: 49, modifiers: 0x40000))
        #expect(state.consume(keyCode: 59, flags: 0, isModifierChange: true) == nil)
        #expect(state.consume(keyCode: 105, flags: 0, isModifierChange: false) == nil)
    }

    @Test("A standalone right Command is recorded only on release")
    func standaloneModifier() {
        var state = KeyRecordingState()
        #expect(state.consume(keyCode: 54, flags: 0x100010, isModifierChange: true) == nil)
        #expect(state.consume(keyCode: 54, flags: 0, isModifierChange: true)
            == .init(keyCode: 54, modifiers: 0))
    }

    @Test("Multiple modifiers remain available for a regular key")
    func multipleModifiers() {
        var state = KeyRecordingState()
        #expect(state.consume(keyCode: 55, flags: 0x100008, isModifierChange: true) == nil)
        #expect(state.consume(keyCode: 56, flags: 0x12000A, isModifierChange: true) == nil)
        #expect(state.consume(keyCode: 20, flags: 0x12000A, isModifierChange: false)
            == .init(keyCode: 20, modifiers: 0x120000))
    }

    @Test("Bare typing is rejected without preventing another recording attempt")
    func invalidThenValid() {
        var state = KeyRecordingState()
        #expect(state.consume(keyCode: 0, flags: 0, isModifierChange: false)?.keyCode == 0)
        #expect(state.consume(keyCode: 59, flags: 0x40001, isModifierChange: true) == nil)
        #expect(state.consume(keyCode: 49, flags: 0x40001, isModifierChange: false)?.modifiers == 0x40000)
    }

    @Test("Releases of modifiers held before recording do not create a binding")
    func unrelatedRelease() {
        var state = KeyRecordingState()
        #expect(state.consume(keyCode: 55, flags: 0, isModifierChange: true) == nil)
    }
}

@Suite("Event tap recording")
@MainActor
struct EventTapRecordingTests {
    @Test("Tap captures a shortcut even when its modifier is the current toggle")
    func recordsCurrentToggleCombo() async throws {
        let tap = RightCommandSuppressor()
        // The callback is handed to `DispatchQueue.main.async` from the tap
        // thread, so it has to be `@Sendable` — a captured `var` cannot be its
        // destination, however reliably this test happens to end up on main.
        let recorded = RecordedKeys()
        tap.onKeyRecorded = { code, modifiers in
            recorded.append(.init(keyCode: code, modifiers: modifiers))
        }
        tap.isRecordingKey = true
        for (code, flags, type): (CGKeyCode, UInt64, CGEventType) in [
            (54, 0x100010, .flagsChanged), (49, 0x100010, .keyDown), (54, 0, .flagsChanged)
        ] {
            let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
            event.flags = CGEventFlags(rawValue: flags)
            #expect(tap.handleEvent(type: type, event: event, toggle: .defaultToggle, hanja: .defaultHanja,
                toggleEnabled: true, excludedOverride: false) == nil)
        }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(recorded.value == [.init(keyCode: 49, modifiers: 0x100000)])
    }

    /// Somewhere the recording callback can leave its answer from any thread.
    private final class RecordedKeys: Sendable {
        private let keys = OSAllocatedUnfairLock<[KeyRecordingState.RecordedKey]>(initialState: [])
        var value: [KeyRecordingState.RecordedKey] { keys.withLock { $0 } }
        func append(_ key: KeyRecordingState.RecordedKey) { keys.withLock { $0.append(key) } }
    }
}
