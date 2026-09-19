import Cocoa
import Testing
@testable import PriTypeCore

/// Hangul composition follows key position, not the active Latin layout.
@Suite("Key position composition")
struct KeyPositionTests {
    private func makeComposer() -> (HangulComposer, MockComposerDelegate) {
        (HangulComposer(configuration: MockConfiguration()), MockComposerDelegate())
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

    @Test("Keys outside the letter block keep the system's characters")
    func nonLetterKeysAreUnmapped() {
        #expect(QwertyKeyMap.character(for: 83, shifted: false) == nil)   // keypad 1
        #expect(QwertyKeyMap.character(for: 18, shifted: true) == nil)    // 1 / !
        #expect(QwertyKeyMap.character(for: 41, shifted: false) == nil)   // ; (ö on German)
        #expect(QwertyKeyMap.character(for: 15, shifted: false) == "r")
        #expect(QwertyKeyMap.character(for: 15, shifted: true) == "R")
    }

    @Test("A national character commits the syllable and reaches the host as typed")
    func germanUmlautPassesThrough() {
        let (composer, delegate) = makeComposer()
        type([("r", 15, []), ("k", 40, [])], into: composer, delegate)
        // German layout: the key at US ";" types ö.
        let handled = composer.handle(TestEventFactory.keyEvent(char: "ö", keyCode: 41)!, delegate: delegate)
        #expect(delegate.insertedTexts == ["가"])
        #expect(!handled, "ö must reach the host from the user's layout, not become ';'")
    }

    @Test("Layout punctuation is inserted as the layout typed it")
    func azertyPunctuation() {
        let (composer, delegate) = makeComposer()
        // AZERTY: the unshifted key at US "1" types &.
        _ = composer.handle(TestEventFactory.keyEvent(char: "&", keyCode: 18)!, delegate: delegate)
        #expect(delegate.insertedTexts == ["&"])
    }

    @Test("A letter on a non-letter key is never read as a jamo")
    func letterOnPunctuationKeyStaysLiteral() {
        let (composer, delegate) = makeComposer()
        // AZERTY puts "m" on the key at US ";" — 두벌식 has no jamo there.
        _ = composer.handle(TestEventFactory.keyEvent(char: "m", keyCode: 41)!, delegate: delegate)
        #expect(delegate.insertedTexts == ["m"])
        #expect(delegate.markedText.isEmpty)
    }

    @Test("AZERTY: once the comma key types ㅡ, punctuation comes from the US positions")
    func azertyGetsUSPunctuation() {
        let (composer, delegate) = makeComposer()
        // AZERTY types "," at the M key (46), where 두벌식 has ㅡ, and ";" at
        // the US comma key (43), so the comma has no other key.
        type([(",", 46, [])], into: composer, delegate)
        #expect(delegate.markedText == "ㅡ")
        type([(";", 43, []), ("m", 41, []), (":", 47, [.shift]), ("&", 18, [])], into: composer, delegate)
        #expect(delegate.insertedTexts == ["ㅡ", ",", ";", ">", "1"])
    }

    @Test("Dvorak: ' , . on Q W E type jamo, and the US keys give the punctuation back")
    func dvorakGetsUSPunctuation() {
        let (composer, delegate) = makeComposer()
        // Dvorak types "'" at Q (12), and "w" / "v" / "z" at US , . / (43, 47, 44).
        type([("'", 12, [])], into: composer, delegate)
        #expect(delegate.markedText == "ㅂ")
        type([("w", 43, []), ("v", 47, []), ("Z", 44, [.shift])], into: composer, delegate)
        #expect(delegate.insertedTexts == ["ㅂ", ",", ".", "?"])
    }

    @Test("A QWERTY-lettered layout keeps its own punctuation and national letters")
    func germanKeepsItsKeys() {
        let (composer, delegate) = makeComposer()
        // German QWERTZ swaps Y and Z, both letters; ü and - sit off the letter keys.
        type([("z", 16, []), ("y", 6, [])], into: composer, delegate)
        let umlaut = composer.handle(TestEventFactory.keyEvent(char: "ü", keyCode: 33)!, delegate: delegate)
        #expect(!umlaut, "ü reaches the host from the user's layout")
        _ = composer.handle(TestEventFactory.keyEvent(char: "-", keyCode: 44)!, delegate: delegate)
        #expect(delegate.insertedTexts.last == "-")
    }

    @Test("A letter after an unused dead accent is not taken for punctuation on the letter key")
    func deadKeyResidueIsNoEvidence() {
        let (composer, delegate) = makeComposer()
        // German: ^ (dead) then R arrives as "^r".
        type([("^r", 15, []), ("k", 40, [])], into: composer, delegate)
        #expect(delegate.markedText == "가")
        let umlaut = composer.handle(TestEventFactory.keyEvent(char: "ü", keyCode: 33)!, delegate: delegate)
        #expect(!umlaut, "the layout is still taken as QWERTY-lettered")
    }

    @Test("The verdict follows the layout: letters on the letter keys again restore it")
    func layoutVerdictFollowsChange() {
        let (composer, delegate) = makeComposer()
        type([(",", 46, [])], into: composer, delegate)       // AZERTY
        type([(";", 43, [])], into: composer, delegate)
        #expect(delegate.insertedTexts.last == ",")
        type([("m", 46, [])], into: composer, delegate)       // the client now types QWERTY
        type([(";", 43, [])], into: composer, delegate)
        #expect(delegate.insertedTexts.last == ";", "the layout's own character again")
    }
}
