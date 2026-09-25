import Foundation

/// Hangul text helpers for what hosts hold, which is not always what PriType
/// typed: text pasted from elsewhere can be decomposed (NFD).
public struct CompositionHelpers: Sendable {
    
    /// The decomposed syllable `text` ends with, as its UTF-16 length and its
    /// precomposed form: ᄀ ᅡ ᆨ (or 가 ᆨ) → 각. Text pasted from macOS file names
    /// and some web pages is stored this way, and hosts delete it a jamo at a time.
    /// `text` is the few UTF-16 units before the caret. Old Hangul, which has no
    /// precomposed form, and a syllable whose initial is part of a longer cluster
    /// are left alone.
    public static func decomposedSyllableSuffix(of text: String) -> (utf16Length: Int, syllable: String)? {
        // The last four scalars, counting back from the caret, read without
        // building an array: this runs on the keystroke path.
        var last1: UInt32?, last2: UInt32?, last3: UInt32?, last4: UInt32?
        for (offset, scalar) in text.unicodeScalars.reversed().prefix(4).enumerated() {
            switch offset {
            case 0: last1 = scalar.value
            case 1: last2 = scalar.value
            case 2: last3 = scalar.value
            default: last4 = scalar.value
            }
        }
        guard let last = last1 else { return nil }
        let initials: ClosedRange<UInt32> = 0x1100...0x1112
        let medials: ClosedRange<UInt32> = 0x1161...0x1175
        let finals: ClosedRange<UInt32> = 0x11A8...0x11C2
        /// The scalar `offset` places back from the caret, 1 being the last one.
        func at(_ offset: Int) -> UInt32? {
            switch offset {
            case 1: return last1
            case 2: return last2
            case 3: return last3
            case 4: return last4
            default: return nil
            }
        }

        let base: UInt32   // precomposed syllable without the final
        let count: Int
        if medials.contains(last), let initial = at(2), initials.contains(initial) {
            base = 0xAC00 + ((initial - 0x1100) * 21 + (last - 0x1161)) * 28
            count = 2
        } else if finals.contains(last), let medial = at(2), medials.contains(medial),
                  let initial = at(3), initials.contains(initial) {
            base = 0xAC00 + ((initial - 0x1100) * 21 + (medial - 0x1161)) * 28
            count = 3
        } else if finals.contains(last), let open = at(2), (0xAC00...0xD7A3).contains(open),
                  (open - 0xAC00) % 28 == 0 {
            return (2, String(UnicodeScalar(open + last - 0x11A7)!))
        } else {
            return nil
        }
        if let before = at(count + 1), (0x1100...0x115F).contains(before) { return nil }
        let syllable = base + (count == 3 ? last - 0x11A7 : 0)
        return (count, String(UnicodeScalar(syllable)!))
    }
}
