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
        tap.onToggle = { actions.record("toggle") }
        tap.onHanjaLookup = { actions.record("hanja") }
        let toggle = KeyBinding(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue, displayName: "Control Space")
        let hanja = KeyBinding(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue, displayName: "Option Space")
        for flags: CGEventFlags in [.maskAlternate, .maskControl] {
            let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
            event.flags = flags
            #expect(tap.handleEvent(type: .keyDown, event: event, toggle: toggle, hanja: hanja,
                toggleEnabled: true, excludedOverride: false) == nil)
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

    @Test("An identical binding fires once, with toggle priority")
    func identicalBindings() async throws {
        let tap = RightCommandSuppressor()
        let actions = ShortcutActions()
        tap.onToggle = { actions.record("toggle") }
        tap.onHanjaLookup = { actions.record("hanja") }
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
