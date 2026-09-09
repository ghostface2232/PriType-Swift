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

    /// Keys whose sanitized copies must land together or not at all.
    static let managedInputSourceKeys = [
        "AppleEnabledInputSources",
        "AppleSelectedInputSources",
        "AppleInputSourceHistory"
    ]

    /// Outcome of an explicit input-source cleanup.
    ///
    /// Cleanup rewrites system preferences, so callers need to know whether the
    /// write actually landed — HIToolbox defaults can silently reject or drop a
    /// write, which is how a "removed" entry appears to come back.
    public enum CleanupResult: Equatable {
        /// Preferences already matched the sanitized form; nothing was written.
        case noChangeNeeded
        /// Every managed key was written and verified by re-reading it.
        case cleaned(keys: [String])
        /// Nothing was left changed: either no write was attempted, or the
        /// verification failed and the originals were restored.
        case failed(reason: String)
    }

    /// Remove stale legacy entries without enabling or selecting input sources.
    ///
    /// This intentionally does not enable PriType itself. Calling
    /// `TISEnableInputSource` for the running input method can make macOS show
    /// an "add input source" confirmation again on startup.
    ///
    /// This is an explicit maintenance action, not a startup step: PriType must not
    /// rewrite HIToolbox snapshots on every launch (see ARCHITECTURE). The write is
    /// all-or-nothing across `managedInputSourceKeys` and is verified by re-reading
    /// each key; on any mismatch the originals are restored so a partial rewrite can
    /// never be left behind.
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
            DebugLogger.log("InputSourceManager: input-source cleanup failed and was rolled back — \(reason)")
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
            guard let original = defaults.array(forKey: key) as? [[String: Any]] else { continue }
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

        // 2. Apply the whole plan, then force it out before reading back.
        for (key, sanitized) in planned {
            defaults.set(sanitized, forKey: key)
        }
        defaults.synchronize()

        // 3. Verify by re-reading. A key that did not take the write is a failure
        //    for the whole operation, not a partial success.
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
