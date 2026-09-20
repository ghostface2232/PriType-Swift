import Foundation
import Carbon

// MARK: - InputSourceManager

/// Manages macOS input-source queries, PriType mode selection and ABC removal.
///
/// Custom PriType language toggles must not call `TISSelectInputSource`.
/// Runtime mode switching is coordinated by `InputModeCoordinator` and
/// `PriTypeInputController`; this type stays off the typing hot path.
public final class InputSourceManager: @unchecked Sendable {
    
    // MARK: - Singleton
    
    /// Shared instance
    public static let shared = InputSourceManager()
    
    private init() {}
    
    // MARK: - Constants
    
    /// Keyboard Layout ID for ABC (252)
    static let abcKeyboardLayoutID = 252

    private static let priTypeBundleID = "com.pritype.inputmethod.v2"
    
    // MARK: - Mode Selection

    /// Tell macOS which PriType mode is now active, so the menu-bar input source
    /// matches `HangulComposer.inputMode`.
    ///
    /// ARCHITECTURE.md ("한/영 전환") forbids driving a custom toggle *with*
    /// `TISSelectInputSource`, and that invariant stands: in 2.7.x the selection
    /// WAS the switch, and its asynchrony is what ate the first character after a
    /// toggle. This is the opposite order. The composer has already switched
    /// synchronously and remains the single source of truth; this call only
    /// reports the outcome. A slow, failed, or unsupported call therefore cannot
    /// affect typing — only the menu-bar icon lags.
    ///
    /// The two modes register as input modes under the bundle id, so the English
    /// one is the source whose id carries the `.english` suffix. Resolved live
    /// rather than cached: the user can enable or disable a mode at any time.
    ///
    /// - Important: Call off the toggle hot path.
    /// - Parameter beforeSelecting: runs only when a selection is actually issued,
    ///   right before it, so the caller can expect the `setValue` echo it causes.
    /// - Returns: whether the requested mode is now the selected input source.
    @discardableResult
    public func selectPriTypeMode(english: Bool, beforeSelecting: () -> Void = {}) -> Bool {
        guard let source = priTypeModeSource(english: english) else {
            DebugLogger.log("InputSourceManager: no enabled PriType \(english ? "english" : "korean") mode to select")
            return false
        }
        if boolProperty(source, kTISPropertyInputSourceIsSelected) {
            return true
        }
        beforeSelecting()
        let status = TISSelectInputSource(source)
        guard status == noErr else {
            DebugLogger.log("InputSourceManager: TISSelectInputSource failed (\(status))")
            return false
        }
        DebugLogger.log("InputSourceManager: selected PriType \(english ? "english" : "korean") mode")
        return true
    }

    private func priTypeModeSource(english: Bool) -> TISInputSource? {
        enabledKeyboardSources()?.first { source in
            guard let id = stringProperty(source, kTISPropertyInputSourceID),
                  id.hasPrefix(Self.priTypeBundleID),
                  stringProperty(source, kTISPropertyInputSourceType) == kTISTypeKeyboardInputMode as String,
                  boolProperty(source, kTISPropertyInputSourceIsSelectCapable)
            else { return false }
            return id.hasSuffix(".english") == english
        }
    }

    private func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }

    // MARK: - TIS API Methods

    /// The enabled keyboard input sources (layouts and input modes), or nil when
    /// TIS cannot list them.
    private func enabledKeyboardSources() -> [TISInputSource]? {
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsEnabled as String: true
        ]
        return TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource]
    }

    /// IDs of the enabled keyboard input sources. Nil when TIS cannot list them
    /// or leaves one without an ID: such a list cannot prove anything absent.
    public func enabledKeyboardInputSourceIDs() -> [String]? {
        guard let sources = enabledKeyboardSources() else { return nil }
        var ids: [String] = []
        for source in sources {
            guard let id = stringProperty(source, kTISPropertyInputSourceID) else { return nil }
            ids.append(id)
        }
        return ids
    }

    /// Never resurrect a disabled ABC/US layout merely to override a client.
    static func enabledRomanKeyboardLayoutID(in enabledIDs: [String]) -> String? {
        ["com.apple.keylayout.ABC", "com.apple.keylayout.US"].first { enabledIDs.contains($0) }
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
        if result == .removed || result == .alreadyAbsent {
            CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
            // A retry can find clean preferences while TIS still has ABC enabled.
            // Refresh on both outcomes; neither is proof of live removal.
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
    ///
    /// - Important: This reports the calling process's *cached* TIS view, which
    ///   HIToolbox does not refresh after a preference write. Inside the running
    ///   input method it keeps answering "enabled" after a successful removal.
    ///   Confirm from a fresh process instead: `ABCLayoutStatusProbe`.
    public func isABCDisabledAccordingToTIS() -> Bool {
        Self.isABCDisabled(in: enabledKeyboardInputSourceIDs())
    }

    static func isABCDisabled(in enabledIDs: [String]?) -> Bool {
        guard let enabledIDs else { return false }
        return !enabledIDs.contains(abcInputSourceID)
    }
}
