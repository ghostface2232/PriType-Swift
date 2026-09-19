import Foundation

/// Centralized key code constants for macOS keyboard events
///
/// ## Usage
/// ```swift
/// if keyCode == KeyCode.space { ... }
/// if KeyCode.isPrintable(charCode) { ... }
/// ```
public enum KeyCode {
    
    // MARK: - Navigation Keys
    
    /// Space key (49)
    public static let space: UInt16 = 49
    
    /// Backspace/Delete key (51)
    public static let backspace: UInt16 = 51
    
    /// Escape key (53)
    public static let escape: UInt16 = 53
    
    /// Return/Enter key (36)
    public static let `return`: UInt16 = 36
    
    /// Numpad Enter key (76)
    public static let numpadEnter: UInt16 = 76
    
    /// Tab key (48)
    public static let tab: UInt16 = 48
    
    // MARK: - Arrow Keys
    
    /// Left arrow (123)
    public static let leftArrow: UInt16 = 123
    
    /// Right arrow (124)
    public static let rightArrow: UInt16 = 124
    
    /// Down arrow (125)
    public static let downArrow: UInt16 = 125
    
    /// Up arrow (126)
    public static let upArrow: UInt16 = 126
    
    // MARK: - Modifier Keys (for CGEventTap)
    // These use Int64 type for compatibility with CGEvent.getIntegerValueField()
    
    /// Right Command key (54)
    public static let rightCommand: Int64 = 54
    
    /// Left Control key (59)
    public static let leftControl: Int64 = 59
    
    /// Right Control key (62)
    public static let rightControl: Int64 = 62
    
    /// Right Option key (61)
    public static let rightOption: Int64 = 61
    
    /// Space key in Int64 context for CGEventTap (49)
    public static let spaceInt64: Int64 = 49
    
    // MARK: - Character Code Ranges
    
    /// Minimum printable ASCII character code (space)
    public static let printableMin: UInt32 = 32
    
    /// Maximum printable ASCII character code (tilde)
    public static let printableMax: UInt32 = 126
    
    /// Threshold for function/special keys (F1, etc.)
    public static let functionKeyThreshold: UInt32 = 63000
    
    /// Tab character code
    public static let tabCharCode: UInt32 = 9
    
    /// Newline (LF) character code
    public static let newlineCharCode: UInt32 = 10
    
    /// Carriage return (CR) character code
    public static let carriageReturnCharCode: UInt32 = 13
    
    // MARK: - Helper Methods
    
    /// Checks if a character code represents a printable ASCII character
    /// - Parameter charCode: Unicode scalar value
    /// - Returns: `true` if printable (32-126)
    public static func isPrintableASCII(_ charCode: UInt32) -> Bool {
        return charCode >= printableMin && charCode <= printableMax
    }
    
    /// Checks if a character code represents a function or special key
    /// - Parameter charCode: Unicode scalar value
    /// - Returns: `true` if function key (>= 63000)
    public static func isFunctionKey(_ charCode: UInt32) -> Bool {
        return charCode >= functionKeyThreshold
    }
    
    /// Checks if a character code is a control character (except tab/newline/CR)
    /// - Parameter charCode: Unicode scalar value
    /// - Returns: `true` if control character that should be ignored
    public static func isIgnorableControlChar(_ charCode: UInt32) -> Bool {
        return charCode < printableMin &&
               charCode != tabCharCode &&
               charCode != newlineCharCode &&
               charCode != carriageReturnCharCode
    }
    
    /// Checks if a character should be passed through to the system
    /// - Parameter charCode: Unicode scalar value
    /// - Returns: `true` if the character should not be handled by the input method
    public static func shouldPassThrough(_ charCode: UInt32) -> Bool {
        return isFunctionKey(charCode) || isIgnorableControlChar(charCode)
    }
}

// MARK: - QwertyKeyMap

/// The US QWERTY letter at each of the 26 letter-key positions.
///
/// 두벌식 is defined by key *position*: ㄱ is the key labelled R on a US keyboard,
/// whatever the active Latin layout calls it. Reading `event.characters` instead
/// ties composition to that layout, so a Dvorak, Colemak or AZERTY user types the
/// wrong jamo, and Caps Lock turns every consonant into its doubled form.
///
/// Only letter keys are mapped, because only they carry jamo. Every other key —
/// digits, punctuation, national characters such as ö or é, keypad, JIS/ISO
/// extras — keeps the character the user's layout produced.
public enum QwertyKeyMap {
    private static let letters: [UInt16: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 31: "o", 32: "u",
        34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m"
    ]

    /// The QWERTY letter at `keyCode`, or `nil` for a key that carries no jamo.
    /// Only Shift selects the upper case; Caps Lock is deliberately ignored.
    public static func character(for keyCode: UInt16, shifted: Bool) -> String? {
        letters[keyCode].map { shifted ? $0.uppercased() : String($0) }
    }

    static func isLetterKey(_ keyCode: UInt16) -> Bool {
        letters[keyCode] != nil
    }

    /// US digits and punctuation of the main typing block, unshifted and
    /// shifted. Key 50 is left out: ISO keyboards swap it with key 10, so its
    /// position is not the US grave key.
    private static let punctuationKeys: [UInt16: (String, String)] = [
        18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"), 21: ("4", "$"), 23: ("5", "%"),
        22: ("6", "^"), 26: ("7", "&"), 28: ("8", "*"), 25: ("9", "("), 29: ("0", ")"),
        27: ("-", "_"), 24: ("=", "+"), 33: ("[", "{"), 30: ("]", "}"), 42: ("\\", "|"),
        41: (";", ":"), 39: ("'", "\""), 43: (",", "<"), 47: (".", ">"), 44: ("/", "?")
    ]

    /// The US character at a digit or punctuation key of the main block, or
    /// `nil` for any other key.
    public static func punctuation(for keyCode: UInt16, shifted: Bool) -> String? {
        punctuationKeys[keyCode].map { shifted ? $0.1 : $0.0 }
    }
}

// MARK: - LatinLayoutObserver

/// Notices a Latin layout that puts punctuation on letter keys.
///
/// 두벌식 takes all 26 letter keys for jamo. A QWERTY-lettered layout (US,
/// German, the Nordic ones) keeps its punctuation elsewhere, so every other
/// key can type what the layout says, national letters included. AZERTY puts
/// the comma on M, Dvorak ' , . on Q W E, Colemak ; on P: in Korean mode those
/// keys type jamo, and that punctuation is left without a key. One letter key
/// typing something other than a letter shows the layout is of that kind; the
/// composer then reads the digit and punctuation keys by their US position,
/// which gives back a complete set.
///
/// Each key is judged by what it typed last, so the verdict follows a change
/// of layout, such as a client later overridden to ABC.
struct LatinLayoutObserver {
    private var lettersTypingOtherwise: Set<UInt16> = []

    /// Whether the layout moved punctuation onto the letter keys.
    var displacesPunctuation: Bool { !lettersTypingOtherwise.isEmpty }

    /// Note what a keystroke typed. `characters` is what the layout produced
    /// (Shift or Caps Lock at most). Only a single character counts: a dead
    /// key types nothing yet, and a letter after an unused dead accent arrives
    /// with it ("^r" on German), which says nothing about the letter key.
    mutating func observe(keyCode: UInt16, characters: String?) {
        guard QwertyKeyMap.isLetterKey(keyCode), let characters, characters.count == 1,
              let character = characters.first else { return }
        if character.isLetter {
            lettersTypingOtherwise.remove(keyCode)
        } else {
            lettersTypingOtherwise.insert(keyCode)
        }
    }
}
