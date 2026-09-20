import Foundation
import LibHangul

/// Helper functions for Hangul composition string conversion and normalization
///
/// This struct provides static utility methods extracted from `HangulComposer`
/// to improve code organization and reusability.
public struct CompositionHelpers: Sendable {
    
    // MARK: - String Conversion
    
    /// Convert UCSChar array (from libhangul) to Swift String
    /// - Parameter codePoints: Array of UInt32 Unicode code points (UCSChar)
    /// - Returns: String representation of the code points
    public static func convertToString(_ codePoints: [UInt32]) -> String {
        return String(codePoints.compactMap { UnicodeScalar($0) }.map { Character($0) })
    }
    
    /// Convert UCSChar array to NFC-normalized Swift String
    /// Combines conversion and `.precomposedStringWithCanonicalMapping` in one step.
    /// - Parameter codePoints: Array of UInt32 Unicode code points (UCSChar)
    /// - Returns: NFC-normalized string
    public static func convertAndNormalize(_ codePoints: [UInt32]) -> String {
        return convertToString(codePoints).precomposedStringWithCanonicalMapping
    }
    
    // MARK: - Jamo Normalization
    
    /// Normalize Jamo characters to Compatibility Jamo for display
    ///
    /// Converts internal Jamo representations (Choseong/Jungseong/Jongseong)
    /// to Compatibility Jamo for better visual display in marked text.
    ///
    /// - Parameter preedit: Array of UInt32 code points from libhangul
    /// - Returns: Normalized string suitable for display
    public static func normalizeJamoForDisplay(_ preedit: [UInt32]) -> String {
        let scalars = preedit.compactMap { UnicodeScalar($0) }
        let mapped = scalars.map { scalar -> UnicodeScalar in
            let val = scalar.value
            // HangulCharacter.jamoToCJamo handles Choseong, Jungseong, AND Jongseong
            let cJamo = HangulCharacter.jamoToCJamo(val)
            return UnicodeScalar(cJamo) ?? scalar
        }
        return String(mapped.map { Character($0) })
    }

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

    /// Returns true when the string is a single standalone Jamo used as preedit.
    public static func isSingleStandaloneJamo(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 1, let value = scalars.first?.value else {
            return false
        }

        return (0x1100...0x11FF).contains(value) ||
            (0x3130...0x318F).contains(value)
    }
}
