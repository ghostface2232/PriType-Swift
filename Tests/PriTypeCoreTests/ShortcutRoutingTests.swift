import Cocoa
import Testing
@testable import PriTypeCore

private final class ShortcutActions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) { lock.withLock { values.append(value) } }
    var snapshot: [String] { lock.withLock { values } }
}

@Suite("Shortcut event routing")
@MainActor
struct ShortcutRoutingTests {
    @Test("Different modifiers on Space dispatch the matching action")
    func sharedPhysicalKey() async throws {
        let tap = RightCommandSuppressor()
        let actions = ShortcutActions()
        tap.onToggle = { _ in actions.record("toggle") }
        tap.onHanjaLookup = { _ in actions.record("hanja") }
        let toggle = KeyBinding(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue, displayName: "Control Space")
        let hanja = KeyBinding(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue, displayName: "Option Space")
        // Check each event's action on its own, not just the final list.
        for (flags, expected) in [(CGEventFlags.maskAlternate, ["hanja"]), (.maskControl, ["hanja", "toggle"])] {
            let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
            event.flags = flags
            #expect(tap.handleEvent(type: .keyDown, event: event, toggle: toggle, hanja: hanja,
                toggleEnabled: true, excludedOverride: false) == nil)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(actions.snapshot == expected)
        }
        let plain = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        plain.flags = []
        #expect(tap.handleEvent(type: .keyDown, event: plain, toggle: toggle, hanja: hanja,
            toggleEnabled: true, excludedOverride: false) != nil)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(actions.snapshot == ["hanja", "toggle"])
    }

    @Test("Holding an ordinary toggle key fires once and stays suppressed")
    func autorepeatFiresOnce() async throws {
        let tap = RightCommandSuppressor()
        let actions = ShortcutActions()
        tap.onToggle = { _ in actions.record("toggle") }
        tap.onHanjaLookup = { _ in actions.record("hanja") }
        let binding = KeyBinding(keyCode: 105, modifiers: 0, displayName: "F13")
        let hanja = KeyBinding(keyCode: 61, modifiers: 0, displayName: "Right Option")
        let first = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 105, keyDown: true))
        #expect(tap.handleEvent(type: .keyDown, event: first, toggle: binding, hanja: hanja,
            toggleEnabled: true, excludedOverride: false) == nil)
        for _ in 0..<3 {
            let repeated = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 105, keyDown: true))
            repeated.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            // Still swallowed, so the key never reaches the app, but no new toggle.
            #expect(tap.handleEvent(type: .keyDown, event: repeated, toggle: binding, hanja: hanja,
                toggleEnabled: true, excludedOverride: false) == nil)
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(actions.snapshot == ["toggle"])
    }

    @Test("An unrelated held key is still delivered")
    func autorepeatOfUnboundKeyPassesThrough() async throws {
        let tap = RightCommandSuppressor()
        let actions = ShortcutActions()
        tap.onToggle = { _ in actions.record("toggle") }
        tap.onHanjaLookup = { _ in actions.record("hanja") }
        // Space alone does not match Control+Space, so holding it must type.
        let toggle = KeyBinding(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue, displayName: "Control Space")
        let hanja = KeyBinding(keyCode: 61, modifiers: 0, displayName: "Right Option")
        let repeated = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        repeated.flags = []
        repeated.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        #expect(tap.handleEvent(type: .keyDown, event: repeated, toggle: toggle, hanja: hanja,
            toggleEnabled: true, excludedOverride: false) != nil)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(actions.snapshot.isEmpty)
    }

    @Test("An identical binding fires once, with toggle priority")
    func identicalBindings() async throws {
        let tap = RightCommandSuppressor()
        let actions = ShortcutActions()
        tap.onToggle = { _ in actions.record("toggle") }
        tap.onHanjaLookup = { _ in actions.record("hanja") }
        let binding = KeyBinding(keyCode: 105, modifiers: 0, displayName: "F13")
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 105, keyDown: true))
        #expect(tap.handleEvent(type: .keyDown, event: event, toggle: binding, hanja: binding,
            toggleEnabled: true, excludedOverride: false) == nil)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(actions.snapshot == ["toggle"])
    }
}
