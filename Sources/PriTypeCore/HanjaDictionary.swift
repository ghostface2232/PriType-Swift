import Foundation

/// Read-only Hanja dictionary stored as a sorted binary file and memory-mapped.
///
/// Parsing `hanja.txt` into a trie kept ~68 MB resident and took about a second.
/// The compiled file is mapped instead: opening it reads only the header and the
/// offset table, and a lookup touches the few pages its binary search visits.
///
/// Layout (all integers little-endian UInt32):
///
///     0   magic "PTHJ"
///     4   version (1)
///     8   key count N
///     12  notice offset, 16 notice length   — license text of the source data
///     20  index offset                      — N + 1 record offsets, relative to the pool
///     24  pool offset, 28 pool length
///
/// Record i spans `index[i] ..< index[i + 1]` in the pool:
/// `key "\n" (hanja "\t" comment "\n")*`. Records are sorted by the UTF-8 bytes of
/// their NFC key, and entries keep their order from the source file.
public struct HanjaDictionary: Sendable {
    static let magic: [UInt8] = Array("PTHJ".utf8)
    static let version: UInt32 = 1
    static let headerSize = 32

    public enum FormatError: Error, Equatable {
        case badHeader
        case badIndex
        case badSource(line: Int)
    }

    private let data: Data
    private let keyCount: Int
    private let indexOffset: Int
    private let poolOffset: Int
    public let notice: String

    public var count: Int { keyCount }

    /// Map a compiled dictionary file. Pages are read on demand.
    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    /// Validates the header and every index offset once, so lookups can trust them.
    public init(data: Data) throws {
        // Offsets below are relative to the first byte; a slice would shift them.
        let data = data.startIndex == 0 ? data : Data(data)
        guard data.count >= Self.headerSize,
              Array(data.prefix(4)) == Self.magic,
              Self.readUInt32(data, at: 4) == Self.version else {
            throw FormatError.badHeader
        }
        let count = Int(Self.readUInt32(data, at: 8))
        let noticeOffset = Int(Self.readUInt32(data, at: 12))
        let noticeLength = Int(Self.readUInt32(data, at: 16))
        let indexOffset = Int(Self.readUInt32(data, at: 20))
        let poolOffset = Int(Self.readUInt32(data, at: 24))
        let poolLength = Int(Self.readUInt32(data, at: 28))
        guard noticeOffset + noticeLength <= data.count,
              indexOffset + (count + 1) * 4 <= data.count,
              poolOffset + poolLength <= data.count else {
            throw FormatError.badHeader
        }
        var previous = 0
        for i in 0...count {
            let offset = Int(Self.readUInt32(data, at: indexOffset + i * 4))
            // Each record holds at least a one-byte key and its newline.
            guard offset <= poolLength, i == 0 ? offset == 0 : offset >= previous + 2 else {
                throw FormatError.badIndex
            }
            previous = offset
        }
        guard previous == poolLength else { throw FormatError.badIndex }

        self.data = data
        self.keyCount = count
        self.indexOffset = indexOffset
        self.poolOffset = poolOffset
        self.notice = String(decoding: data[data.startIndex + noticeOffset ..< data.startIndex + noticeOffset + noticeLength],
                             as: UTF8.self)
    }

    /// Entries whose key is exactly `key`, in source order.
    public func entries(for key: String) -> [HanjaEntry] {
        let needle = Array(key.precomposedStringWithCanonicalMapping.utf8)
        guard !needle.isEmpty else { return [] }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [HanjaEntry] in
            let pool = UnsafeRawBufferPointer(rebasing: raw[poolOffset...])
            func recordStart(_ i: Int) -> Int {
                Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: indexOffset + i * 4, as: UInt32.self)))
            }
            var low = 0
            var high = keyCount
            while low < high {
                let mid = (low + high) / 2
                let start = recordStart(mid)
                let end = recordStart(mid + 1)
                switch Self.compare(needle, pool, from: start, to: end) {
                case .orderedAscending: high = mid
                case .orderedDescending: low = mid + 1
                case .orderedSame:
                    return Self.parseEntries(pool, from: start + needle.count + 1, to: end, key: key)
                }
            }
            return []
        }
    }

    /// Compare `needle` with the key of the record at `start ..< end`.
    private static func compare(_ needle: [UInt8], _ pool: UnsafeRawBufferPointer,
                                from start: Int, to end: Int) -> ComparisonResult {
        var i = 0
        var p = start
        while p < end {
            let byte = pool[p]
            if byte == 0x0A { // end of the record key
                return i == needle.count ? .orderedSame : .orderedDescending
            }
            if i == needle.count { return .orderedAscending }
            if needle[i] != byte { return needle[i] < byte ? .orderedAscending : .orderedDescending }
            i += 1
            p += 1
        }
        return .orderedDescending
    }

    private static func parseEntries(_ pool: UnsafeRawBufferPointer, from start: Int, to end: Int,
                                     key: String) -> [HanjaEntry] {
        var entries: [HanjaEntry] = []
        var lineStart = start
        var tab = -1
        var p = start
        while p < end {
            switch pool[p] {
            case 0x09 where tab < 0:
                tab = p
            case 0x0A:
                if tab > lineStart {
                    entries.append(HanjaEntry(
                        hangul: key,
                        hanja: String(decoding: UnsafeRawBufferPointer(rebasing: pool[lineStart..<tab]), as: UTF8.self),
                        meaning: String(decoding: UnsafeRawBufferPointer(rebasing: pool[(tab + 1)..<p]), as: UTF8.self)))
                }
                lineStart = p + 1
                tab = -1
            default:
                break
            }
            p += 1
        }
        return entries
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    // MARK: - Compiling

    /// Compile libhangul's `hanja.txt` format (`key:hanja:comment`, `#` comments).
    ///
    /// Fields are parsed the way libhangul's `HanjaTable` parses them, so the
    /// compiled dictionary returns the same entries in the same order. The
    /// leading comment block (the data's license) is kept as the notice.
    public static func compile(source: String) throws -> Data {
        var notice: [String] = []
        var inHeader = true
        var groups: [[UInt8]: [(hanja: String, comment: String)]] = [:]
        var lineNumber = 0
        for rawLine in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                if inHeader { notice.append(String(line.dropFirst().drop(while: { $0 == " " }))) }
                continue
            }
            if line.isEmpty { continue }
            inHeader = false
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
            let hanja = parts[1].trimmingCharacters(in: .whitespaces)
            let comment = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
            guard !key.isEmpty, !hanja.isEmpty else { continue }
            guard !(key + hanja + comment).contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }) else {
                throw FormatError.badSource(line: lineNumber)
            }
            groups[Array(key.utf8), default: []].append((hanja, comment))
        }

        let keys = groups.keys.sorted { $0.lexicographicallyPrecedes($1) }
        var pool: [UInt8] = []
        var index: [UInt32] = [0]
        index.reserveCapacity(keys.count + 1)
        for key in keys {
            pool.append(contentsOf: key)
            pool.append(0x0A)
            for entry in groups[key] ?? [] {
                pool.append(contentsOf: entry.hanja.utf8)
                pool.append(0x09)
                pool.append(contentsOf: entry.comment.utf8)
                pool.append(0x0A)
            }
            index.append(UInt32(pool.count))
        }

        let noticeBytes = Array(notice.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let noticeOffset = headerSize
        let indexOffset = noticeOffset + noticeBytes.count
        let poolOffset = indexOffset + index.count * 4

        var out = Data(capacity: poolOffset + pool.count)
        out.append(contentsOf: magic)
        for value in [version, UInt32(keys.count), UInt32(noticeOffset), UInt32(noticeBytes.count),
                      UInt32(indexOffset), UInt32(poolOffset), UInt32(pool.count)] {
            append(value, to: &out)
        }
        out.append(contentsOf: noticeBytes)
        for value in index { append(value, to: &out) }
        out.append(contentsOf: pool)
        return out
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
