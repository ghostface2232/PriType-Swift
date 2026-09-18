import Foundation
import CoreGraphics

// MARK: - Types

/// Toggle key options for language switching (legacy enum, kept for migration)
///
/// Defines the available modifier key combinations that can be used
/// to switch between Korean and English input modes.
public enum ToggleKey: String, CaseIterable, Sendable {
    /// Control + Space key combination
    case controlSpace = "controlSpace"
    /// Right Command key (single key toggle)
    case rightCommand = "rightCommand"
    
    /// Human-readable display name for the toggle key
    public var displayName: String {
        switch self {
        case .controlSpace: return "Control + Space"
        case .rightCommand: return "우측 Command"
        }
    }
    
    /// Convert legacy ToggleKey to KeyBinding
    public var asKeyBinding: KeyBinding {
        switch self {
        case .rightCommand:
            return .defaultToggle
        case .controlSpace:
            return KeyBinding(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue, displayName: "Control + Space")
        }
    }
}

// MARK: - KeyBinding

/// Represents a user-configured key binding (raw keyCode + modifiers)
///
/// Unlike the legacy `ToggleKey` enum which only supports preset options,
/// `KeyBinding` stores the actual raw key code and modifier flags,
/// allowing users to bind any key combination.
///
/// ## Usage
/// ```swift
/// let binding = KeyBinding(keyCode: 54, modifiers: 0, displayName: "우측 Command")
/// if event.keyCode == binding.keyCode { ... }
/// ```
public struct KeyBinding: Codable, Equatable, Sendable {
    /// macOS virtual key code (e.g., 54 = Right Command, 61 = Right Option)
    public let keyCode: Int64
    
    /// CGEventFlags raw value. 0 means single modifier key (no additional modifiers).
    public let modifiers: UInt64
    
    /// Human-readable display name (e.g., "우측 Command", "Control + Space")
    public let displayName: String
    
    /// Whether this is a modifier-only binding (no additional modifiers required)
    public var isModifierOnly: Bool {
        modifiers == 0
    }
    
    /// Whether the bound key is a modifier key (Command, Option, Control, Shift, CapsLock)
    /// Modifier keys generate `flagsChanged` events; regular keys generate `keyDown` events.
    public var isModifierKey: Bool {
        switch keyCode {
        case 54, 55: return true  // Right/Left Command
        case 61, 58: return true  // Right/Left Option
        case 62, 59: return true  // Right/Left Control
        case 56, 60: return true  // Left/Right Shift
        case 57:     return true  // Caps Lock
        case 63:     return true  // Fn
        default:     return false
        }
    }
    
    /// Reject bindings that swallow ordinary typing globally, including Shift+letter.
    public var isSafeGlobalBinding: Bool {
        if keyCode == 57 || keyCode == 63 { return false }
        if isModifierKey { return modifiers == 0 }
        let shortcuts = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        if modifiers & shortcuts != 0 { return true }
        return [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90].contains(keyCode)
    }

    /// A well-known macOS shortcut this binding would shadow, if any.
    ///
    /// These bindings are still allowed — a user may genuinely prefer PriType to
    /// win, and macOS lets the shortcut be reassigned — but taking one silently
    /// looks like the system shortcut broke. The settings UI warns instead.
    /// Only exact matches are reported, so an unrelated combo never nags.
    public var systemShortcutConflict: SystemShortcut? {
        SystemShortcut.all.first { $0.matches(self) }
    }

    /// A macOS shortcut PriType can shadow when bound to the same keys.
    public struct SystemShortcut: Equatable, Sendable {
        public let keyCode: Int64
        public let modifiers: UInt64
        /// Localization key for the shortcut's name.
        public let nameKey: String

        /// Exact match. This is only safe because recorded bindings are normalized
        /// to the four bare modifier masks at record time
        /// (`SettingsWindowController.receiveBinding`, which strips the
        /// device-specific left/right bits, `maskNonCoalesced`, Caps Lock, numeric
        /// pad and Fn). Widening that mask would silently kill this feature with no
        /// test failure — `normalizedRecordedModifiersStillConflict` pins it.
        func matches(_ binding: KeyBinding) -> Bool {
            binding.keyCode == keyCode && binding.modifiers == modifiers
        }

        static let all: [SystemShortcut] = [
            // Space combos own input-source switching and Spotlight on a default
            // macOS install — the exact area a user is configuring here.
            SystemShortcut(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue,
                           nameKey: "shortcut.previousInputSource"),
            SystemShortcut(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue,
                           nameKey: "shortcut.nextInputSource"),
            SystemShortcut(keyCode: 49, modifiers: CGEventFlags.maskCommand.rawValue,
                           nameKey: "shortcut.spotlight"),
            SystemShortcut(keyCode: 49, modifiers: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue,
                           nameKey: "shortcut.finderSearch"),
            SystemShortcut(keyCode: 49, modifiers: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue,
                           nameKey: "shortcut.emojiPicker"),
            // Screenshot family.
            SystemShortcut(keyCode: 20, modifiers: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue,
                           nameKey: "shortcut.screenshot"),
            SystemShortcut(keyCode: 21, modifiers: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue,
                           nameKey: "shortcut.screenshotRegion"),
            SystemShortcut(keyCode: 23, modifiers: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue,
                           nameKey: "shortcut.screenshotUI")
        ]
    }

    /// Default toggle key: Right Command
    public static let defaultToggle = KeyBinding(keyCode: 54, modifiers: 0, displayName: "우측 Command")
    
    /// Default hanja key: Right Option
    public static let defaultHanja = KeyBinding(keyCode: 61, modifiers: 0, displayName: "우측 Option")
    
    /// Generate a display name from raw keyCode and modifiers
    public static func generateDisplayName(keyCode: Int64, modifiers: UInt64) -> String {
        var parts: [String] = []
        let flags = CGEventFlags(rawValue: modifiers)
        
        if flags.contains(.maskControl) { parts.append("Control") }
        if flags.contains(.maskAlternate) { parts.append("Option") }
        if flags.contains(.maskShift) { parts.append("Shift") }
        if flags.contains(.maskCommand) { parts.append("Command") }
        
        // Key name from keyCode — comprehensive macOS virtual key code mapping
        let keyName: String
        switch keyCode {
        // Modifier keys
        case 54: keyName = "우측 Command"
        case 55: keyName = "좌측 Command"
        case 61: keyName = "우측 Option"
        case 58: keyName = "좌측 Option"
        case 62: keyName = "우측 Control"
        case 59: keyName = "좌측 Control"
        case 56: keyName = "좌측 Shift"
        case 60: keyName = "우측 Shift"
        case 57: keyName = "Caps Lock"
        case 63: keyName = "Fn"
        // Special keys
        case 49: keyName = "Space"
        case 36: keyName = "Return"
        case 48: keyName = "Tab"
        case 53: keyName = "Escape"
        case 51: keyName = "Delete"
        case 117: keyName = "Forward Delete"
        // Arrow keys
        case 123: keyName = "←"
        case 124: keyName = "→"
        case 125: keyName = "↓"
        case 126: keyName = "↑"
        // Navigation
        case 115: keyName = "Home"
        case 119: keyName = "End"
        case 116: keyName = "Page Up"
        case 121: keyName = "Page Down"
        // F-keys
        case 122: keyName = "F1"
        case 120: keyName = "F2"
        case 99:  keyName = "F3"
        case 118: keyName = "F4"
        case 96:  keyName = "F5"
        case 97:  keyName = "F6"
        case 98:  keyName = "F7"
        case 100: keyName = "F8"
        case 101: keyName = "F9"
        case 109: keyName = "F10"
        case 103: keyName = "F11"
        case 111: keyName = "F12"
        case 105: keyName = "F13"
        case 107: keyName = "F14"
        case 113: keyName = "F15"
        // Letter keys (QWERTY layout)
        case 0:  keyName = "A"
        case 11: keyName = "B"
        case 8:  keyName = "C"
        case 2:  keyName = "D"
        case 14: keyName = "E"
        case 3:  keyName = "F"
        case 5:  keyName = "G"
        case 4:  keyName = "H"
        case 34: keyName = "I"
        case 38: keyName = "J"
        case 40: keyName = "K"
        case 37: keyName = "L"
        case 46: keyName = "M"
        case 45: keyName = "N"
        case 31: keyName = "O"
        case 35: keyName = "P"
        case 12: keyName = "Q"
        case 15: keyName = "R"
        case 1:  keyName = "S"
        case 17: keyName = "T"
        case 32: keyName = "U"
        case 9:  keyName = "V"
        case 13: keyName = "W"
        case 7:  keyName = "X"
        case 16: keyName = "Y"
        case 6:  keyName = "Z"
        // Number keys
        case 29: keyName = "0"
        case 18: keyName = "1"
        case 19: keyName = "2"
        case 20: keyName = "3"
        case 21: keyName = "4"
        case 23: keyName = "5"
        case 22: keyName = "6"
        case 26: keyName = "7"
        case 28: keyName = "8"
        case 25: keyName = "9"
        // Punctuation
        case 27: keyName = "-"
        case 24: keyName = "="
        case 33: keyName = "["
        case 30: keyName = "]"
        case 42: keyName = "\\"
        case 41: keyName = ";"
        case 39: keyName = "'"
        case 43: keyName = ","
        case 47: keyName = "."
        case 44: keyName = "/"
        case 50: keyName = "`"
        default:
            keyName = "Key(\(keyCode))"
        }
        
        // For modifier-only bindings, don't duplicate modifier name
        if modifiers == 0 {
            return keyName
        }
        
        parts.append(keyName)
        return parts.joined(separator: " + ")
    }
}

// MARK: - Notification Names

/// Notification names used by PriType
public extension Notification.Name {
    /// Posted when a key binding changes
    static let keyBindingChanged = Notification.Name("PriTypeKeyBindingChanged")
}

// MARK: - ConfigurationProviding Protocol

/// Protocol for accessing configuration settings
///
/// This protocol enables dependency injection for configuration access,
/// improving testability by allowing mock implementations in tests.
///
/// ## Usage
/// ```swift
/// class MyClass {
///     private let config: ConfigurationProviding
///     
///     init(config: ConfigurationProviding = ConfigurationManager.shared) {
///         self.config = config
///     }
/// }
/// ```
public protocol ConfigurationProviding: AnyObject, Sendable {
    /// The selected toggle key for switching between Korean and English
    var toggleKey: ToggleKey { get set }
    
    /// Whether Right Command key is configured as the toggle key
    var rightCommandAsToggle: Bool { get }
    
    /// Whether Control+Space is configured as the toggle key
    var controlSpaceAsToggle: Bool { get }

    /// Whether macOS owns Caps Lock input-source switching.
    var capsLockInputSourceSwitchEnabled: Bool { get }
    
    /// Whether the system double-space period feature is enabled.
    var doubleSpacePeriodEnabled: Bool { get }

    /// Whether the system auto-capitalization feature is enabled.
    ///
    /// PriType does not reimplement this in Korean composition; English mode is
    /// pure pass-through so macOS owns the feature just like the ABC input source.
    var autoCapitalizationEnabled: Bool { get }

    /// Whether the system smart quote substitution feature is enabled.
    var smartQuoteSubstitutionEnabled: Bool { get }

    /// Whether the system smart dash substitution feature is enabled.
    var smartDashSubstitutionEnabled: Bool { get }

    /// Experimental: deliver the in-progress syllable as REAL text (Windows-style
    /// direct insertion) instead of marked text, on probe-verified allowlisted hosts.
    /// Default OFF. See Docs/KoreanWindowsInputFeasibility.md (Phase 3).
    var experimentalDirectInsertion: Bool { get }

    /// Bundle IDs of apps where PriType must not consume the toggle/hanja keys.
    var toggleExcludedBundleIDs: [String] { get }
}

public extension ConfigurationProviding {
    /// Default: experimental direct insertion disabled. Conformers (e.g. test mocks)
    /// inherit this unless they override it; only `ConfigurationManager` reads the flag.
    var experimentalDirectInsertion: Bool { false }
    var toggleExcludedBundleIDs: [String] { [] }

    /// Default: enabled, matching macOS's normal text-input default.
    var autoCapitalizationEnabled: Bool { true }
    var smartQuoteSubstitutionEnabled: Bool { true }
    var smartDashSubstitutionEnabled: Bool { true }
}

// MARK: - ConfigurationManager

/// Manages persistent user configuration using UserDefaults
///
/// `ConfigurationManager` provides a centralized interface for accessing and
/// modifying user preferences. All settings are automatically persisted using
/// `UserDefaults` with the `com.pritype` prefix.
///
/// ## Usage
/// ```swift
/// // Read the current toggle key binding
/// let binding = ConfigurationManager.shared.toggleKeyBinding
/// ```
///
/// ## Notifications
/// When a key binding changes, a `PriTypeKeyBindingChanged` notification is posted.
///
/// ## Thread Safety
/// This class uses `UserDefaults` which is thread-safe for reading/writing.
/// The class is marked `@unchecked Sendable` as UserDefaults provides the synchronization.
public final class ConfigurationManager: ConfigurationProviding, @unchecked Sendable {
    
    // MARK: - Singleton
    
    /// Shared instance for global access
    public static let shared = ConfigurationManager()
    
    // MARK: - Private Properties
    
    private let defaults = UserDefaults.standard
    private let systemTextFeatureLock = NSLock()
    private var lastSystemTextRefresh: TimeInterval = 0
    private var cachedDoubleSpacePeriodEnabled: Bool = ConfigurationManager.readSystemTextFeature(
        key: SystemTextInputKeys.automaticPeriodSubstitution,
        defaultValue: true
    )
    private var cachedAutoCapitalizationEnabled: Bool = ConfigurationManager.readSystemTextFeature(
        key: SystemTextInputKeys.automaticCapitalization,
        defaultValue: true
    )
    private var cachedSmartQuoteSubstitutionEnabled: Bool = ConfigurationManager.readSystemTextFeature(
        key: SystemTextInputKeys.automaticQuoteSubstitution,
        defaultValue: true
    )
    private var cachedSmartDashSubstitutionEnabled: Bool = ConfigurationManager.readSystemTextFeature(
        key: SystemTextInputKeys.automaticDashSubstitution,
        defaultValue: true
    )
    
    private init() {
        defaults.removeObject(forKey: "com.pritype.autoCapitalize")
        defaults.removeObject(forKey: "com.pritype.doubleSpacePeriod")
    }
    
    // MARK: - Keys
    
    private enum Keys {
        static let toggleKey = "com.pritype.toggleKey"  // Legacy
        static let toggleKeyBinding = "com.pritype.toggleKeyBinding"
        static let hanjaKeyBinding = "com.pritype.hanjaKeyBinding"
        static let lastUpdateCheck = "com.pritype.lastUpdateCheck"
        static let autoUpdateCheck = "com.pritype.autoUpdateCheck"
        static let experimentalDirectInsertion = "com.pritype.experimentalDirectInsertion"
        static let toggleExcludedBundleIDs = "com.pritype.toggleExcludedBundleIDs"
    }

    private enum SystemTextInputKeys {
        static let automaticCapitalization = "NSAutomaticCapitalizationEnabled"
        static let automaticDashSubstitution = "NSAutomaticDashSubstitutionEnabled"
        static let automaticPeriodSubstitution = "NSAutomaticPeriodSubstitutionEnabled"
        static let automaticQuoteSubstitution = "NSAutomaticQuoteSubstitutionEnabled"
    }

    // MARK: - Toggle Key (Legacy)
    
    /// The selected toggle key for switching between Korean and English
    ///
    /// Defaults to `.rightCommand` if no preference is set.
    /// - Note: Legacy property kept for backward compatibility. Prefer `toggleKeyBinding`.
    public var toggleKey: ToggleKey {
        get {
            if let rawValue = defaults.string(forKey: Keys.toggleKey),
               let key = ToggleKey(rawValue: rawValue) {
                return key
            }
            return .rightCommand  // Default
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.toggleKey)
        }
    }
    
    // MARK: - Key Binding Cache
    // CGEventTap callbacks read these on EVERY key event (100+ times/sec during typing).
    // JSON decoding on every access is wasteful; cache in memory and invalidate on write.
    // Lock protects in-memory cache from races between CGEventTap thread and settings UI.
    
    private var _cachedToggleBinding: KeyBinding?
    private var _cachedHanjaBinding: KeyBinding?
    private let keyBindingLock = NSLock()
    
    /// The user-configured toggle key binding
    ///
    /// Supports any key or key combination registered via the Key Recorder UI.
    /// On first access, migrates from legacy `toggleKey` if present.
    /// Result is cached in memory to avoid JSON decoding on every CGEventTap callback.
    public var toggleKeyBinding: KeyBinding {
        get {
            keyBindingLock.lock()
            defer { keyBindingLock.unlock() }
            if let cached = _cachedToggleBinding {
                return cached
            }
            let binding: KeyBinding
            if let data = defaults.data(forKey: Keys.toggleKeyBinding),
               let decoded = try? JSONDecoder().decode(KeyBinding.self, from: data) {
                // Fn and Caps Lock are not supported as PriType custom toggle keys.
                binding = decoded.isSafeGlobalBinding ? decoded : .defaultToggle
            } else {
                // Migrate from legacy toggleKey
                binding = toggleKey.asKeyBinding
            }
            _cachedToggleBinding = binding
            return binding
        }
        set {
            guard newValue.isSafeGlobalBinding else { return }
            keyBindingLock.lock()
            _cachedToggleBinding = newValue
            keyBindingLock.unlock()
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.toggleKeyBinding)
            }
            NotificationCenter.default.post(name: .keyBindingChanged, object: nil)
        }
    }
    
    /// The user-configured hanja input key binding
    ///
    /// Defaults to Right Option if no preference is set.
    /// Result is cached in memory to avoid JSON decoding on every CGEventTap callback.
    public var hanjaKeyBinding: KeyBinding {
        get {
            keyBindingLock.lock()
            defer { keyBindingLock.unlock() }
            if let cached = _cachedHanjaBinding {
                return cached
            }
            let binding: KeyBinding
            if let data = defaults.data(forKey: Keys.hanjaKeyBinding),
               let decoded = try? JSONDecoder().decode(KeyBinding.self, from: data) {
                // Sanitize: Fn key (63) is not supported in CGEventTap
                binding = decoded.isSafeGlobalBinding ? decoded : .defaultHanja
            } else {
                binding = .defaultHanja
            }
            _cachedHanjaBinding = binding
            return binding
        }
        set {
            guard newValue.isSafeGlobalBinding else { return }
            keyBindingLock.lock()
            _cachedHanjaBinding = newValue
            keyBindingLock.unlock()
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.hanjaKeyBinding)
            }
            NotificationCenter.default.post(name: .keyBindingChanged, object: nil)
        }
    }
    
    // MARK: - Toggle Exclusions

    /// Bundle IDs of apps that must receive the toggle/hanja key themselves.
    ///
    /// Remote-desktop clients and VMs run their own IME; swallowing the key leaves
    /// the guest session unable to switch languages. Read through
    /// `ToggleExclusionPolicy`, never from an event-tap callback directly.
    public var toggleExcludedBundleIDs: [String] {
        get {
            (defaults.array(forKey: Keys.toggleExcludedBundleIDs) as? [String]) ?? []
        }
        set {
            var deduped: [String] = []
            for bundleID in newValue {
                deduped = ToggleExclusionPolicy.adding(bundleID, to: deduped)
            }
            defaults.set(deduped, forKey: Keys.toggleExcludedBundleIDs)
            // The policy snapshot is the only consumer; the settings view reloads
            // its own rows imperatively after each mutation.
            ToggleExclusionPolicy.shared.refreshExcludedBundleIDs(from: self)
        }
    }

    // MARK: - Key Binding Migration

    /// Persist the legacy `toggleKey` enum as a `KeyBinding`, and repair stored
    /// bindings that are unreadable or no longer safe as global bindings.
    ///
    /// The getters above fall back in memory, but never wrote the result back, so a
    /// legacy install re-derived its binding on every launch and an unsafe stored
    /// value (e.g. a bare letter key from an older build) stayed on disk forever —
    /// it would come back the moment the sanitizing fallback changed. Run this once
    /// at startup so what is stored is what is used.
    /// - Returns: `true` if anything on disk was rewritten.
    @discardableResult
    public func migrateKeyBindingsIfNeeded() -> Bool {
        let changed = Self.migrateKeyBindings(in: defaults)
        if changed {
            keyBindingLock.lock()
            _cachedToggleBinding = nil
            _cachedHanjaBinding = nil
            keyBindingLock.unlock()
            NotificationCenter.default.post(name: .keyBindingChanged, object: nil)
        }
        return changed
    }

    /// Pure migration step, separated from the singleton so it can be exercised
    /// against a scratch `UserDefaults` domain.
    static func migrateKeyBindings(in defaults: UserDefaults) -> Bool {
        var changed = false

        // Toggle. The three cases must resolve exactly as the getter does, or the
        // migration would persist something the running app was not using.
        let storedToggle = defaults.data(forKey: Keys.toggleKeyBinding)
            .flatMap { try? JSONDecoder().decode(KeyBinding.self, from: $0) }
        if let storedToggle {
            // Decodable but unusable ⇒ repair to the default.
            if !storedToggle.isSafeGlobalBinding {
                changed = store(.defaultToggle, forKey: Keys.toggleKeyBinding, in: defaults) || changed
            }
        } else if let rawValue = defaults.string(forKey: Keys.toggleKey) {
            // Absent OR undecodable, with a legacy value present. The getter falls
            // back to the legacy enum in BOTH cases, so the migration must too —
            // splitting on `data != nil` would overwrite a user's Control+Space
            // with the default and then delete the legacy key that proved it.
            let legacy = ToggleKey(rawValue: rawValue)?.asKeyBinding ?? .defaultToggle
            changed = store(legacy.isSafeGlobalBinding ? legacy : .defaultToggle,
                            forKey: Keys.toggleKeyBinding, in: defaults) || changed
        } else if defaults.data(forKey: Keys.toggleKeyBinding) != nil {
            // Undecodable with no legacy source to recover from.
            changed = store(.defaultToggle, forKey: Keys.toggleKeyBinding, in: defaults) || changed
        }

        // Drop the legacy key only once a DECODABLE binding stands in for it.
        // Removing it next to an unreadable blob would destroy the preference.
        let toggleNowReadable = defaults.data(forKey: Keys.toggleKeyBinding)
            .flatMap { try? JSONDecoder().decode(KeyBinding.self, from: $0) } != nil
        if toggleNowReadable, defaults.object(forKey: Keys.toggleKey) != nil {
            defaults.removeObject(forKey: Keys.toggleKey)
            changed = true
        }

        // Hanja has no legacy source; only repair an unusable stored value.
        if let data = defaults.data(forKey: Keys.hanjaKeyBinding) {
            let decoded = try? JSONDecoder().decode(KeyBinding.self, from: data)
            if decoded?.isSafeGlobalBinding != true {
                changed = store(.defaultHanja, forKey: Keys.hanjaKeyBinding, in: defaults) || changed
            }
        }

        return changed
    }

    /// - Returns: `true` only if the value actually reached `defaults`. Reporting a
    ///   change that did not happen would let the caller drop the legacy key on the
    ///   strength of a binding that was never written.
    @discardableResult
    private static func store(_ binding: KeyBinding, forKey key: String, in defaults: UserDefaults) -> Bool {
        guard let data = try? JSONEncoder().encode(binding) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    // MARK: - Convenience Properties
    
    /// Whether Right Command key is configured as the toggle key
    ///
    /// Use this to conditionally enable Right Command monitoring.
    public var rightCommandAsToggle: Bool {
        return toggleKeyBinding.keyCode == 54 && toggleKeyBinding.isModifierOnly
    }
    
    /// Whether Control+Space is configured as the toggle key
    ///
    /// Use this to conditionally handle Control+Space in the composer.
    public var controlSpaceAsToggle: Bool {
        return toggleKeyBinding.keyCode == 49 && toggleKeyBinding.modifiers == CGEventFlags.maskControl.rawValue
    }

    /// Mirrors macOS "Use the Caps Lock key to switch to and from ABC".
    ///
    /// When this is enabled, PriType should not also run its own language
    /// toggle key. The system input-source switch becomes the single owner.
    public var capsLockInputSourceSwitchEnabled: Bool {
        if let value = CFPreferencesCopyValue(
            "TISRomanSwitchState" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) {
            if let number = value as? NSNumber {
                return number.intValue != 0
            }
            if let bool = value as? Bool {
                return bool
            }
        }

        return UserDefaults.standard.object(forKey: "TISRomanSwitchState") != nil
            && UserDefaults.standard.integer(forKey: "TISRomanSwitchState") != 0
    }
    
    // MARK: - Text Input Features
    
    private func refreshSystemTextFeaturesIfNeeded() {
        systemTextFeatureLock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastSystemTextRefresh >= 2 else { return }
            lastSystemTextRefresh = now
            cachedDoubleSpacePeriodEnabled = Self.readSystemTextFeature(key: SystemTextInputKeys.automaticPeriodSubstitution, defaultValue: true)
            cachedAutoCapitalizationEnabled = Self.readSystemTextFeature(key: SystemTextInputKeys.automaticCapitalization, defaultValue: true)
            cachedSmartQuoteSubstitutionEnabled = Self.readSystemTextFeature(key: SystemTextInputKeys.automaticQuoteSubstitution, defaultValue: true)
            cachedSmartDashSubstitutionEnabled = Self.readSystemTextFeature(key: SystemTextInputKeys.automaticDashSubstitution, defaultValue: true)
        }
    }

    /// Mirrors macOS "Add period with double-space" for PriType Korean input.
    public var doubleSpacePeriodEnabled: Bool {
        refreshSystemTextFeaturesIfNeeded()
        return systemTextFeatureLock.withLock { cachedDoubleSpacePeriodEnabled }
    }

    /// Mirrors macOS "Capitalize words automatically".
    ///
    /// PriType reads and caches this setting for observability, but does not
    /// apply it in Korean composition. English mode passes through to macOS, so
    /// the system handles capitalization without PriType tracking text context.
    public var autoCapitalizationEnabled: Bool {
        refreshSystemTextFeaturesIfNeeded()
        return systemTextFeatureLock.withLock { cachedAutoCapitalizationEnabled }
    }

    /// Mirrors macOS "Use smart quotes".
    public var smartQuoteSubstitutionEnabled: Bool {
        refreshSystemTextFeaturesIfNeeded()
        return systemTextFeatureLock.withLock { cachedSmartQuoteSubstitutionEnabled }
    }

    /// Mirrors macOS "Use smart dashes".
    public var smartDashSubstitutionEnabled: Bool {
        refreshSystemTextFeaturesIfNeeded()
        return systemTextFeatureLock.withLock { cachedSmartDashSubstitutionEnabled }
    }

    private static func readSystemTextFeature(key: String, defaultValue: Bool) -> Bool {
        return UserDefaults.standard.object(forKey: key) == nil
            ? defaultValue
            : UserDefaults.standard.bool(forKey: key)
    }

    /// Experimental Windows-style direct insertion (Phase 3). Default OFF.
    /// When ON, the in-progress syllable is delivered as REAL text on allowlisted,
    /// probe-verified native AppKit hosts instead of marked text. This is a research
    /// vehicle — see Docs/KoreanWindowsInputFeasibility.md. Enable via Settings or:
    ///   defaults write com.pritype.inputmethod.v2 com.pritype.experimentalDirectInsertion -bool YES
    public var experimentalDirectInsertion: Bool {
        get { defaults.bool(forKey: Keys.experimentalDirectInsertion) }
        set { defaults.set(newValue, forKey: Keys.experimentalDirectInsertion) }
    }

    // MARK: - Update Settings
    
    /// Timestamp of the last successful update check
    /// Used by `UpdateChecker` to throttle API calls (24-hour interval)
    public var lastUpdateCheck: Date? {
        get {
            defaults.object(forKey: Keys.lastUpdateCheck) as? Date
        }
        set {
            defaults.set(newValue, forKey: Keys.lastUpdateCheck)
        }
    }
    
    /// Whether automatic update checking is enabled
    /// Default: enabled
    public var autoUpdateCheckEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.autoUpdateCheck) == nil {
                return true  // Default enabled
            }
            return defaults.bool(forKey: Keys.autoUpdateCheck)
        }
        set {
            defaults.set(newValue, forKey: Keys.autoUpdateCheck)
        }
    }
}
