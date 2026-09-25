import Foundation

/// Loads and searches the Hanja dictionary.
///
/// The dictionary is the compiled `hanja.dat` (see `HanjaDictionary`), memory-mapped
/// rather than parsed, so loading is a file open and a scan of its offset table.
/// A search never waits for a load running on another thread: it returns no
/// entries and the next key press finds the dictionary ready.
public final class HanjaManager: @unchecked Sendable {

    public static let shared = HanjaManager()

    private enum LoadState {
        case unloaded
        case loading
        case loaded(HanjaDictionary)
        case failed
    }

    /// Guards `state`, `wanted` and `unloads`; waited on only by `loadIfNeeded`,
    /// never by a search.
    private let condition = NSCondition()
    private var state = LoadState.unloaded
    /// Whether Hanja conversion is on, as last said by `preload()` / `unload()`.
    /// Recorded on the caller's thread, so a background load that finishes, or
    /// starts, late still obeys the newest of them.
    private var wanted = true
    /// Bumped by every `unload()`. A load that saw one happen, and finishes
    /// while Hanja is off, throws its result away.
    private var unloads: UInt64 = 0
    private let loader: @Sendable () -> HanjaDictionary?

    /// Jamo → special symbol mapping (Windows-style)
    private var jamoSymbols: [String: [HanjaEntry]] = [:]
    private var jamoSymbolsLoaded = false
    private let jamoLock = NSLock()

    private convenience init() {
        let url = Self.resourceBundle.url(forResource: "hanja", withExtension: "dat")
        self.init(loader: { Self.load(from: url) })
    }

    /// For tests: a manager whose dictionary comes from `loader`.
    init(loader: @escaping @Sendable () -> HanjaDictionary?) {
        self.loader = loader
    }

    /// Whether the dictionary is mapped and ready for lookups.
    public var isLoaded: Bool {
        condition.withLock { if case .loaded = state { return true } else { return false } }
    }

    /// Map the dictionary in the background, for launch and for turning Hanja
    /// conversion on. Pairs with `unload()`: call both from one thread (main),
    /// and on-off-on keeps a load already running, on-off leaves nothing mapped,
    /// however late the background work runs.
    public func preload() {
        condition.withLock { wanted = true }
        DispatchQueue.global(qos: .utility).async {
            _ = self.dictionary(onlyIfWanted: true)
        }
    }

    /// Map the dictionary, or wait for the thread that is mapping it. Blocks;
    /// for tests and tools. The app preloads with `preload()`, and key presses
    /// go through `search`, which never waits.
    public func loadIfNeeded() {
        guard dictionary() == nil else { return }
        condition.withLock {
            while case .loading = state { condition.wait() }
        }
    }

    /// Drop the mapping and the symbol table, for when Hanja conversion is turned
    /// off. A load in progress is left to finish and its result discarded, so a
    /// quick on-then-off does not leave the dictionary mapped.
    public func unload() {
        condition.withLock {
            wanted = false
            unloads &+= 1
            switch state {
            case .loaded, .failed: state = .unloaded
            case .loading, .unloaded: break
            }
        }
        jamoLock.withLock {
            jamoSymbols = [:]
            jamoSymbolsLoaded = false
        }
        DebugLogger.log("HanjaManager: Unloaded")
    }

    /// The mapped dictionary. Loads it on this thread when nobody has; returns nil
    /// without waiting when another thread is loading it. `onlyIfWanted` is the
    /// preload: it does not start a load once Hanja has been turned off, checked
    /// in the same critical section as the claim so an `unload()` cannot slip in
    /// between.
    private func dictionary(onlyIfWanted: Bool = false) -> HanjaDictionary? {
        let claim: UInt64? = condition.withLock {
            guard case .unloaded = state, wanted || !onlyIfWanted else { return nil }
            state = .loading
            return unloads
        }
        if let unloadsAtClaim = claim {
            let loaded = loader()
            condition.withLock {
                if !wanted && unloads != unloadsAtClaim {
                    state = .unloaded
                } else {
                    state = loaded.map(LoadState.loaded) ?? .failed
                }
                condition.broadcast()
            }
        }
        return condition.withLock {
            if case .loaded(let dictionary) = state { return dictionary }
            return nil
        }
    }

    private static func load(from url: URL?) -> HanjaDictionary? {
        guard let url else {
            DebugLogger.log("HanjaManager: WARNING - hanja.dat not found in bundle")
            return nil
        }
        do {
            let dictionary = try HanjaDictionary(contentsOf: url)
            DebugLogger.log("HanjaManager: Mapped dictionary (\(dictionary.count) keys)")
            return dictionary
        } catch {
            DebugLogger.log("HanjaManager: WARNING - Failed to map hanja.dat: \(error)")
            return nil
        }
    }

    /// Load jamo symbol mapping from bundled JSON
    private func loadJamoSymbolsIfNeeded() {
        jamoLock.lock()
        defer { jamoLock.unlock() }
        guard !jamoSymbolsLoaded else { return }

        let bundle = Self.resourceBundle
        guard let url = bundle.url(forResource: "jamo_symbols", withExtension: "json") else {
            DebugLogger.log("HanjaManager: jamo_symbols.json not found in bundle")
            jamoSymbolsLoaded = true
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let raw = try JSONDecoder().decode([String: [JamoSymbolRaw]].self, from: data)
            for (jamo, symbols) in raw {
                jamoSymbols[jamo] = symbols.map { HanjaEntry(hangul: jamo, hanja: $0.char, meaning: $0.desc) }
            }
            DebugLogger.log("HanjaManager: Loaded jamo symbols (\(jamoSymbols.count) keys, \(jamoSymbols.values.map(\.count).reduce(0, +)) entries)")
        } catch {
            DebugLogger.log("HanjaManager: Failed to load jamo_symbols.json: \(error)")
        }
        jamoSymbolsLoaded = true
    }

    /// Search for Hanja entries matching the given Hangul key (exact match)
    /// - Parameter key: Hangul text to search for (e.g., "가") or a jamo consonant (e.g., "ㅁ")
    /// - Returns: Array of Hanja entries, empty if no results or the dictionary
    ///   is still loading on another thread
    public func search(key: String) -> [HanjaEntry] {
        // Jamo consonant → search symbol table instead of hanja dictionary
        // The composer's preedit is Compatibility Jamo (U+3131~), as are our
        // JSON keys. Choseong Jamo (U+1100~) is converted, for other callers.
        let normalizedKey: String
        if key.count == 1, let char = key.first, char.isJamoConsonant {
            normalizedKey = key
        } else if key.count == 1, let char = key.first, char.isChoseongJamo {
            normalizedKey = String(char.choseongToCompatibility)
        } else {
            normalizedKey = ""
        }

        if !normalizedKey.isEmpty {
            loadJamoSymbolsIfNeeded()
            return jamoLock.withLock { jamoSymbols[normalizedKey] ?? [] }
        }

        guard let dictionary = dictionary() else {
            DebugLogger.log("HanjaManager: dictionary not ready, no candidates")
            return []
        }
        return dictionary.entries(for: key)
    }

    /// Longest word a lookup tries, in syllables. Covers all but 150 of
    /// the dictionary's 222,709 keys, and fits in the composer's text buffer.
    public static let maxWordLength = 10

    /// Candidates for the Hangul word that ends `text`: the longest ending that is
    /// a dictionary word first, then each shorter one down to the last syllable.
    /// Each entry's `hangul` is the text it replaces.
    ///
    /// "대한민국" gives 大韓民國, then 民國, then 國 and the other readings of 국.
    public func searchWord(endingWith text: String) -> [HanjaEntry] {
        var word = Substring(Self.trailingHangulWord(in: text))
        var results: [HanjaEntry] = []
        while !word.isEmpty {
            results += search(key: String(word))
            word = word.dropFirst()
        }
        return results
    }

    /// The Hangul syllables at the end of `text`, at most `maxWordLength` of them.
    static func trailingHangulWord(in text: String) -> String {
        String(text.precomposedStringWithCanonicalMapping.reversed().prefix { $0.isHangulSyllable }.prefix(maxWordLength).reversed())
    }

    /// Resource bundle for loading dictionary data
    private static let resourceBundle: Bundle = {
        if let resourceURL = Bundle.main.resourceURL,
           let resourceBundle = Bundle(url: resourceURL.appendingPathComponent("PriType_PriTypeCore.bundle")) {
            return resourceBundle
        }
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }()
}

/// Raw JSON structure for jamo_symbols.json
private struct JamoSymbolRaw: Decodable {
    let char: String
    let desc: String
}

/// A simple value type for Hanja search results
public struct HanjaEntry: Sendable {
    public let hangul: String   // 한글 (e.g., "가") or jamo (e.g., "ㅁ")
    public let hanja: String    // 한자 (e.g., "可") or symbol (e.g., "♥")
    public let meaning: String  // 뜻 (e.g., "옳을 가") or description (e.g., "검은 하트")
}

// MARK: - Character Extension for Jamo detection
extension Character {
    /// Returns true for a precomposed Hangul syllable (가-힣, U+AC00-U+D7A3)
    var isHangulSyllable: Bool {
        guard unicodeScalars.count == 1, let scalar = unicodeScalars.first else { return false }
        return (0xAC00...0xD7A3).contains(scalar.value)
    }

    /// Returns true if this character is a Hangul Compatibility Jamo consonant (ㄱ-ㅎ, U+3131-U+314E)
    var isJamoConsonant: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        let v = scalar.value
        return v >= 0x3131 && v <= 0x314E
    }
    
    /// Returns true if this character is a Hangul Jamo Choseong (initial consonant, U+1100-U+1112)
    /// The positional jamo of decomposed (NFD) text
    var isChoseongJamo: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        let v = scalar.value
        return v >= 0x1100 && v <= 0x1112
    }
    
    /// Convert a Choseong Jamo (U+1100~) to Compatibility Jamo (U+3131~)
    var choseongToCompatibility: Character {
        guard let scalar = unicodeScalars.first else { return self }
        let v = scalar.value
        guard v >= 0x1100 && v <= 0x1112 else { return self }
        // Mapping: U+1100 ㄱ→U+3131, U+1101 ㄲ→U+3132, ...
        let mapping: [UInt32: UInt32] = [
            0x1100: 0x3131, // ㄱ
            0x1101: 0x3132, // ㄲ
            0x1102: 0x3134, // ㄴ
            0x1103: 0x3137, // ㄷ
            0x1104: 0x3138, // ㄸ
            0x1105: 0x3139, // ㄹ
            0x1106: 0x3141, // ㅁ
            0x1107: 0x3142, // ㅂ
            0x1108: 0x3143, // ㅃ
            0x1109: 0x3145, // ㅅ
            0x110A: 0x3146, // ㅆ
            0x110B: 0x3147, // ㅇ
            0x110C: 0x3148, // ㅈ
            0x110D: 0x3149, // ㅉ
            0x110E: 0x314A, // ㅊ
            0x110F: 0x314B, // ㅋ
            0x1110: 0x314C, // ㅌ
            0x1111: 0x314D, // ㅍ
            0x1112: 0x314E, // ㅎ
        ]
        if let compat = mapping[v], let scalar = UnicodeScalar(compat) {
            return Character(scalar)
        }
        return self
    }
}
