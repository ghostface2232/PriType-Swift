import Testing
@testable import PriTypeCore

/// The 두벌식 automaton on its own: keys in, text out, no host.
@Suite("DubeolsikEngine")
struct DubeolsikEngineTests {
    /// What typing `keys` leaves behind: everything committed, then the syllable
    /// still being typed. "<" is Backspace.
    private func type(_ keys: String) -> (committed: String, composing: String) {
        var engine = DubeolsikEngine()
        var committed = ""
        for key in keys {
            if key == "<" {
                engine.backspace()
                continue
            }
            guard let step = engine.type(key) else {
                Issue.record("\(key) is not a letter key")
                continue
            }
            committed += step.committed.map(String.init) ?? ""
            #expect(step.composing == engine.composing)
        }
        return (committed, engine.composing.map(String.init) ?? "")
    }

    private func text(_ keys: String) -> String {
        let result = type(keys)
        return result.committed + result.composing
    }

    @Test("Syllables, compound vowels and compound finals of the standard layout")
    func standardSyllables() {
        #expect(text("gksrmf") == "한글")
        #expect(text("dkssudgktpdy") == "안녕하세요")
        #expect(text("rhkd") == "광")                  // ㅘ
        #expect(text("dnjs") == "원")                  // ㅝ
        #expect(text("dml") == "의")                   // ㅢ
        #expect(text("ekfr") == "닭")                  // ㄺ
        #expect(text("rkqt") == "값")                  // ㅄ
        #expect(text("rhkfr") == "괅")                 // five keys in one syllable
    }

    @Test("A final moves on to the vowel after it, a compound final by its second half")
    func finalsMoveOn() {
        #expect(text("ekfrk") == "달가")
        #expect(text("rkqtdl") == "값이")
        #expect(text("dlfrdj") == "읽어")
        #expect(text("qkRk") == "바까", "ㄲ typed with Shift moves whole")
        #expect(text("dlTj") == "이써", "and so does ㅆ")
    }

    @Test("Combinations the standard layout does not have stay apart")
    func nonStandardCombinationsStayApart() {
        #expect(text("dkl") == "아ㅣ", "ㅏ + ㅣ is not ㅐ")
        #expect(text("rkrr") == "각ㄱ", "no doubled final ㄱ")
        #expect(text("rktt") == "갓ㅅ", "no doubled final ㅅ")
        #expect(text("rr") == "ㄱㄱ", "no doubled initial")
        #expect(text("rkE") == "가ㄸ", "ㄸ cannot end a syllable")
        #expect(text("ks") == "ㅏㄴ", "a consonant after a lone vowel starts anew (no 모아치기)")
        #expect(text("hk") == "ㅘ", "a lone compound vowel still composes")
    }

    @Test("Shift picks the doubled consonants and ㅒ ㅖ; other letters type as unshifted")
    func shiftedLetters() {
        #expect(text("RkEkQkTkWk") == "까따빠싸짜")
        #expect(text("dOdP") == "얘예")
        #expect(text("DKSSUD") == "안녕", "Shift on the other letters changes nothing")
    }

    @Test("Backspace undoes one keystroke, not one jamo")
    func backspaceUndoesAKeystroke() {
        #expect(type("ekfr<").composing == "달", "닭 → 달")
        #expect(text("ekfr<k") == "다라", "and the ㄹ it leaves moves on like any final")
        #expect(type("do<").composing == "ㅇ", "ㅐ typed with one key goes whole")
        #expect(type("dhk<").composing == "오", "ㅘ typed as ㅗ + ㅏ steps back to ㅗ")
        #expect(type("qkR<").composing == "바", "ㄲ typed with Shift goes whole")
        #expect(type("r<").composing.isEmpty)
        #expect(type("<").composing.isEmpty, "nothing to undo")
        // The syllable a final moved into was typed as two keys.
        let split = type("ekfrk<")
        #expect(split.committed == "달")
        #expect(split.composing == "ㄱ")
    }

    @Test("Flush ends the syllable and returns it")
    func flush() {
        var engine = DubeolsikEngine()
        _ = engine.type("g")
        _ = engine.type("k")
        #expect(engine.flush() == "하")
        #expect(!engine.isComposing)
        #expect(engine.flush() == nil)
    }

    @Test("Keys that are not letters are left alone")
    func nonLetters() {
        var engine = DubeolsikEngine()
        for key: Character in ["1", " ", ";", "é", "ㄱ", "😀"] {
            #expect(engine.type(key) == nil)
        }
        #expect(!engine.isComposing)
    }

    @Test("Every output is one NFC scalar, and Backspace returns to the state before the key",
          arguments: 0..<50)
    func invariants(seed: Int) {
        var state = UInt64(seed + 1) &* 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var engine = DubeolsikEngine()
        for _ in 0..<200 {
            let before = engine
            let key = letters[next(letters.count)]
            guard let step = engine.type(key) else {
                Issue.record("\(key) is a letter")
                return
            }
            for scalar in [step.committed, step.composing].compactMap({ $0 }) {
                let text = String(scalar)
                #expect(text == text.precomposedStringWithCanonicalMapping)
                #expect((0xAC00...0xD7A3).contains(scalar.value) || (0x3131...0x3163).contains(scalar.value))
            }
            #expect(step.composing != nil, "a letter always leaves something composing")
            // Undoing a key that did not commit anything puts the syllable back.
            if step.committed == nil {
                var undone = engine
                undone.backspace()
                #expect(undone.composing == before.composing)
            }
        }
    }
}
