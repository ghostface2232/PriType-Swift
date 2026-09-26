import Testing
import Foundation
@testable import PriTypeCore

@Suite("Enabled Roman override policy")
struct RomanOverridePolicyTests {
    @Test("Disabled ABC is never revived by a keyboard override")
    func onlyEnabledLayouts() {
        #expect(InputSourceManager.enabledRomanKeyboardLayoutID(in: []) == nil)
        #expect(InputSourceManager.enabledRomanKeyboardLayoutID(in: ["com.pritype.inputmethod.v2.english"]) == nil)
        #expect(InputSourceManager.enabledRomanKeyboardLayoutID(in: ["com.apple.keylayout.US"]) == "com.apple.keylayout.US")
        #expect(InputSourceManager.enabledRomanKeyboardLayoutID(in: ["com.apple.keylayout.US", "com.apple.keylayout.ABC"]) == "com.apple.keylayout.ABC")
    }
}

@Suite("Roman override layout resolution")
struct RomanLayoutResolutionTests {
    private final class Lister {
        var calls = 0
        var answer: [String]? = ["com.apple.keylayout.ABC"]
        func list() -> [String]? { calls += 1; return answer }
    }

    @Test("The enabled list is read once, then again only after it changes")
    func resolvedOncePerChange() {
        var resolution = RomanLayoutResolution()
        let lister = Lister()
        #expect(resolution.layoutID(resolving: lister.list) == "com.apple.keylayout.ABC")
        #expect(resolution.layoutID(resolving: lister.list) == "com.apple.keylayout.ABC")
        #expect(lister.calls == 1, "a switch to English asks TIS nothing new")

        lister.answer = ["com.apple.keylayout.US"]
        resolution.invalidate()
        #expect(resolution.layoutID(resolving: lister.list) == "com.apple.keylayout.US")
        #expect(lister.calls == 2)
    }

    @Test("No Roman layout is an answer too; an unreadable list is not")
    func absenceIsKeptFailureIsNot() {
        var resolution = RomanLayoutResolution()
        let lister = Lister()
        lister.answer = nil
        #expect(resolution.layoutID(resolving: lister.list) == nil)
        #expect(resolution.layoutID(resolving: lister.list) == nil)
        #expect(lister.calls == 2, "TIS could not say: ask again next time")

        lister.answer = []
        #expect(resolution.layoutID(resolving: lister.list) == nil)
        #expect(resolution.layoutID(resolving: lister.list) == nil)
        #expect(lister.calls == 3, "neither ABC nor US is enabled: that holds until the list changes")
    }
}

// MARK: - Cleanup Atomicity / Verification Tests

@Suite("Disable ABC keyboard layout", .serialized)
struct DisableABCTests {

    private func makeDefaults(_ name: String = #function) -> (UserDefaults, String) {
        let suite = "com.pritype.tests.abc.\(Self.slug(name))"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    /// `#function` arrives as "name()"; strip what cannot appear in a domain name.
    static func slug(_ name: String) -> String {
        name.filter { $0.isLetter || $0.isNumber }
    }

    /// `removePersistentDomain` alone leaves a stub plist behind; `removeSuite` is
    /// what detaches the domain, so scratch suites do not accumulate on disk.
    static func discard(_ defaults: UserDefaults, _ suite: String) {
        defaults.removePersistentDomain(forName: suite)
        UserDefaults.standard.removeSuite(named: suite)
        // removeSuite detaches the domain but cfprefsd still leaves the plist on
        // disk; delete it so scratch suites do not accumulate in ~/Library/Preferences.
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    private let abcByName: [String: Any] = [
        "InputSourceKind": "Keyboard Layout",
        "KeyboardLayout Name": "ABC",
        "KeyboardLayout ID": 252
    ]
    private let abcByIDOnly: [String: Any] = [
        "InputSourceKind": "Keyboard Layout",
        "KeyboardLayout ID": 252
    ]
    private let priType: [String: Any] = [
        "Bundle ID": "com.pritype.inputmethod.v2",
        "InputSourceKind": "Keyboard Input Method"
    ]

    @Test("ABC is matched by layout name and by layout ID")
    func abcEntryMatching() {
        #expect(InputSourceManager.isABCLayoutEntry(abcByName))
        #expect(InputSourceManager.isABCLayoutEntry(abcByIDOnly))
        #expect(!InputSourceManager.isABCLayoutEntry(priType))
        #expect(!InputSourceManager.isABCLayoutEntry([
            "KeyboardLayout Name": "U.S.", "KeyboardLayout ID": 0
        ]))
    }

    @Test("Removing ABC leaves the other sources and verifies the write")
    func removesABC() {
        let (defaults, suite) = makeDefaults()
        defer { Self.discard(defaults, suite) }
        defaults.set([abcByName, priType], forKey: "AppleEnabledInputSources")

        #expect(InputSourceManager.disableABCKeyboardLayout(in: defaults) == .removed)
        let after = defaults.array(forKey: "AppleEnabledInputSources") as? [[String: Any]] ?? []
        #expect(after.count == 1)
        #expect(!after.contains(where: InputSourceManager.isABCLayoutEntry))
    }

    @Test("An ID-only ABC entry is removed too")
    func removesIDOnlyEntry() {
        let (defaults, suite) = makeDefaults()
        defer { Self.discard(defaults, suite) }
        defaults.set([abcByIDOnly, priType], forKey: "AppleEnabledInputSources")

        #expect(InputSourceManager.disableABCKeyboardLayout(in: defaults) == .removed)
        #expect((defaults.array(forKey: "AppleEnabledInputSources") as? [[String: Any]])?.count == 1)
    }

    @Test("An already-clean list is reported as alreadyAbsent, not as a write")
    func alreadyAbsentIsDistinct() {
        let (defaults, suite) = makeDefaults()
        defer { Self.discard(defaults, suite) }
        defaults.set([priType], forKey: "AppleEnabledInputSources")

        #expect(InputSourceManager.disableABCKeyboardLayout(in: defaults) == .alreadyAbsent)
        #expect((defaults.array(forKey: "AppleEnabledInputSources") as? [[String: Any]])?.count == 1)
    }

    @Test("An unreadable list fails instead of silently succeeding")
    func unreadableListFails() {
        let (defaults, suite) = makeDefaults()
        defer { Self.discard(defaults, suite) }

        // The previous implementation reported success for every outcome, which is
        // what made a failed write look like "ABC came back".
        if case .failed = InputSourceManager.disableABCKeyboardLayout(in: defaults) {
            // expected
        } else {
            Issue.record("missing AppleEnabledInputSources must be reported as a failure")
        }
    }

    @Test("ABC variants and Pinyin are left alone")
    func abcFamilyIsPreserved() {
        // These all satisfy the loose `id.contains("ABC")` test, and none is the
        // plain ABC layout. Removing or mis-confirming them is finding #1 of the
        // review: a permanent false failure for anyone who keeps one enabled.
        for variant in ["ABC – QWERTZ", "ABC – AZERTY", "ABC – India"] {
            #expect(!InputSourceManager.isABCLayoutEntry([
                "InputSourceKind": "Keyboard Layout",
                "KeyboardLayout Name": variant,
                "KeyboardLayout ID": -2
            ]), "\(variant) must be preserved")
        }
        #expect(!InputSourceManager.isABCLayoutEntry([
            "InputSourceKind": "Input Mode",
            "Bundle ID": "com.apple.inputmethod.SCIM.ITABC"
        ]))
    }

    @Test("Layout ID 252 only matches an unnamed keyboard-layout entry")
    func layoutIDBranchIsNarrow() {
        // A third-party .keylayout reusing resource ID 252 must not be deleted.
        #expect(!InputSourceManager.isABCLayoutEntry([
            "InputSourceKind": "Keyboard Layout",
            "KeyboardLayout Name": "My Custom Layout",
            "KeyboardLayout ID": 252
        ]))
        #expect(!InputSourceManager.isABCLayoutEntry([
            "InputSourceKind": "Input Mode",
            "KeyboardLayout ID": 252
        ]))
        // The narrow case the branch exists for: a layout entry with no name.
        #expect(InputSourceManager.isABCLayoutEntry([
            "InputSourceKind": "Keyboard Layout",
            "KeyboardLayout ID": 252
        ]))
    }

    @Test("Removal keeps the surviving entries, not merely the count")
    func survivingEntriesAreIdentified() {
        let (defaults, suite) = makeDefaults()
        defer { Self.discard(defaults, suite) }
        let variant: [String: Any] = [
            "InputSourceKind": "Keyboard Layout",
            "KeyboardLayout Name": "ABC – QWERTZ",
            "KeyboardLayout ID": -2
        ]
        defaults.set([abcByName, variant, priType], forKey: "AppleEnabledInputSources")

        #expect(InputSourceManager.disableABCKeyboardLayout(in: defaults) == .removed)
        let after = defaults.array(forKey: "AppleEnabledInputSources") as? [[String: Any]] ?? []
        // Order is preserved and exactly the plain ABC entry is gone.
        #expect((after.first?["KeyboardLayout Name"] as? String) == "ABC – QWERTZ")
        #expect((after.last?["Bundle ID"] as? String) == "com.pritype.inputmethod.v2")
        #expect(after.count == 2)
    }

    @Test("A value of the wrong shape fails rather than reporting no change")
    func wrongShapedValueFails() {
        let (defaults, suite) = makeDefaults()
        defer { Self.discard(defaults, suite) }
        defaults.set(["not-a-dictionary"], forKey: "AppleEnabledInputSources")

        if case .failed = InputSourceManager.disableABCKeyboardLayout(in: defaults) {
            // expected
        } else {
            Issue.record("a non-[[String: Any]] value must be reported as a failure")
        }
    }

    @Test("Preference removal followed by a stale-TIS retry remains unconfirmed")
    @MainActor
    func retryRequiresLiveRemoval() async throws {
        let (defaults, suite) = makeDefaults()
        defer { Self.discard(defaults, suite) }
        defaults.set([abcByName, priType], forKey: "AppleEnabledInputSources")

        let first = InputSourceManager.disableABCKeyboardLayout(in: defaults)
        #expect(first == .removed)
        let firstConfirmed = try await ABCRemovalVerification.confirm(
            result: first, isDisabled: { false }, wait: {}
        )
        #expect(!firstConfirmed)

        let retry = InputSourceManager.disableABCKeyboardLayout(in: defaults)
        #expect(retry == .alreadyAbsent)
        let retryConfirmed = try await ABCRemovalVerification.confirm(
            result: retry, isDisabled: { false }, wait: {}
        )
        #expect(!retryConfirmed)
        let liveRemovalConfirmed = try await ABCRemovalVerification.confirm(
            result: retry, isDisabled: { true }, wait: {}
        )
        #expect(liveRemovalConfirmed)
    }

    @Test("Removal is idempotent")
    func removalIsIdempotent() {
        let (defaults, suite) = makeDefaults()
        defer { Self.discard(defaults, suite) }
        defaults.set([abcByName, priType], forKey: "AppleEnabledInputSources")

        #expect(InputSourceManager.disableABCKeyboardLayout(in: defaults) == .removed)
        #expect(InputSourceManager.disableABCKeyboardLayout(in: defaults) == .alreadyAbsent)
    }
}
