/// The 두벌식 keys that type a Hangul text, for driving the harness with real
/// sentences: "안녕하세요" → "dkssudgktpdy". Characters other than precomposed
/// syllables are returned as they are.
public enum Dubeolsik {
    private static let initials = ["r", "R", "s", "e", "E", "f", "a", "q", "Q", "t", "T",
                                   "d", "w", "W", "c", "z", "x", "v", "g"]
    private static let medials = ["k", "o", "i", "O", "j", "p", "u", "P", "h", "hk", "ho",
                                  "hl", "y", "n", "nj", "np", "nl", "b", "m", "ml", "l"]
    private static let finals = ["", "r", "R", "rt", "s", "sw", "sg", "e", "f", "fr", "fa",
                                 "fq", "ft", "fx", "fv", "fg", "a", "q", "qt", "t", "T",
                                 "d", "w", "c", "z", "x", "v", "g"]

    public static func keys(for text: String) -> String {
        var keys = ""
        for scalar in text.unicodeScalars {
            let value = Int(scalar.value)
            guard (0xAC00...0xD7A3).contains(value) else {
                keys.unicodeScalars.append(scalar)
                continue
            }
            let index = value - 0xAC00
            keys += initials[index / (21 * 28)] + medials[(index % (21 * 28)) / 28] + finals[index % 28]
        }
        return keys
    }
}
