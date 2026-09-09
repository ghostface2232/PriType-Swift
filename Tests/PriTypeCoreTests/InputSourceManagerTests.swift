import Testing
import Foundation
@testable import PriTypeCore

@Suite("InputSourceManager")
struct InputSourceManagerTests {
    @Test("Keeps PriType parent and BOTH Korean + English modes in enabled sources")
    func keepsPriTypeParentAndBothModesInEnabledSources() {
        // Dual-mode design: korean (com.pritype.inputmethod.v2) and english
        // (com.pritype.inputmethod.v2.english) are BOTH current — neither is stale.
        let sources: [[String: Any]] = [
            [
                "Bundle ID": "com.pritype.inputmethod.v2",
                "InputSourceKind": "Keyboard Input Method"
            ],
            [
                "Bundle ID": "com.pritype.inputmethod.v2",
                "InputSourceKind": "Input Mode",
                "Input Mode": "com.pritype.inputmethod.v2"
            ],
            [
                "Bundle ID": "com.pritype.inputmethod.v2",
                "InputSourceKind": "Input Mode",
                "Input Mode": "com.pritype.inputmethod.v2.english"
            ]
        ]

        let sanitized = InputSourceManager.sanitizedInputSources(
            sources,
            removeAppleKoreanInputModes: false,
            allowsPriTypeParentEntry: true
        )

        #expect(sanitized.count == 3)
        #expect(sanitized.contains { $0["Input Mode"] == nil })  // parent
        #expect(sanitized.contains { ($0["Input Mode"] as? String) == "com.pritype.inputmethod.v2" })          // korean
        #expect(sanitized.contains { ($0["Input Mode"] as? String) == "com.pritype.inputmethod.v2.english" })  // english (kept)
    }

    @Test("Keeps PriType parent and removes stale child modes from selected and history sources")
    func keepsPriTypeParentAndRemovesStaleChildModesFromSelectedAndHistorySources() {
        let sources: [[String: Any]] = [
            [
                "Bundle ID": "com.pritype.inputmethod.v2",
                "InputSourceKind": "Keyboard Input Method"
            ],
            [
                "Bundle ID": "com.pritype.inputmethod.v2",
                "InputSourceKind": "Input Mode",
                "Input Mode": "com.pritype.inputmethod.v2"
            ],
            [
                "Bundle ID": "com.pritype.inputmethod.v2",
                "InputSourceKind": "Input Mode",
                "Input Mode": "com.pritype.inputmethod.v2.korean"
            ],
            [
                "Bundle ID": "com.apple.PressAndHold",
                "InputSourceKind": "Non Keyboard Input Method"
            ]
        ]

        let sanitized = InputSourceManager.sanitizedInputSources(
            sources,
            removeAppleKoreanInputModes: false,
            allowsPriTypeParentEntry: true
        )

        #expect(sanitized.count == 3)
        #expect(sanitized.contains { ($0["Bundle ID"] as? String) == "com.pritype.inputmethod.v2" && $0["Input Mode"] == nil })
        #expect(sanitized.contains { ($0["Input Mode"] as? String) == "com.pritype.inputmethod.v2" })
        #expect(!sanitized.contains { ($0["Input Mode"] as? String) == "com.pritype.inputmethod.v2.korean" })
        #expect(sanitized.contains { ($0["Bundle ID"] as? String) == "com.apple.PressAndHold" })
    }
}

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

// MARK: - Cleanup Atomicity / Verification Tests

@Suite("Input source cleanup")
struct InputSourceCleanupTests {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "com.pritype.tests.hitoolbox.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func priTypeParent() -> [String: Any] {
        ["Bundle ID": "com.pritype.inputmethod.v2", "InputSourceKind": "Keyboard Input Method"]
    }

    private func priTypeMode(_ mode: String) -> [String: Any] {
        [
            "Bundle ID": "com.pritype.inputmethod.v2",
            "InputSourceKind": "Input Mode",
            "Input Mode": mode
        ]
    }

    @Test("Already-clean preferences are reported as needing no write")
    func noChangeNeeded() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clean = [priTypeParent(), priTypeMode("com.pritype.inputmethod.v2")]
        defaults.set(clean, forKey: "AppleEnabledInputSources")

        #expect(InputSourceManager.cleanupStaleInputSources(in: defaults) == .noChangeNeeded)
        let after = defaults.array(forKey: "AppleEnabledInputSources") as? [[String: Any]]
        #expect(after?.count == 2)
    }

    @Test("Missing keys are skipped rather than created")
    func absentKeysAreNotCreated() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(InputSourceManager.cleanupStaleInputSources(in: defaults) == .noChangeNeeded)
        for key in InputSourceManager.managedInputSourceKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key) must not be materialized")
        }
    }

    @Test("Stale entries are removed from every managed key and verified")
    func cleansAndVerifiesEveryKey() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let stale = [
            priTypeParent(),
            priTypeMode("com.pritype.inputmethod.v2"),
            priTypeMode("com.pritype.inputmethod.v2.korean")  // stale legacy child
        ]
        for key in InputSourceManager.managedInputSourceKeys {
            defaults.set(stale, forKey: key)
        }

        let result = InputSourceManager.cleanupStaleInputSources(in: defaults)
        #expect(result == .cleaned(keys: InputSourceManager.managedInputSourceKeys.sorted()))

        for key in InputSourceManager.managedInputSourceKeys {
            let after = defaults.array(forKey: key) as? [[String: Any]] ?? []
            #expect(after.count == 2, "\(key) should have lost exactly the stale child")
            #expect(!after.contains { ($0["Input Mode"] as? String) == "com.pritype.inputmethod.v2.korean" })
            #expect(after.contains { ($0["Input Mode"] as? String) == "com.pritype.inputmethod.v2" })
        }
    }

    @Test("Only keys that actually differ are rewritten")
    func onlyDifferingKeysAreWritten() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([priTypeParent(), priTypeMode("com.pritype.inputmethod.v2.korean")],
                     forKey: "AppleEnabledInputSources")
        defaults.set([priTypeParent()], forKey: "AppleSelectedInputSources")

        let result = InputSourceManager.cleanupStaleInputSources(in: defaults)
        #expect(result == .cleaned(keys: ["AppleEnabledInputSources"]))
        // The already-clean key is untouched, and the absent one stays absent.
        #expect((defaults.array(forKey: "AppleSelectedInputSources") as? [[String: Any]])?.count == 1)
        #expect(defaults.object(forKey: "AppleInputSourceHistory") == nil)
    }

    @Test("Duplicate entries collapse to one")
    func duplicatesCollapse() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mode = priTypeMode("com.pritype.inputmethod.v2")
        defaults.set([mode, mode, priTypeParent()], forKey: "AppleEnabledInputSources")

        #expect(InputSourceManager.cleanupStaleInputSources(in: defaults) == .cleaned(keys: ["AppleEnabledInputSources"]))
        let after = defaults.array(forKey: "AppleEnabledInputSources") as? [[String: Any]] ?? []
        #expect(after.count == 2)
    }

    @Test("Cleanup is idempotent")
    func cleanupIsIdempotent() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([priTypeParent(), priTypeMode("com.pritype.inputmethod.v2.korean")],
                     forKey: "AppleEnabledInputSources")

        #expect(InputSourceManager.cleanupStaleInputSources(in: defaults) == .cleaned(keys: ["AppleEnabledInputSources"]))
        #expect(InputSourceManager.cleanupStaleInputSources(in: defaults) == .noChangeNeeded)
    }
}

// MARK: - ABC Removal Tests

@Suite("Disable ABC keyboard layout")
struct DisableABCTests {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "com.pritype.tests.abc.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
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
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([abcByName, priType], forKey: "AppleEnabledInputSources")

        #expect(InputSourceManager.disableABCKeyboardLayout(in: defaults) == .removed)
        let after = defaults.array(forKey: "AppleEnabledInputSources") as? [[String: Any]] ?? []
        #expect(after.count == 1)
        #expect(!after.contains(where: InputSourceManager.isABCLayoutEntry))
    }

    @Test("An ID-only ABC entry is removed too")
    func removesIDOnlyEntry() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([abcByIDOnly, priType], forKey: "AppleEnabledInputSources")

        #expect(InputSourceManager.disableABCKeyboardLayout(in: defaults) == .removed)
        #expect((defaults.array(forKey: "AppleEnabledInputSources") as? [[String: Any]])?.count == 1)
    }

    @Test("An already-clean list is reported as alreadyAbsent, not as a write")
    func alreadyAbsentIsDistinct() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([priType], forKey: "AppleEnabledInputSources")

        #expect(InputSourceManager.disableABCKeyboardLayout(in: defaults) == .alreadyAbsent)
        #expect((defaults.array(forKey: "AppleEnabledInputSources") as? [[String: Any]])?.count == 1)
    }

    @Test("An unreadable list fails instead of silently succeeding")
    func unreadableListFails() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        // The previous implementation reported success for every outcome, which is
        // what made a failed write look like "ABC came back".
        if case .failed = InputSourceManager.disableABCKeyboardLayout(in: defaults) {
            // expected
        } else {
            Issue.record("missing AppleEnabledInputSources must be reported as a failure")
        }
    }

    @Test("Removal is idempotent")
    func removalIsIdempotent() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([abcByName, priType], forKey: "AppleEnabledInputSources")

        #expect(InputSourceManager.disableABCKeyboardLayout(in: defaults) == .removed)
        #expect(InputSourceManager.disableABCKeyboardLayout(in: defaults) == .alreadyAbsent)
    }
}
