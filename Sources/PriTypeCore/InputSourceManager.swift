import Foundation
import Carbon

// MARK: - InputSourceManager

/// Manages macOS input-source queries and stale preference cleanup.
///
/// Custom PriType language toggles must not call `TISSelectInputSource`.
/// Runtime mode switching is coordinated by `InputModeCoordinator` and
/// `PriTypeInputController`; this type stays off the typing hot path.
///
/// ## Usage
/// ```swift
/// let sources = InputSourceManager.shared.getEnabledKeyboardInputSources()
/// let isABCEnabled = InputSourceManager.shared.isABCEnabled()
/// ```
public final class InputSourceManager: @unchecked Sendable {
    
    // MARK: - Singleton
    
    /// Shared instance
    public static let shared = InputSourceManager()
    
    private init() {}
    
    // MARK: - Constants
    
    /// Keyboard Layout ID for ABC (252)
    public static let abcKeyboardLayoutID = 252

    private static let priTypeBundleID = "com.pritype.inputmethod.v2"
    private static let priTypeKoreanInputMode = "com.pritype.inputmethod.v2"
    private static let priTypeEnglishInputMode = "com.pritype.inputmethod.v2.english"
    // Both PriType modes are current. cleanupStaleInputSources must NOT strip the
    // English mode (it is a real registered mode, not a stale leftover).
    private static let currentPriTypeInputModes: Set<String> = [
        priTypeKoreanInputMode,
        priTypeEnglishInputMode
    ]
    
    // MARK: - TIS API Methods
    
    /// Get a list of all enabled keyboard input sources using TIS API
    public func getEnabledKeyboardInputSources() -> [(id: String, name: String)] {
        var result: [(id: String, name: String)] = []
        
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsEnabled as String: true
        ]
        
        guard let sourceList = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
            return result
        }
        
        for source in sourceList {
            if let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
               let namePtr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
                let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                let name = Unmanaged<CFString>.fromOpaque(namePtr).takeUnretainedValue() as String
                result.append((id: id, name: name))
            }
        }
        
        return result
    }
    
    /// Never resurrect a disabled ABC/US layout merely to override a client.
    static func enabledRomanKeyboardLayoutID(in enabledIDs: [String]) -> String? {
        ["com.apple.keylayout.ABC", "com.apple.keylayout.US"].first { enabledIDs.contains($0) }
    }

    /// Check if ABC is enabled via TIS API
    public func isABCEnabled() -> Bool {
        let sources = getEnabledKeyboardInputSources()
        return sources.contains { $0.name == "ABC" || $0.id.contains("ABC") }
    }
    
    /// Check if US is enabled via TIS API  
    public func isUSEnabled() -> Bool {
        let sources = getEnabledKeyboardInputSources()
        return sources.contains { $0.id.contains("US") || $0.name == "U.S." }
    }

    // MARK: - Disable the default English (ABC) layout

    /// Outcome of disabling the ABC keyboard layout.
    public enum ABCRemovalResult: Equatable {
        /// ABC was present and the removal was written and read back successfully.
        case removed
        /// ABC was not in the enabled list to begin with — the desired end state.
        case alreadyAbsent
        /// The write did not survive a read-back and a restore was attempted.
        /// The restore is not itself verified, so this does not promise the
        /// preferences are byte-identical to their prior state.
        case failed(reason: String)
    }

    /// The exact input-source ID of the plain ABC layout.
    ///
    /// Must be matched exactly. `id.contains("ABC")` also catches ABC-AZERTY,
    /// ABC-QWERTZ, ABC-India and even Chinese Pinyin (`…SCIM.ITABC`), none of which
    /// this action removes — using the loose form to confirm removal reports a
    /// permanent failure to anyone who keeps one of those enabled.
    static let abcInputSourceID = "com.apple.keylayout.ABC"

    /// Whether an `AppleEnabledInputSources` entry is the plain ABC keyboard layout.
    ///
    /// The layout ID is accepted only as a fallback for an entry that carries no
    /// name, and only for a keyboard-layout entry. Matching ID 252 on its own would
    /// delete any third-party `.keylayout` that happens to reuse that resource ID —
    /// an unbounded false-positive surface for a malformed-entry case that is not
    /// demonstrated. The ABC *variants* carry different names and IDs and are
    /// deliberately left alone.
    static func isABCLayoutEntry(_ source: [String: Any]) -> Bool {
        let name = source["KeyboardLayout Name"] as? String
        if name == "ABC" { return true }
        guard name == nil,
              (source["InputSourceKind"] as? String) == "Keyboard Layout",
              let layoutID = source["KeyboardLayout ID"] as? Int else { return false }
        return layoutID == abcKeyboardLayoutID
    }

    /// Disable the ABC layout in the enabled-input-source list, verifying the write.
    ///
    /// Reversible: the user can re-add ABC in System Settings (the login window
    /// still needs it). This never selects or enables anything else.
    @discardableResult
    public func disableABCKeyboardLayout() -> ABCRemovalResult {
        guard let defaults = UserDefaults(suiteName: "com.apple.HIToolbox") else {
            return .failed(reason: "HIToolbox defaults unavailable")
        }
        let result = Self.disableABCKeyboardLayout(in: defaults)
        if result == .removed {
            CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
            // Refresh the menu-bar input-source list so the change is visible now.
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            task.arguments = ["TextInputMenuAgent"]
            try? task.run()
        }
        DebugLogger.log("InputSourceManager: disable ABC → \(result)")
        return result
    }

    /// Pure defaults-level ABC removal with read-back verification.
    static func disableABCKeyboardLayout(in defaults: UserDefaults) -> ABCRemovalResult {
        let key = "AppleEnabledInputSources"
        guard let original = defaults.array(forKey: key) as? [[String: Any]] else {
            return .failed(reason: "\(key) unreadable")
        }

        let remaining = original.filter { !isABCLayoutEntry($0) }
        guard remaining.count != original.count else { return .alreadyAbsent }

        defaults.set(remaining, forKey: key)
        defaults.synchronize()

        // Verify. A write that did not land is exactly the "ABC came back" report
        // from the original issue, and must not be shown to the user as success.
        guard let after = defaults.array(forKey: key) as? [[String: Any]] else {
            defaults.set(original, forKey: key)
            defaults.synchronize()
            return .failed(reason: "\(key) unreadable after write")
        }
        guard !after.contains(where: isABCLayoutEntry) else {
            defaults.set(original, forKey: key)
            defaults.synchronize()
            return .failed(reason: "ABC still present after write")
        }
        return .removed
    }

    /// Whether the live TIS state agrees that the plain ABC layout is gone.
    ///
    /// The preference write can succeed while the running system still has ABC
    /// enabled, so the UI confirms against TIS before claiming success. This uses
    /// the exact source ID — the confirmation must recognise exactly what the
    /// removal targets, or ABC-variant and Pinyin users fail forever.
    public func isABCDisabledAccordingToTIS() -> Bool {
        !getEnabledKeyboardInputSources().contains { $0.id == Self.abcInputSourceID }
    }

    /// Keys whose sanitized copies must land together or not at all.
    static let managedInputSourceKeys = [
        "AppleEnabledInputSources",
        "AppleSelectedInputSources",
        "AppleInputSourceHistory"
    ]

    /// Outcome of an explicit input-source cleanup.
    ///
    /// Cleanup rewrites system preferences, so callers need a result rather than a
    /// silent success. Note what the read-back can and cannot establish: it detects
    /// a write rejected or reverted at the storage layer, but NOT macOS re-adding
    /// an entry afterwards — the deferred rewrite is what users perceive as an
    /// entry "coming back", and no synchronous check can see it. Confirming that
    /// requires the live TIS state (see `isABCDisabledAccordingToTIS`).
    public enum CleanupResult: Equatable {
        /// Preferences already matched the sanitized form; nothing was written.
        case noChangeNeeded
        /// Every managed key was written and read back unchanged.
        case cleaned(keys: [String])
        /// A write did not survive the read-back. A restore of the written keys was
        /// attempted but is not itself verified, so this does not promise the
        /// preferences are byte-identical to their prior state.
        case failed(reason: String)
    }

    /// Remove stale legacy entries without enabling or selecting input sources.
    ///
    /// This intentionally does not enable PriType itself. Calling
    /// `TISEnableInputSource` for the running input method can make macOS show
    /// an "add input source" confirmation again on startup.
    ///
    /// This is an explicit maintenance action, not a startup step: PriType must not
    /// rewrite HIToolbox snapshots on every launch (see ARCHITECTURE). The value of
    /// this path is the all-or-nothing planning across `managedInputSourceKeys`:
    /// every key is planned before anything is written, so a mismatch on the last
    /// key still restores the earlier ones and no partially-cleaned state is left
    /// behind. The read-back is a cheap storage-layer guard, not proof the cleanup
    /// stuck — see `CleanupResult`.
    @discardableResult
    public func cleanupStaleInputSources() -> CleanupResult {
        guard let defaults = UserDefaults(suiteName: "com.apple.HIToolbox") else {
            DebugLogger.log("InputSourceManager: failed to open HIToolbox defaults")
            return .failed(reason: "HIToolbox defaults unavailable")
        }
        let result = Self.cleanupStaleInputSources(in: defaults)
        switch result {
        case .noChangeNeeded:
            DebugLogger.log("InputSourceManager: Apple ABC and legacy input-source cleanup already current")
        case .cleaned(let keys):
            CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
            DebugLogger.log("InputSourceManager: cleaned stale PriType input-source entries (\(keys.joined(separator: ", ")))")
        case .failed(let reason):
            // Flush here too: the restore writes need it at least as much as the
            // forward writes they undo.
            CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
            DebugLogger.log("InputSourceManager: input-source cleanup failed; restore attempted — \(reason)")
        }
        return result
    }

    /// Pure defaults-level cleanup, separated so it can be exercised against a
    /// scratch domain instead of the live HIToolbox preferences.
    static func cleanupStaleInputSources(in defaults: UserDefaults) -> CleanupResult {
        // 1. Plan every write before touching anything.
        var originals: [String: [[String: Any]]] = [:]
        var planned: [String: [[String: Any]]] = [:]

        for key in managedInputSourceKeys {
            // A key that is absent is simply not managed. A key that is PRESENT but
            // of the wrong shape is a real problem and must not be reported as
            // "already current" — that is what `disableABCKeyboardLayout` does too.
            guard defaults.object(forKey: key) != nil else { continue }
            guard let original = defaults.array(forKey: key) as? [[String: Any]] else {
                return .failed(reason: "\(key) is present but not a list of entries")
            }
            let sanitized = sanitizedInputSources(
                original,
                removeAppleKoreanInputModes: false,
                allowsPriTypeParentEntry: true
            )
            originals[key] = original
            if !inputSourcesEqual(sanitized, original) {
                planned[key] = sanitized
            }
        }

        guard !planned.isEmpty else { return .noChangeNeeded }

        // 2. Apply the whole plan.
        for (key, sanitized) in planned {
            defaults.set(sanitized, forKey: key)
        }
        defaults.synchronize()

        // 3. Read back. `UserDefaults` reflects out-of-band changes from cfprefsd,
        //    so this does catch a write rejected or reverted by another process —
        //    but a key compared against the value we just derived from it agrees by
        //    construction otherwise. A mismatch fails the WHOLE operation rather
        //    than leaving some keys cleaned.
        for (key, expected) in planned {
            let actual = defaults.array(forKey: key) as? [[String: Any]]
            guard let actual, inputSourcesEqual(actual, expected) else {
                for (rollbackKey, original) in originals where planned[rollbackKey] != nil {
                    defaults.set(original, forKey: rollbackKey)
                }
                defaults.synchronize()
                return .failed(reason: "verification failed for \(key)")
            }
        }

        return .cleaned(keys: planned.keys.sorted())
    }

    private static func inputSourcesEqual(_ lhs: [[String: Any]], _ rhs: [[String: Any]]) -> Bool {
        (lhs as NSArray).isEqual(to: rhs)
    }

    internal static func sanitizedInputSources(
        _ sources: [[String: Any]],
        removeAppleKoreanInputModes: Bool,
        allowsPriTypeParentEntry: Bool
    ) -> [[String: Any]] {
        var seen = Set<String>()

        return sources.compactMap { source in
            if shouldRemoveInputSource(
                source,
                removeAppleKoreanInputModes: removeAppleKoreanInputModes,
                allowsPriTypeParentEntry: allowsPriTypeParentEntry
            ) {
                return nil
            }

            let key = inputSourceIdentity(source)
            guard seen.insert(key).inserted else {
                return nil
            }

            return source
        }
    }

    private static func shouldRemoveInputSource(
        _ source: [String: Any],
        removeAppleKoreanInputModes: Bool,
        allowsPriTypeParentEntry: Bool
    ) -> Bool {
        if (source["Bundle ID"] as? String) == priTypeBundleID {
            let inputMode = source["Input Mode"] as? String
            guard let inputMode else {
                return !allowsPriTypeParentEntry
            }
            if !currentPriTypeInputModes.contains(inputMode) {
                return true
            }
            return false
        }

        if removeAppleKoreanInputModes,
           Self.appleKoreanInputMethodBundleIDs.contains(source["Bundle ID"] as? String ?? ""),
           source["InputSourceKind"] as? String == "Input Mode" {
            return true
        }

        return false
    }

    private static let appleKoreanInputMethodBundleIDs: Set<String> = [
        "com.apple.inputmethod.Korean",
        "com.apple.inputmethod.ironwood"
    ]

    private static func inputSourceIdentity(_ source: [String: Any]) -> String {
        [
            source["InputSourceKind"] as? String ?? "",
            source["Bundle ID"] as? String ?? "",
            source["Input Mode"] as? String ?? "",
            "\(source["KeyboardLayout ID"] as? Int ?? Int.min)",
            source["KeyboardLayout Name"] as? String ?? ""
        ].joined(separator: "\u{1F}")
    }
}
