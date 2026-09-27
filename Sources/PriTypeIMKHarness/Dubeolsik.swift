/// The 두벌식 keys that type a Hangul text, for driving the harness with real
/// sentences: "안녕하세요" → "dkssudgktpdy". A lone jamo — what a syllable is
/// while it has no vowel or no initial — gives its own key, so "ㅏ나" → "ksk".
/// Other characters are returned as they are.
public enum Dubeolsik {
    private static let initials = ["r", "R", "s", "e", "E", "f", "a", "q", "Q", "t", "T",
                                   "d", "w", "W", "c", "z", "x", "v", "g"]
    private static let medials = ["k", "o", "i", "O", "j", "p", "u", "P", "h", "hk", "ho",
                                  "hl", "y", "n", "nj", "np", "nl", "b", "m", "ml", "l"]
    private static let finals = ["", "r", "R", "rt", "s", "sw", "sg", "e", "f", "fr", "fa",
                                 "fq", "ft", "fx", "fv", "fg", "a", "q", "qt", "t", "T",
                                 "d", "w", "c", "z", "x", "v", "g"]

    /// Compatibility jamo (U+3131…) of each initial, in `initials` order.
    private static let compatibilityInitials: [UInt32] = [
        0x3131, 0x3132, 0x3134, 0x3137, 0x3138, 0x3139, 0x3141, 0x3142, 0x3143, 0x3145,
        0x3146, 0x3147, 0x3148, 0x3149, 0x314A, 0x314B, 0x314C, 0x314D, 0x314E
    ]

    public static func keys(for text: String) -> String {
        text.unicodeScalars.map { keys(for: $0) ?? String($0) }.joined()
    }

    /// The keys of one syllable or lone jamo, or `nil` for anything else.
    public static func keys(for scalar: Unicode.Scalar) -> String? {
        let value = scalar.value
        switch value {
        case 0xAC00...0xD7A3:
            let index = Int(value - 0xAC00)
            return initials[index / (21 * 28)] + medials[(index % (21 * 28)) / 28] + finals[index % 28]
        case 0x314F...0x3163:
            return medials[Int(value - 0x314F)]
        default:
            return compatibilityInitials.firstIndex(of: value).map { initials[$0] }
        }
    }
}
