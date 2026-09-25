import Testing
@testable import PriTypeCore

// MARK: - CompositionHelpers Tests

@Suite("CompositionHelpers")
struct CompositionHelpersTests {

    @Test("A decomposed syllable before the caret is found with its precomposed form")
    func decomposedSyllableSuffix() {
        let find = CompositionHelpers.decomposedSyllableSuffix(of:)
        #expect(find("a\u{1100}\u{1161}\u{11A8}")! == (3, "각"))
        #expect(find("\u{1100}\u{1161}")! == (2, "가"))
        #expect(find("\u{1100}\u{1161}\u{11A8}\u{1100}\u{1161}")! == (2, "가"))
        #expect(find("가\u{11A8}")! == (2, "각"), "Precomposed LV + final")
        #expect(find("각") == nil, "Already precomposed")
        #expect(find("ab") == nil)
        #expect(find("\u{1161}\u{11A8}") == nil, "No initial")
        #expect(find("\u{1100}\u{1100}\u{1161}") == nil, "Old Hangul cluster")
        #expect(find("\u{1100}\u{119E}") == nil, "Arae-a has no precomposed form")
        #expect(find("\u{1100}\u{1100}\u{1161}\u{11A8}") == nil, "Old Hangul cluster, with a final")
        #expect(find("\u{1100}\u{1161}\u{11C3}") == nil, "Old final")
        #expect(find("\u{1100}\u{1161}\u{11A8}\u{11A8}") == nil, "Double final")
        #expect(find("") == nil)
        #expect(find("\u{11A8}") == nil, "A final alone")
        #expect(find("😀\u{1100}\u{1161}")! == (2, "가"), "An astral character before the syllable")
    }
}

// MARK: - InputMode Tests

@Suite("InputMode")
struct InputModeTests {
    
    @Test("Toggle switches between korean and english")
    func toggled() {
        #expect(InputMode.korean.toggled == .english)
        #expect(InputMode.english.toggled == .korean)
    }
    
    @Test("Double toggle returns to original")
    func doubleToggleReturnsOriginal() {
        #expect(InputMode.korean.toggled.toggled == .korean)
        #expect(InputMode.english.toggled.toggled == .english)
    }
}

// MARK: - PriTypeConfig Tests

@Suite("PriTypeConfig Constants")
struct PriTypeConfigTests {
    
    @Test("Default values are sensible")
    func defaultValues() {
        #expect(PriTypeConfig.finderDesktopThreshold == 50)
        #expect(PriTypeConfig.doubleSpaceThreshold > 0)
        #expect(PriTypeConfig.doubleSpaceThreshold < 1.0)
        #expect(PriTypeConfig.settingsWindowWidth > 0)
        #expect(PriTypeConfig.settingsWindowHeight > 0)
    }
}

// MARK: - Jamo Conversion Tests

@Suite("Jamo Conversion")
struct JamoConversionTests {

    @Test("Choseong jamo detection covers U+1100...U+1112 only")
    func choseongDetection() {
        #expect(Character("\u{1100}").isChoseongJamo)   // ᄀ first choseong
        #expect(Character("\u{1112}").isChoseongJamo)   // ᄒ last choseong
        #expect(!Character("\u{10FF}").isChoseongJamo)  // just below range
        #expect(!Character("\u{1113}").isChoseongJamo)  // just above range
        #expect(!Character("\u{3131}").isChoseongJamo)  // ㄱ compatibility jamo, not choseong
        #expect(!Character("가").isChoseongJamo)         // precomposed syllable
        #expect(!Character("A").isChoseongJamo)
    }

    @Test("Choseong jamo maps to the matching compatibility jamo")
    func choseongToCompatibilityMapping() {
        // libhangul emits choseong jamo; jamo_symbols.json is keyed by compatibility jamo.
        #expect(Character("\u{1100}").choseongToCompatibility == "\u{3131}")  // ᄀ → ㄱ
        #expect(Character("\u{1102}").choseongToCompatibility == "\u{3134}")  // ᄂ → ㄴ
        #expect(Character("\u{1106}").choseongToCompatibility == "\u{3141}")  // ᄆ → ㅁ
        #expect(Character("\u{110B}").choseongToCompatibility == "\u{3147}")  // ᄋ → ㅇ
        #expect(Character("\u{1112}").choseongToCompatibility == "\u{314E}")  // ᄒ → ㅎ
    }

    @Test("Non-choseong characters are returned unchanged")
    func nonChoseongUnchanged() {
        #expect(Character("가").choseongToCompatibility == "가")
        #expect(Character("A").choseongToCompatibility == "A")
        #expect(Character("\u{3131}").choseongToCompatibility == "\u{3131}")  // already compatibility
    }

    @Test("Compatibility jamo consonant detection covers U+3131...U+314E")
    func jamoConsonantDetection() {
        #expect(Character("\u{3131}").isJamoConsonant)  // ㄱ
        #expect(Character("\u{314E}").isJamoConsonant)  // ㅎ
        #expect(!Character("\u{314F}").isJamoConsonant) // ㅏ (vowel, just above range)
        #expect(!Character("가").isJamoConsonant)
    }
}
