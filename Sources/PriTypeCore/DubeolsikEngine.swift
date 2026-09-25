// MARK: - DubeolsikEngine

/// The standard 두벌식 (KS X 5002) composition automaton.
///
/// It takes the QWERTY letter of each key (`QwertyKeyMap`) and holds the one
/// syllable being typed. Everything it produces is a single Unicode scalar — a
/// precomposed syllable or a compatibility jamo — so its output is NFC by
/// construction and needs no conversion or normalization.
///
/// Only the standard combinations exist: the seven compound vowels (ㅘ ㅙ ㅚ ㅝ
/// ㅞ ㅟ ㅢ) and the eleven compound finals (ㄳ ㄵ ㄶ ㄺ ㄻ ㄼ ㄽ ㄾ ㄿ ㅀ ㅄ).
/// ㅐ ㅒ ㅔ ㅖ ㄲ ㅆ come only from their own keys, so ㅏ + ㅣ is ㅏㅣ and 갓 + ㅅ
/// is 갓ㅅ. A consonant after a lone vowel starts the next syllable (ㅏ + ㄴ →
/// ㅏ나), as it does in Apple's 두벌식: no 모아치기.
///
/// Backspace undoes one keystroke rather than one jamo: the state after every
/// key of the syllable is kept, so ㅐ typed with one key goes whole while ㅗ + ㅏ
/// steps back to ㅗ, and 닭 steps back to 달. A syllable takes at most five keys
/// (괅 = ㄱ ㅗ ㅏ ㄹ ㄱ), and the storage for them is reserved once.
struct DubeolsikEngine: Sendable {
    /// One syllable: jamo indices in Unicode's syllable order. `none` marks an
    /// absent initial or medial; a final of 0 is no final.
    struct Syllable: Equatable, Sendable {
        static let none: UInt8 = .max

        var initial = none
        var medial = none
        var final: UInt8 = 0

        /// The syllable as one scalar: precomposed when it has an initial and a
        /// medial, else the compatibility jamo of whichever one it has.
        var scalar: Unicode.Scalar? {
            if initial != Self.none, medial != Self.none {
                return Unicode.Scalar(0xAC00 + (UInt32(initial) * 21 + UInt32(medial)) * 28 + UInt32(final))
            }
            if initial != Self.none {
                return Unicode.Scalar(DubeolsikEngine.compatibilityInitials[Int(initial)])
            }
            if medial != Self.none {
                return Unicode.Scalar(0x314F + UInt32(medial))
            }
            return nil
        }
    }

    /// What one key did: the syllable it completed, if any, and the one now
    /// being typed. The commit always comes first — it is the text before the
    /// new syllable.
    struct Step: Equatable, Sendable {
        var committed: Unicode.Scalar?
        var composing: Unicode.Scalar?
    }

    /// The live syllable after each of its keystrokes, oldest first.
    private var history: [Syllable]

    init() {
        history = []
        history.reserveCapacity(5)
    }

    var isComposing: Bool { !history.isEmpty }

    /// The syllable being typed, or `nil` when nothing is.
    var composing: Unicode.Scalar? { history.last?.scalar }

    /// Type the key at the QWERTY letter `key` ("r" is ㄱ, "R" is ㄲ). `nil` for
    /// anything that is not one of the 52 letters, which the engine leaves alone.
    mutating func type(_ key: Character) -> Step? {
        guard let ascii = key.asciiValue, ascii < 128 else { return nil }
        let jamo = Self.keys[Int(ascii)]
        guard jamo != Self.noKey else { return nil }

        var committed: Unicode.Scalar?
        if jamo & Self.vowelFlag == 0 {
            committed = typeConsonant(jamo)
        } else {
            committed = typeVowel(jamo & ~Self.vowelFlag)
        }
        return Step(committed: committed, composing: composing)
    }

    /// Undo the last keystroke of the syllable. Returns whether one was undone.
    @discardableResult
    mutating func backspace() -> Bool {
        history.popLast() != nil
    }

    /// End the syllable, returning it (`nil` when nothing was being typed).
    mutating func flush() -> Unicode.Scalar? {
        let syllable = composing
        reset()
        return syllable
    }

    mutating func reset() {
        history.removeAll(keepingCapacity: true)
    }

    // MARK: Keys

    private mutating func typeConsonant(_ initial: UInt8) -> Unicode.Scalar? {
        guard var syllable = history.last else {
            start(Syllable(initial: initial))
            return nil
        }
        // A lone jamo takes no consonant after it: the consonant starts anew.
        guard syllable.initial != Syllable.none, syllable.medial != Syllable.none else {
            return startNext(Syllable(initial: initial))
        }
        let final = syllable.final == 0
            ? Self.finals[Int(initial)]
            : Self.compoundFinal(syllable.final, initial)
        guard final != 0 else {
            return startNext(Syllable(initial: initial))
        }
        syllable.final = final
        history.append(syllable)
        return nil
    }

    private mutating func typeVowel(_ medial: UInt8) -> Unicode.Scalar? {
        guard var syllable = history.last else {
            start(Syllable(medial: medial))
            return nil
        }
        if syllable.medial == Syllable.none {
            syllable.medial = medial
            history.append(syllable)
            return nil
        }
        if syllable.final == 0 {
            let compound = Self.compoundMedial(syllable.medial, medial)
            guard compound != Syllable.none else {
                return startNext(Syllable(medial: medial))
            }
            syllable.medial = compound
            history.append(syllable)
            return nil
        }
        // A vowel after a final takes the final (or its second half) as its
        // initial: 닭 + ㅏ → 달가. The new syllable was typed as two keys, the
        // consonant and then the vowel, and backspace steps through both.
        let moved: UInt8
        if let (kept, next) = Self.splitFinal(syllable.final) {
            syllable.final = kept
            moved = next
        } else {
            moved = Self.initials[Int(syllable.final)]
            syllable.final = 0
        }
        let committed = syllable.scalar
        start(Syllable(initial: moved))
        history.append(Syllable(initial: moved, medial: medial))
        return committed
    }

    private mutating func start(_ syllable: Syllable) {
        history.removeAll(keepingCapacity: true)
        history.append(syllable)
    }

    /// Commit the live syllable and start `syllable` after it.
    private mutating func startNext(_ syllable: Syllable) -> Unicode.Scalar? {
        let committed = composing
        start(syllable)
        return committed
    }

    // MARK: Tables

    private static let noKey: UInt8 = .max
    private static let vowelFlag: UInt8 = 0x80

    /// QWERTY letter (ASCII) → initial index, or medial index | `vowelFlag`.
    private static let keys: [UInt8] = {
        var table = [UInt8](repeating: noKey, count: 128)
        let consonants: [Character: UInt8] = [
            "r": 0, "R": 1, "s": 2, "e": 3, "E": 4, "f": 5, "a": 6, "q": 7, "Q": 8, "t": 9,
            "T": 10, "d": 11, "w": 12, "W": 13, "c": 14, "z": 15, "x": 16, "v": 17, "g": 18
        ]
        let vowels: [Character: UInt8] = [
            "k": 0, "o": 1, "i": 2, "O": 3, "j": 4, "p": 5, "u": 6, "P": 7, "h": 8,
            "y": 12, "n": 13, "b": 17, "m": 18, "l": 20
        ]
        for (key, initial) in consonants {
            table[Int(key.asciiValue!)] = initial
        }
        for (key, medial) in vowels {
            table[Int(key.asciiValue!)] = medial | vowelFlag
        }
        // Shift changes only the seven keys above; the rest type as unshifted.
        for lower in "abcdefghijklmnopqrstuvwxyz" {
            let upper = Int(Character(lower.uppercased()).asciiValue!)
            if table[upper] == noKey {
                table[upper] = table[Int(lower.asciiValue!)]
            }
        }
        return table
    }()

    /// Initial index → final index; 0 where the initial cannot end a syllable
    /// (ㄸ ㅃ ㅉ).
    private static let finals: [UInt8] = [1, 2, 4, 7, 0, 8, 16, 17, 0, 19, 20, 21, 22, 0, 23, 24, 25, 26, 27]

    /// Final index → initial index, for the single finals that move on.
    private static let initials: [UInt8] = [
        Syllable.none, 0, 1, Syllable.none, 2, Syllable.none, Syllable.none, 3, 5,
        Syllable.none, Syllable.none, Syllable.none, Syllable.none, Syllable.none, Syllable.none, Syllable.none,
        6, 7, Syllable.none, 9, 10, 11, 12, 14, 15, 16, 17, 18
    ]

    /// Compatibility jamo of each initial (U+3131…), for a lone consonant.
    fileprivate static let compatibilityInitials: [UInt32] = [
        0x3131, 0x3132, 0x3134, 0x3137, 0x3138, 0x3139, 0x3141, 0x3142, 0x3143, 0x3145,
        0x3146, 0x3147, 0x3148, 0x3149, 0x314A, 0x314B, 0x314C, 0x314D, 0x314E
    ]

    /// The standard compound finals, as (first final, second consonant's initial).
    private static let compoundFinals: [(final: UInt8, first: UInt8, second: UInt8)] = [
        (3, 1, 9),    // ㄳ = ㄱ ㅅ
        (5, 4, 12),   // ㄵ = ㄴ ㅈ
        (6, 4, 18),   // ㄶ = ㄴ ㅎ
        (9, 8, 0),    // ㄺ = ㄹ ㄱ
        (10, 8, 6),   // ㄻ = ㄹ ㅁ
        (11, 8, 7),   // ㄼ = ㄹ ㅂ
        (12, 8, 9),   // ㄽ = ㄹ ㅅ
        (13, 8, 16),  // ㄾ = ㄹ ㅌ
        (14, 8, 17),  // ㄿ = ㄹ ㅍ
        (15, 8, 18),  // ㅀ = ㄹ ㅎ
        (18, 17, 9)   // ㅄ = ㅂ ㅅ
    ]

    /// The compound final of `final` followed by the consonant `initial`, or 0.
    private static func compoundFinal(_ final: UInt8, _ initial: UInt8) -> UInt8 {
        compoundFinals.first { $0.first == final && $0.second == initial }?.final ?? 0
    }

    /// A compound final split into the final it keeps and the initial it passes on.
    private static func splitFinal(_ final: UInt8) -> (kept: UInt8, moved: UInt8)? {
        compoundFinals.first { $0.final == final }.map { ($0.first, $0.second) }
    }

    /// The compound vowel of `first` followed by `second`, or `Syllable.none`.
    private static func compoundMedial(_ first: UInt8, _ second: UInt8) -> UInt8 {
        switch (first, second) {
        case (8, 0): return 9     // ㅘ = ㅗ ㅏ
        case (8, 1): return 10    // ㅙ = ㅗ ㅐ
        case (8, 20): return 11   // ㅚ = ㅗ ㅣ
        case (13, 4): return 14   // ㅝ = ㅜ ㅓ
        case (13, 5): return 15   // ㅞ = ㅜ ㅔ
        case (13, 20): return 16  // ㅟ = ㅜ ㅣ
        case (18, 20): return 19  // ㅢ = ㅡ ㅣ
        default: return Syllable.none
        }
    }
}
