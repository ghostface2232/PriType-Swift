import Cocoa
import Testing
@testable import PriTypeCore

/// Hangul composition follows key position, not the active Latin layout.
@Suite("Key position composition")
struct KeyPositionTests {
    private func makeComposer() -> (HangulComposer, MockComposerDelegate) {
        (HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration()), MockComposerDelegate())
    }

    private func type(_ keys: [(char: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags)],
                      into composer: HangulComposer, _ delegate: MockComposerDelegate) {
        for key in keys {
            _ = composer.handle(TestEventFactory.keyEvent(char: key.char, keyCode: key.keyCode,
                                                          modifiers: key.modifiers)!, delegate: delegate)
        }
    }

    @Test("A Dvorak layout still types 두벌식 by key position")
    func dvorakLayout() {
        let (composer, delegate) = makeComposer()
        // Dvorak produces "," at the R key (15) and "t" at the K key (40).
        type([(",", 15, []), ("t", 40, [])], into: composer, delegate)
        #expect(delegate.markedText == "가")
    }

    @Test("Caps Lock does not double consonants")
    func capsLockIgnored() {
        let (composer, delegate) = makeComposer()
        // With Caps Lock on the system reports "R" and "K" without Shift.
        type([("R", 15, [.capsLock]), ("K", 40, [.capsLock])], into: composer, delegate)
        #expect(delegate.markedText == "가")
    }

    @Test("Shift still selects the doubled consonant, with or without Caps Lock")
    func shiftSelectsUpperRow() {
        for modifiers: NSEvent.ModifierFlags in [[.shift], [.shift, .capsLock]] {
            let (composer, delegate) = makeComposer()
            type([("R", 15, modifiers), ("k", 40, [])], into: composer, delegate)
            #expect(delegate.markedText == "까")
        }
    }

    @Test("Keys outside the main block keep the system's characters")
    func keypadKeepsSystemCharacters() {
        #expect(QwertyKeyMap.character(for: 83, shifted: false) == nil)   // keypad 1
        #expect(QwertyKeyMap.character(for: 18, shifted: true) == "!")
        #expect(QwertyKeyMap.character(for: 15, shifted: false) == "r")
    }
}
