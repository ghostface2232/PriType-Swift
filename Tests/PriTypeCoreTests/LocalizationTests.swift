import Foundation
import Testing

@Suite("Localization")
struct LocalizationTests {
    private static let core = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/PriTypeCore")

    @Test("Every key L10n asks for exists in every language")
    func everyKeyIsTranslated() throws {
        let source = try String(contentsOf: Self.core.appendingPathComponent("L10n.swift"), encoding: .utf8)
        let keys = Set(source.matches(of: /localized\("([^"]+)"\)/).map { String($0.1) })
        #expect(!keys.isEmpty)
        for language in ["en", "ko"] {
            let url = Self.core.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
            let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
            let missing = keys.subtracting(table.keys).sorted()
            #expect(missing.isEmpty, "\(language) is missing \(missing)")
        }
    }
}
