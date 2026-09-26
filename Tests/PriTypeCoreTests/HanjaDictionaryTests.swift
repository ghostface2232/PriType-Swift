import Foundation
import LibHangul
import Testing
@testable import PriTypeCore

@Suite("HanjaDictionary")
struct HanjaDictionaryTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sourceURL = repoRoot.appendingPathComponent("Tools/hanja/hanja.txt")
    static let compiledURL = repoRoot.appendingPathComponent("Sources/PriTypeCore/Resources/hanja.dat")

    static let sample = """
    # Sample notice
    # second line

    가:可:옳을 가
    가:家:집 가
    가나:假那:
    가나다:假那多:
    나:那:어찌 나
    # comment in the middle
    가:加:더할 가
    각:各:각각 각
    """

    @Test("Lookups return every entry for the exact key, in source order")
    func exactLookup() throws {
        let dictionary = try HanjaDictionary(data: HanjaDictionary.compile(source: Self.sample))
        #expect(dictionary.count == 5)
        #expect(dictionary.entries(for: "가").map(\.hanja) == ["可", "家", "加"])
        #expect(dictionary.entries(for: "가").map(\.meaning) == ["옳을 가", "집 가", "더할 가"])
        #expect(dictionary.entries(for: "가나").map(\.hanja) == ["假那"])
        #expect(dictionary.entries(for: "가나").first?.meaning == "")
        #expect(dictionary.entries(for: "가나다").first?.hangul == "가나다")
        #expect(dictionary.entries(for: "각").map(\.hanja) == ["各"])
        #expect(dictionary.entries(for: "나").map(\.hanja) == ["那"])
    }

    @Test("Glossed words come before unglossed ones; single syllables keep source order")
    func commonWordsFirst() throws {
        let source = """
        한국:寒國:
        한국:寒菊:
        한국:韓國:대한민국
        한국:汗國:
        한:汗:땀 한
        한:韓:나라 한
        """
        let dictionary = try HanjaDictionary(data: HanjaDictionary.compile(source: source))
        #expect(dictionary.entries(for: "한국").map(\.hanja) == ["韓國", "寒國", "寒菊", "汗國"])
        #expect(dictionary.entries(for: "한").map(\.hanja) == ["汗", "韓"])
    }

    @Test("Prefixes, extensions and absent keys find nothing")
    func misses() throws {
        let dictionary = try HanjaDictionary(data: HanjaDictionary.compile(source: Self.sample))
        for key in ["", "가나다라", "각가", "다", "a", "ㄱ", "\u{0}"] {
            #expect(dictionary.entries(for: key).isEmpty, "\(key)")
        }
    }

    @Test("Decomposed Hangul finds the precomposed key")
    func normalizesQuery() throws {
        let dictionary = try HanjaDictionary(data: HanjaDictionary.compile(source: Self.sample))
        let decomposed = "가".decomposedStringWithCanonicalMapping
        #expect(decomposed.unicodeScalars.count == 2)
        #expect(dictionary.entries(for: decomposed).count == 3)
    }

    @Test("The leading comment block is kept as the notice")
    func keepsNotice() throws {
        let dictionary = try HanjaDictionary(data: HanjaDictionary.compile(source: Self.sample))
        #expect(dictionary.notice == "Sample notice\nsecond line")
    }

    @Test("Damaged files are rejected when opened, not when searched")
    func rejectsDamage() throws {
        let data = try HanjaDictionary.compile(source: Self.sample)
        #expect(throws: HanjaDictionary.FormatError.badHeader) { try HanjaDictionary(data: Data()) }
        #expect(throws: HanjaDictionary.FormatError.badHeader) { try HanjaDictionary(data: data.prefix(40)) }
        var wrongMagic = data
        wrongMagic[0] = 0
        #expect(throws: HanjaDictionary.FormatError.badHeader) { try HanjaDictionary(data: wrongMagic) }
        // Point the second record past the end of the pool.
        var badOffset = data
        let indexOffset = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) })
        badOffset.replaceSubrange((indexOffset + 4)..<(indexOffset + 8), with: [0xFF, 0xFF, 0xFF, 0x00])
        #expect(throws: HanjaDictionary.FormatError.badIndex) { try HanjaDictionary(data: badOffset) }
    }

    @Test("A slice of a larger buffer reads the same")
    func readsSlices() throws {
        let data = try HanjaDictionary.compile(source: Self.sample)
        let padded = Data([1, 2, 3]) + data
        let dictionary = try HanjaDictionary(data: padded.dropFirst(3))
        #expect(dictionary.entries(for: "가").count == 3)
    }

    @Test("Tabs in a field would break the record format, so they fail the build")
    func rejectsTabs() {
        #expect(throws: HanjaDictionary.FormatError.badSource(line: 1)) {
            try HanjaDictionary.compile(source: "가:可\t家:옳을 가")
        }
    }

    @Test("The bundled hanja.dat is compiled from the current hanja.txt")
    func bundledDictionaryIsUpToDate() throws {
        let source = try String(contentsOf: Self.sourceURL, encoding: .utf8)
        let compiled = try HanjaDictionary.compile(source: source)
        let bundled = try Data(contentsOf: Self.compiledURL)
        #expect(compiled == bundled, "Run `swift run PriTypeHanjaCompiler` and commit hanja.dat")
    }

    @Test("Answers match libhangul's HanjaTable for the same source")
    func matchesLibhangul() throws {
        let table = HanjaTable()
        #expect(table.load(filename: Self.sourceURL.path))
        let dictionary = try HanjaDictionary(contentsOf: Self.compiledURL)
        let source = try String(contentsOf: Self.sourceURL, encoding: .utf8)
        var keys: [String] = []
        for (n, line) in source.split(whereSeparator: \.isNewline).enumerated()
        where n % 211 == 0 && !line.hasPrefix("#") {
            if let key = line.split(separator: ":").first { keys.append(String(key)) }
        }
        keys += ["가", "한", "국", "인", "대한민국", "한국", "ㄱㄴ순"]
        #expect(keys.count > 1000)
        for key in keys {
            let source = table.matchExact(key: key).map { list in
                (0..<list.getSize()).compactMap { list.getNth($0) }.map { (hanja: $0.getValue(), comment: $0.getComment()) }
            } ?? []
            let expected = HanjaDictionary.candidateOrder(source, keySyllables: key.count).map { [$0.hanja, $0.comment] }
            let actual = dictionary.entries(for: key).map { [$0.hanja, $0.meaning] }
            #expect(actual == expected, "\(key)")
        }
    }
}

@Suite("HanjaManager loading")
struct HanjaManagerLoadingTests {
    private final class Gate: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
    }

    @Test("A search while another thread loads waits for it and finds entries")
    func searchWaitsForLoad() throws {
        let data = try HanjaDictionary.compile(source: HanjaDictionaryTests.sample)
        let gate = Gate()
        let manager = HanjaManager(loader: {
            gate.started.signal()
            gate.release.wait()
            return try? HanjaDictionary(data: data)
        })
        // Long enough that only a hang could outlast it, whatever else runs.
        manager.loadWaitLimit = 30
        Thread { manager.loadIfNeeded() }.start()
        gate.started.wait()
        // The load finishes a moment after the Hanja key: the key still gets its
        // candidates, rather than none until it is pressed again.
        Thread {
            Thread.sleep(forTimeInterval: 0.02)
            gate.release.signal()
        }.start()
        #expect(manager.search(key: "가").count == 3)
        #expect(manager.isLoaded)
    }

    @Test("A load that does not finish in time leaves the search empty, not stuck")
    func searchWaitIsBounded() throws {
        let data = try HanjaDictionary.compile(source: HanjaDictionaryTests.sample)
        let gate = Gate()
        let manager = HanjaManager(loader: {
            gate.started.signal()
            gate.release.wait()
            return try? HanjaDictionary(data: data)
        })
        let finished = DispatchSemaphore(value: 0)
        Thread { manager.loadIfNeeded(); finished.signal() }.start()
        gate.started.wait()

        let start = Date()
        #expect(manager.searchWord(endingWith: "가가가가").isEmpty)
        // One wait for the whole word, not one per ending (four would be 0.8 s).
        #expect(Date().timeIntervalSince(start) < manager.loadWaitLimit * 3)
        #expect(!manager.isLoaded)

        gate.release.signal()
        finished.wait()
        #expect(manager.search(key: "가").count == 3)
    }

    @Test("A failed load is not retried on every key press")
    func failedLoadIsRemembered() {
        let attempts = LockedCounter()
        let manager = HanjaManager(loader: { attempts.increment(); return nil })
        #expect(manager.search(key: "가").isEmpty)
        #expect(manager.search(key: "가").isEmpty)
        #expect(attempts.value == 1)
    }

    @Test("Unloading drops the dictionary; the next search maps it again")
    func unloadAndReload() throws {
        let data = try HanjaDictionary.compile(source: HanjaDictionaryTests.sample)
        let attempts = LockedCounter()
        let manager = HanjaManager(loader: { attempts.increment(); return try? HanjaDictionary(data: data) })
        manager.loadIfNeeded()
        #expect(manager.isLoaded)
        manager.unload()
        #expect(!manager.isLoaded)
        #expect(manager.search(key: "가").count == 3)
        #expect(attempts.value == 2)
    }

    @Test("Turning Hanja off while the dictionary loads leaves it unmapped")
    func unloadDuringLoad() throws {
        let data = try HanjaDictionary.compile(source: HanjaDictionaryTests.sample)
        let gate = Gate()
        let manager = HanjaManager(loader: {
            gate.started.signal()
            gate.release.wait()
            return try? HanjaDictionary(data: data)
        })
        let finished = DispatchSemaphore(value: 0)
        Thread { manager.loadIfNeeded(); finished.signal() }.start()
        gate.started.wait()
        manager.unload()
        gate.release.signal()
        finished.wait()
        #expect(!manager.isLoaded)
    }

    @Test("Turning Hanja off and on again while the dictionary loads keeps it")
    func reloadDuringDiscardedLoad() throws {
        let data = try HanjaDictionary.compile(source: HanjaDictionaryTests.sample)
        let gate = Gate()
        let attempts = LockedCounter()
        let manager = HanjaManager(loader: {
            attempts.increment()
            gate.started.signal()
            gate.release.wait()
            return try? HanjaDictionary(data: data)
        })
        let finished = DispatchSemaphore(value: 0)
        Thread { manager.loadIfNeeded(); finished.signal() }.start()
        gate.started.wait()
        manager.unload()
        manager.preload()
        gate.release.signal()
        finished.wait()
        #expect(manager.isLoaded)
        #expect(attempts.value == 1)
    }

    @Test("Off, on, off again while the dictionary loads leaves it unmapped")
    func offOnOffDuringLoad() throws {
        let data = try HanjaDictionary.compile(source: HanjaDictionaryTests.sample)
        let gate = Gate()
        let attempts = LockedCounter()
        let manager = HanjaManager(loader: {
            attempts.increment()
            gate.started.signal()
            gate.release.wait()
            return try? HanjaDictionary(data: data)
        })
        let finished = DispatchSemaphore(value: 0)
        Thread { manager.loadIfNeeded(); finished.signal() }.start()
        gate.started.wait()
        manager.unload()
        manager.preload()
        manager.unload()
        gate.release.signal()
        finished.wait()
        // The preload's background block may run after this; it must not load.
        Thread.sleep(forTimeInterval: 0.05)
        #expect(!manager.isLoaded)
        #expect(attempts.value == 1)
    }

    @Test("Jamo keys use the symbol table even without the dictionary")
    func jamoWithoutDictionary() {
        let manager = HanjaManager(loader: { nil })
        #expect(!manager.search(key: "ㅁ").isEmpty)
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite("Hanja word lookup")
struct HanjaWordLookupTests {
    static let source = """
    국:國:나라 국
    국:局:판 국
    민국:民國:
    대한민국:大韓民國:
    한국:韓國:
    한:韓:나라 한
    가:家:집 가
    """

    private func manager() throws -> HanjaManager {
        let data = try HanjaDictionary.compile(source: Self.source)
        return HanjaManager(loader: { try? HanjaDictionary(data: data) })
    }

    @Test("Longer words come first, then each shorter ending")
    func longestFirst() throws {
        let results = try manager().searchWord(endingWith: "대한민국")
        #expect(results.map(\.hanja) == ["大韓民國", "民國", "國", "局"])
        #expect(results.map(\.hangul) == ["대한민국", "민국", "국", "국"])
    }

    @Test("Only the Hangul run at the end counts")
    func stopsAtNonHangul() throws {
        let manager = try manager()
        #expect(manager.searchWord(endingWith: "우리 한국").map(\.hanja) == ["韓國", "國", "局"])
        #expect(manager.searchWord(endingWith: "abc한").map(\.hanja) == ["韓"])
        #expect(manager.searchWord(endingWith: "한국 ").isEmpty)
        #expect(manager.searchWord(endingWith: "").isEmpty)
        #expect(manager.searchWord(endingWith: "한ㄱ").isEmpty)
    }

    @Test("Text without a dictionary word before the last syllable still finds it")
    func unknownPrefix() throws {
        #expect(try manager().searchWord(endingWith: "오늘가").map(\.hanja) == ["家"])
    }

    @Test("The word is capped at maxWordLength syllables")
    func capsLength() {
        let long = String(repeating: "가", count: 25)
        #expect(HanjaManager.trailingHangulWord(in: long).count == HanjaManager.maxWordLength)
        #expect(HanjaManager.trailingHangulWord(in: "x대한") == "대한")
        let decomposed = "대한".decomposedStringWithCanonicalMapping
        #expect(HanjaManager.trailingHangulWord(in: decomposed) == "대한")
    }

    @Test("A word replaces only the text it was looked up from")
    func replacementCheck() {
        let word = HanjaEntry(hangul: "대한", hanja: "大韓", meaning: "")
        #expect(HangulComposer.canReplace("대한", with: word))
        #expect(!HangulComposer.canReplace("가한", with: word))
        #expect(!HangulComposer.canReplace(nil, with: word), "a host that cannot show its text")
        #expect(!HangulComposer.canReplace("", with: word), "a host that reports nothing")
        let syllable = HanjaEntry(hangul: "한", hanja: "韓", meaning: "")
        #expect(HangulComposer.canReplace("한", with: syllable))
        #expect(!HangulComposer.canReplace("요", with: syllable), "one syllable is checked too")
        #expect(!HangulComposer.canReplace("\u{11AB}", with: syllable), "a lone jamo of NFD text")
        #expect(!HangulComposer.canReplace(nil, with: syllable))
    }

    @Test("The bundled dictionary converts a whole word")
    func bundledWord() {
        HanjaManager.shared.loadIfNeeded()
        let results = HanjaManager.shared.searchWord(endingWith: "대한민국")
        #expect(results.first?.hanja == "大韓民國")
        #expect(results.contains { $0.hangul == "국" })
        #expect(HanjaManager.shared.searchWord(endingWith: "한국").first?.hanja == "韓國")
        #expect(HanjaManager.shared.searchWord(endingWith: "미국").first?.hanja == "美國")
    }
}
