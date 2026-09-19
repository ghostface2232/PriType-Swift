import Testing
import Cocoa
@testable import PriTypeCore

// MARK: - HangulComposer Tests

@Suite("HangulComposer")
struct HangulComposerTests {
    
    // MARK: - Basic Composition Tests
    
    @Test("Single choseong input")
    func singleChoseong() {
        let (composer, delegate) = makeComposer()
        let event = TestEventFactory.keyEvent(char: "r", keyCode: 15)!
        let handled = composer.handle(event, delegate: delegate)
        
        #expect(handled, "Choseong should be handled")
        #expect(
            delegate.markedText == "ㄱ" || 
            delegate.markedText == "\u{3131}" || 
            delegate.markedText == "\u{1100}",
            "Expected ㄱ, got '\(delegate.markedText)'"
        )
    }
    
    @Test("Choseong + Jungseong = syllable")
    func choseongPlusJungseong() {
        let (composer, delegate) = makeComposer()
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: delegate)
        
        #expect(delegate.markedText == "가")
    }
    
    @Test("Full syllable with jongseong")
    func fullSyllable() {
        let (composer, delegate) = makeComposer()
        _ = composer.handle(TestEventFactory.keyEvent(char: "d", keyCode: 2)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "s", keyCode: 1)!, delegate: delegate)
        
        #expect(delegate.markedText == "안")
    }
    
    // MARK: - Syllable Boundary Tests
    
    @Test("Syllable boundary commits previous and starts new")
    func syllableBoundary() {
        let (composer, delegate) = makeComposer()
        _ = composer.handle(TestEventFactory.keyEvent(char: "d", keyCode: 2)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "s", keyCode: 1)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "s", keyCode: 1)!, delegate: delegate)
        
        #expect(delegate.insertedTexts.last == "안")
        #expect(
            delegate.markedText == "ㄴ" || 
            delegate.markedText == "\u{3134}" ||
            delegate.markedText == "\u{1102}" ||
            delegate.markedText == "\u{11AB}",
            "Expected ㄴ, got '\(delegate.markedText)'"
        )
    }
    
    // MARK: - Backspace Tests
    
    @Test("Backspace during composition removes last jamo")
    func backspaceInComposition() {
        let (composer, delegate) = makeComposer()
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: delegate)
        
        #expect(delegate.markedText == "가")
        
        let backspace = TestEventFactory.keyEvent(char: "\u{7F}", keyCode: KeyCode.backspace)!
        let handled = composer.handle(backspace, delegate: delegate)
        
        #expect(handled, "Backspace should be handled during composition")
        #expect(
            delegate.markedText == "ㄱ" || 
            delegate.markedText == "\u{3131}" ||
            delegate.markedText == "\u{1100}",
            "Expected ㄱ after backspace, got '\(delegate.markedText)'"
        )
    }
    
    @Test("Backspace on empty context passes through")
    func backspaceOnEmptyContext() {
        let (composer, delegate) = makeComposer()
        let backspace = TestEventFactory.keyEvent(char: "\u{7F}", keyCode: KeyCode.backspace)!
        let handled = composer.handle(backspace, delegate: delegate)
        
        #expect(!handled, "Backspace on empty context should pass through")
    }
    
    // MARK: - Mode Toggle Tests
    
    @Test("Set input mode")
    func setInputMode() {
        let (composer, _) = makeComposer()
        #expect(composer.inputMode == .korean)
        
        composer.setInputMode(.english)
        #expect(composer.inputMode == .english)
        
        composer.setInputMode(.korean)
        #expect(composer.inputMode == .korean)
    }
    
    @Test("English mode passes through ordinary printable keys")
    func englishModePassthrough() {
        let (composer, delegate) = makeComposer()
        composer.setInputMode(.english)
        #expect(composer.inputMode == .english)
        delegate.fullText = "middle"
        
        let event = TestEventFactory.keyEvent(char: "a", keyCode: 0)!
        let handled = composer.handle(event, delegate: delegate)

        #expect(!handled, "English fake mode should pass ordinary printable keys through")
        #expect(delegate.insertedTexts.isEmpty)
        #expect(delegate.markedText.isEmpty)
    }

    @Test("English conveniences remain host-owned at empty and sentence-boundary fields")
    func englishConveniencesPassThrough() {
        let (composer, delegate) = makeComposer()
        composer.setInputMode(.english)
        for text in ["", "Hello. ", "h ", "-", "Hello"] {
            for (char, code): (String, UInt16) in [("h", 4), ("w", 13), ("\"", 39), ("-", 27), (" ", KeyCode.space)] {
                delegate.fullText = text
                #expect(!composer.handle(TestEventFactory.keyEvent(char: char, keyCode: code)!, delegate: delegate))
                #expect(delegate.fullText == text)
            }
        }
        #expect(delegate.insertedTexts.isEmpty)
        #expect(delegate.markedText.isEmpty)
    }

    @Test("Deleting preedit preserves committed text for Hanja lookup")
    func backspacePreservesCommittedBuffer() {
        let (composer, delegate) = makeComposer()
        composer.localTextBuffer = "대한"
        delegate.fullText = "대한"
        #expect(composer.handle(TestEventFactory.keyEvent(char: "a", keyCode: 0)!, delegate: delegate))
        // The last jamo is committed and the key passed on; the host's own
        // deleteBackward then removes it (Apple's Korean IME does the same).
        #expect(!composer.handle(TestEventFactory.keyEvent(char: "\u{7F}", keyCode: KeyCode.backspace)!, delegate: delegate))
        #expect(delegate.insertedTexts == ["ㅁ"])
        delegate.fullText.removeLast()   // the host's deleteBackward
        #expect(composer.localTextBuffer == "대한")
        #expect(delegate.fullText == "대한")
        #expect(!composer.hasActiveComposition)
        #expect(!composer.handle(TestEventFactory.keyEvent(char: "\u{7F}", keyCode: KeyCode.backspace)!, delegate: delegate))
        #expect(composer.localTextBuffer == "대")
    }

    @Test("Full preedit decomposition never touches committed text or the document")
    func backspaceDecompositionKeepsCommittedText() {
        let (composer, delegate) = makeComposer()
        composer.localTextBuffer = "한글"
        delegate.fullText = "한글"

        // Build a three-jamo syllable on top of already committed text.
        for (char, code): (String, UInt16) in [("d", 2), ("k", 40), ("s", 1)] {  // ㅇ, 아, 안
            #expect(composer.handle(TestEventFactory.keyEvent(char: char, keyCode: code)!, delegate: delegate))
        }
        #expect(composer.hasActiveComposition)

        // Every backspace that leaves a jamo behind only shrinks the marked text.
        // The one that removes the last jamo commits it and passes the key on, so
        // the host deletes it itself — never a bare cancel of the marked text,
        // which Figma turns into a commit. Either way the committed buffer and,
        // once the host has deleted, the document are untouched.
        // Bounded: an engine backspace that stops consuming would otherwise spin
        // here forever and wedge the run instead of failing.
        var seenMarked: [String] = []
        for _ in 0..<8 {
            guard composer.hasActiveComposition else { break }
            let handled = composer.handle(TestEventFactory.keyEvent(char: "\u{7F}", keyCode: KeyCode.backspace)!, delegate: delegate)
            if composer.hasActiveComposition {
                #expect(handled)
                seenMarked.append(delegate.markedText)
            } else {
                #expect(!handled, "the emptying backspace must go to the host")
                #expect(delegate.insertedTexts == ["ㅇ"])
                delegate.fullText.removeLast()   // the host's deleteBackward
            }
            #expect(composer.localTextBuffer == "한글")
        }
        #expect(delegate.fullText == "한글")
        #expect(!composer.hasActiveComposition, "composition did not drain within 8 backspaces")
        #expect(seenMarked.count >= 2, "expected stepwise decomposition, saw \(seenMarked)")
    }

    @Test("Backspace after an empty preedit never deletes host text itself")
    func backspaceAfterEmptyPreeditDefersToHost() {
        let (composer, delegate) = makeComposer()
        composer.localTextBuffer = "가나"
        delegate.fullText = "가나"

        // With nothing composing the key is passed through: the host performs the
        // deletion. PriType may only trim its own shadow buffer.
        #expect(!composer.handle(TestEventFactory.keyEvent(char: "\u{7F}", keyCode: KeyCode.backspace)!, delegate: delegate))
        #expect(composer.localTextBuffer == "가")
        #expect(delegate.fullText == "가나", "PriType must not delete host text on a passed-through backspace")

        #expect(!composer.handle(TestEventFactory.keyEvent(char: "\u{7F}", keyCode: KeyCode.backspace)!, delegate: delegate))
        #expect(composer.localTextBuffer.isEmpty)
        #expect(delegate.fullText == "가나")

        // Underflow must stay safe once the shadow buffer is exhausted.
        #expect(!composer.handle(TestEventFactory.keyEvent(char: "\u{7F}", keyCode: KeyCode.backspace)!, delegate: delegate))
        #expect(composer.localTextBuffer.isEmpty)
        #expect(delegate.fullText == "가나")
    }

    @Test("Idle Korean Space reaches host shortcuts")
    func idleSpacePassThrough() {
        let (composer, delegate) = makeComposer()
        #expect(!composer.handle(TestEventFactory.keyEvent(char: " ", keyCode: KeyCode.space)!, delegate: delegate))
        #expect(delegate.insertedTexts.isEmpty)
    }

    @Test("English mode passes every printable key through without inserting")
    func englishModePassesAllPrintableThrough() {
        let (composer, delegate) = makeComposer()
        composer.setInputMode(.english)

        // All printable keys flow to the host untouched.
        let cases: [(String, UInt16)] = [
            ("Z", 6), ("r", 15), ("k", 40),   // including 2-bulsik jamo keys
            ("1", 18), ("0", 29), ("!", 18), ("@", 19),
            (".", 47), (",", 43), (";", 41), ("/", 44),
            (" ", KeyCode.space)
        ]

        for (char, keyCode) in cases {
            delegate.fullText = "mid"
            let event = TestEventFactory.keyEvent(char: char, keyCode: keyCode)!
            #expect(!composer.handle(event, delegate: delegate), "‘\(char)’ should pass through in English mode")
        }

        #expect(delegate.insertedTexts.isEmpty, "English mode must not insert text")
        #expect(delegate.markedText.isEmpty, "English mode must not set marked text")
    }

    @Test("English mode passes through modifier combos without inserting")
    func englishModeModifierComboPassthrough() {
        let (composer, delegate) = makeComposer()
        composer.setInputMode(.english)

        let cmdC = TestEventFactory.keyEvent(char: "c", keyCode: 8, modifiers: [.command])!
        let ctrlA = TestEventFactory.keyEvent(char: "a", keyCode: 0, modifiers: [.control])!

        #expect(!composer.handle(cmdC, delegate: delegate))
        #expect(!composer.handle(ctrlA, delegate: delegate))
        #expect(delegate.insertedTexts.isEmpty)
        #expect(delegate.markedText.isEmpty)
    }

    // MARK: - Mode Transition Tests

    @Test("Switching to English commits the active Korean composition once")
    func switchToEnglishCommitsActiveComposition() {
        let (composer, delegate) = makeComposer()

        // Compose "가" (still in marked/preedit state, not yet committed).
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: delegate)
        #expect(delegate.markedText == "가")
        #expect(delegate.insertedTexts.isEmpty)

        composer.setInputMode(.english)

        #expect(composer.inputMode == .english)
        #expect(delegate.insertedTexts == ["가"], "Pending composition must commit exactly once on switch")
        #expect(delegate.markedText.isEmpty, "Marked text must be cleared after commit")
    }

    @Test("Moving the caret or running a shortcut empties the Hanja buffer, in either mode")
    func caretMovesAndShortcutsClearBuffer() {
        // The buffer stands for the text before the caret. After any of these the
        // caret may be elsewhere (or the text changed), so a Hanja lookup must not
        // convert what was typed before them.
        let keys: [(String, NSEvent)] = [
            ("←", TestEventFactory.keyEvent(char: "\u{F702}", keyCode: KeyCode.leftArrow)!),
            ("Tab", TestEventFactory.keyEvent(char: "\t", keyCode: KeyCode.tab)!),
            ("Return", TestEventFactory.keyEvent(char: "\r", keyCode: KeyCode.`return`)!),
            ("Home (Fn+←)", TestEventFactory.keyEvent(char: "\u{F729}", keyCode: 115)!),
            ("⌘V", TestEventFactory.keyEvent(char: "v", keyCode: 9, modifiers: [.command])!)
        ]
        for mode in [InputMode.korean, .english] {
            for (name, event) in keys {
                let (composer, delegate) = makeComposer()
                composer.setInputMode(mode)
                composer.localTextBuffer = "한국"
                _ = composer.handle(event, delegate: delegate)
                #expect(composer.localTextBuffer.isEmpty, "\(name) in \(mode) mode left '\(composer.localTextBuffer)'")
            }
        }
    }

    @Test("setInputMode clears the local text buffer")
    func setInputModeClearsLocalBuffer() {
        let (composer, _) = makeComposer()
        composer.localTextBuffer = "stale"
        composer.setInputMode(.english)
        #expect(composer.localTextBuffer == "")
    }

    @Test("Korean → English → Korean round-trips cleanly")
    func koreanEnglishKoreanRoundTrip() {
        let (composer, delegate) = makeComposer()

        // Korean: compose and commit "가".
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: delegate)
        composer.setInputMode(.english)
        #expect(delegate.insertedTexts == ["가"])

        // English: a printable key passes through, inserting nothing more.
        #expect(!composer.handle(TestEventFactory.keyEvent(char: "a", keyCode: 0)!, delegate: delegate))
        #expect(delegate.insertedTexts == ["가"], "English mode must not insert")

        // Back to Korean: composition works again from a clean state.
        composer.setInputMode(.korean)
        _ = composer.handle(TestEventFactory.keyEvent(char: "d", keyCode: 2)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "s", keyCode: 1)!, delegate: delegate)
        #expect(delegate.markedText == "안")
    }

    // MARK: - Modifier Key Tests
    
    @Test("Command+key passes through")
    func modifierKeyPassthrough() {
        let (composer, delegate) = makeComposer()
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: delegate)
        
        let cmdEvent = TestEventFactory.keyEvent(char: "s", keyCode: 1, modifiers: [.command])!
        let handled = composer.handle(cmdEvent, delegate: delegate)
        
        #expect(!handled, "Command+key should pass through")
    }
    
    // MARK: - Special Key Tests
    
    @Test("Return key commits composition")
    func returnKeyCommit() {
        let (composer, delegate) = makeComposer()
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: delegate)
        
        let returnEvent = TestEventFactory.keyEvent(char: "\r", keyCode: KeyCode.`return`)!
        let handled = composer.handle(returnEvent, delegate: delegate)
        
        #expect(!handled, "Return should pass through after committing composition")
        #expect(delegate.insertedTexts.contains("가"))
        #expect(delegate.insertedTexts.filter { $0 == "\n" }.isEmpty)
        #expect(delegate.markedText.isEmpty)
    }

    @Test("Return key uses GoodNotes compatibility newline")
    func returnKeyGoodNotesCompatibility() {
        let (composer, delegate) = makeComposer()
        composer.markKeystroke(bundleId: "com.goodnotesapp.x")
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: delegate)

        let returnEvent = TestEventFactory.keyEvent(char: "\r", keyCode: KeyCode.`return`)!
        let handled = composer.handle(returnEvent, delegate: delegate)

        #expect(handled, "GoodNotes compatibility should consume Return after direct newline insertion")
        #expect(delegate.insertedTexts.contains("가"))
        #expect(delegate.insertedTexts.filter { $0 == "\n" }.count == 1)
        #expect(delegate.markedText.isEmpty)
    }

    @Test("Return key commits and consumes original Return for Hermes")
    func returnKeyHermesCompatibility() {
        let (composer, delegate) = makeComposer()
        composer.markKeystroke(bundleId: "com.nousresearch.hermes")
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: delegate)

        let returnEvent = TestEventFactory.keyEvent(char: "\r", keyCode: KeyCode.`return`)!
        let handled = composer.handle(returnEvent, delegate: delegate)

        #expect(handled, "Hermes compatibility should consume Return after committing Hangul composition")
        #expect(delegate.insertedTexts.contains("가"))
        #expect(delegate.insertedTexts.filter { $0 == "\n" }.isEmpty)
        #expect(delegate.markedText.isEmpty)
    }

    @Test("Return key passes through without composition")
    func returnKeyPassthroughWithoutComposition() {
        let (composer, delegate) = makeComposer()

        let returnEvent = TestEventFactory.keyEvent(char: "\r", keyCode: KeyCode.`return`)!
        let handled = composer.handle(returnEvent, delegate: delegate)

        #expect(!handled, "Return should pass through when there is no composition")
        #expect(delegate.insertedTexts.isEmpty)
    }
    
    @Test("Arrow key commits composition")
    func arrowKeyCommit() {
        let (composer, delegate) = makeComposer()
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: delegate)
        
        let arrowEvent = TestEventFactory.keyEvent(char: "\u{F702}", keyCode: KeyCode.leftArrow)!
        let handled = composer.handle(arrowEvent, delegate: delegate)
        
        #expect(!handled, "Arrow key should pass through")
        #expect(delegate.insertedTexts.contains("가"))
    }
    
    // MARK: - Composition Commit on Shortcut Tests (Regression)
    
    @Test("Cmd+Arrow commits composition before pass-through")
    func cmdArrowCommitsComposition() {
        let (composer, delegate) = makeComposer()
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: delegate)
        #expect(delegate.markedText == "가")
        #expect(delegate.insertedTexts.isEmpty)
        
        let cmdLeft = TestEventFactory.keyEvent(char: "\u{F702}", keyCode: KeyCode.leftArrow, modifiers: [.command])!
        let handled = composer.handle(cmdLeft, delegate: delegate)
        
        #expect(!handled, "Cmd+Arrow passes through")
        #expect(delegate.insertedTexts.contains("가"), "Composition should be committed")
        #expect(delegate.markedText == "")
    }
    
    @Test("Option+Arrow commits composition before pass-through")
    func optionArrowCommitsComposition() {
        let (composer, delegate) = makeComposer()
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: delegate)
        
        let optLeft = TestEventFactory.keyEvent(char: "\u{F702}", keyCode: KeyCode.leftArrow, modifiers: [.option])!
        let handled = composer.handle(optLeft, delegate: delegate)
        
        #expect(!handled)
        #expect(delegate.insertedTexts.contains("가"))
        #expect(delegate.markedText == "")
    }
    
    @Test("Home key commits composition before pass-through")
    func homeKeyCommitsComposition() {
        let (composer, delegate) = makeComposer()
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: delegate)
        
        let homeKey = TestEventFactory.keyEvent(char: "\u{F729}", keyCode: 115)!
        let handled = composer.handle(homeKey, delegate: delegate)
        
        #expect(!handled)
        #expect(delegate.insertedTexts.contains("가"))
        #expect(delegate.markedText == "")
    }
    
    @Test("Cmd shortcut without composition just passes through")
    func cmdShortcutWithoutComposition() {
        let (composer, delegate) = makeComposer()
        let cmdS = TestEventFactory.keyEvent(char: "s", keyCode: 1, modifiers: [.command])!
        let handled = composer.handle(cmdS, delegate: delegate)
        
        #expect(!handled)
        #expect(delegate.insertedTexts.isEmpty)
        #expect(delegate.markedText == "")
    }
    
    // MARK: - libhangul default-behavior regression guards
    //
    // The libhangul-swift defaults (combinationOnDoubleStroke OFF, fineGrainedBackspace ON,
    // outputMode .syllable) are what standard 2-bulsik PriType relies on. These tests lock
    // that contract so a future library default change can't silently break Korean input.

    @Test("Double-stroke does NOT combine: ㄱ+ㄱ → ㄱㄱ, not ㄲ (combinationOnDoubleStroke OFF)")
    func doubleStrokeDoesNotCombine() {
        let (composer, delegate) = makeComposer()
        // 'r' = ㄱ in 2-bulsik. Pressing it twice must commit the first ㄱ and start a new ㄱ,
        // NOT auto-combine into ㄲ (which would require combinationOnDoubleStroke = true).
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "r", keyCode: 15)!, delegate: delegate)

        #expect(delegate.markedText != "ㄲ", "ㄱㄱ must not auto-combine into ㄲ")
        #expect(
            delegate.markedText == "ㄱ" ||
            delegate.markedText == "\u{3131}" ||
            delegate.markedText == "\u{1100}",
            "second ㄱ should be the new preedit, got '\(delegate.markedText)'"
        )
        #expect(delegate.insertedTexts.contains { $0 == "ㄱ" || $0 == "\u{3131}" || $0 == "\u{1100}" },
                "first ㄱ should have committed")
    }

    @Test("Fine-grained backspace decomposes a compound vowel: 와 → 오 → ㅇ (fineGrainedBackspace ON)")
    func fineGrainedBackspaceDecomposesCompoundVowel() {
        let (composer, delegate) = makeComposer()
        // 와 = ㅇ(d) + ㅘ, where ㅘ = ㅗ(h) + ㅏ(k).
        _ = composer.handle(TestEventFactory.keyEvent(char: "d", keyCode: 2)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "h", keyCode: 4)!, delegate: delegate)
        _ = composer.handle(TestEventFactory.keyEvent(char: "k", keyCode: 40)!, delegate: delegate)
        #expect(delegate.markedText == "와")

        let backspace = TestEventFactory.keyEvent(char: "\u{7F}", keyCode: KeyCode.backspace)!
        // Fine-grained: the compound vowel ㅘ collapses one step to ㅗ → 오 (not the whole syllable).
        #expect(composer.handle(backspace, delegate: delegate), "backspace consumed during composition")
        #expect(delegate.markedText == "오", "compound vowel should decompose one step, got '\(delegate.markedText)'")
        // Next backspace removes the vowel, leaving just the initial ㅇ.
        _ = composer.handle(backspace, delegate: delegate)
        #expect(
            delegate.markedText == "ㅇ" ||
            delegate.markedText == "\u{3147}" ||
            delegate.markedText == "\u{110B}",
            "should leave the initial ㅇ, got '\(delegate.markedText)'"
        )
    }

    // MARK: - Helper
    
    private func makeComposer() -> (HangulComposer, MockComposerDelegate) {
        let composer = HangulComposer(configuration: MockConfiguration())
        let delegate = MockComposerDelegate()
        return (composer, delegate)
    }
}

// MARK: - Cursor Rect Validation Tests

/// `isValidCursorRect` guards the Hanja candidate window against the garbage
/// coordinates Chromium/Electron hosts return. These are the documented reject
/// cases (see ARCHITECTURE.md "좌표 유효성 검증").
@Suite("Cursor Rect Validation")
struct CursorRectValidationTests {

    @Test("Rejects zero origin (uninitialized coordinate query)")
    func rejectsZeroOrigin() {
        #expect(!HangulComposer.isValidCursorRect(NSRect(x: 0, y: 0, width: 0, height: 0)))
        #expect(!HangulComposer.isValidCursorRect(NSRect(x: 0, y: 0, width: 100, height: 20)))
    }

    @Test("Rejects non-positive height")
    func rejectsNonPositiveHeight() {
        #expect(!HangulComposer.isValidCursorRect(NSRect(x: 100, y: 100, width: 10, height: 0)))
        #expect(!HangulComposer.isValidCursorRect(NSRect(x: 100, y: 100, width: 10, height: -1)))
    }

    @Test("Rejects floating-point / sub-pixel garbage coordinates")
    func rejectsFloatGarbage() {
        // Representative Chromium garbage: subnormal x/width with negative height.
        #expect(!HangulComposer.isValidCursorRect(NSRect(x: 1.6e-314, y: 95886, width: 1.6e-314, height: -1)))
        // Near-zero or non-finite values on an otherwise on-screen rect.
        let screens = [NSRect(x: 0, y: 0, width: 1920, height: 1080)]
        for rect in [
            NSRect(x: 1.6e-314, y: 500, width: 1, height: 18),   // subnormal
            NSRect(x: 1e-300, y: 500, width: 1, height: 18),     // tiny but normal
            NSRect(x: 0.5, y: 0.5, width: 10, height: 10),
            NSRect(x: 1, y: 1, width: 10, height: 10),
            NSRect(x: 0, y: 500, width: 1, height: 18),
            NSRect(x: CGFloat.nan, y: 500, width: 1, height: 18),
            NSRect(x: 500, y: 500, width: CGFloat.nan, height: 18)
        ] {
            #expect(!CursorRectResolver.isValidCursorRect(rect, screens: screens), "\(rect)")
        }
    }

    @Test("Accepts a caret on a display left of or below the main one")
    func acceptsNegativeCoordinatesOnSecondaryDisplays() {
        let screens = [
            NSRect(x: 0, y: 0, width: 1920, height: 1080),        // main
            NSRect(x: -2560, y: 0, width: 2560, height: 1440),    // left
            NSRect(x: 0, y: -1080, width: 1920, height: 1080)     // below
        ]
        #expect(CursorRectResolver.isValidCursorRect(NSRect(x: -100, y: 500, width: 1, height: 18), screens: screens))
        #expect(CursorRectResolver.isValidCursorRect(NSRect(x: 500, y: -300, width: 1, height: 18), screens: screens))
        // The same point with only the main display attached is off screen.
        #expect(!CursorRectResolver.isValidCursorRect(NSRect(x: -100, y: 500, width: 1, height: 18), screens: [screens[0]]))
    }

    @Test("Accepts a well-formed on-screen rect")
    func acceptsValidOnScreenRect() {
        // Needs a real display; skip cleanly in a headless environment.
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let rect = NSRect(x: frame.midX, y: frame.midY, width: 8, height: 18)
        #expect(HangulComposer.isValidCursorRect(rect))
    }

    @Test("Rejects an off-screen rect")
    func rejectsOffScreenRect() {
        // Far outside any plausible display bounds.
        #expect(!HangulComposer.isValidCursorRect(NSRect(x: 5_000_000, y: 5_000_000, width: 8, height: 18)))
    }
}
