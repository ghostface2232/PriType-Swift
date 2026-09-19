import Foundation

/// Localization strings accessor for PriType
///
/// Provides type-safe access to localized strings from Localizable.strings.
///
/// ## Usage
/// ```swift
/// Text(L10n.keyBinding.toggleKey)
/// NSMenuItem(title: L10n.menu.settings, action: nil, keyEquivalent: "")
/// ```
public enum L10n {
    
    /// Returns the bundle containing localized resources
    /// Uses robust fallback logic for both development and distribution environments
    private static let bundle: Bundle = {
        // 1. Try to find the SPM resource bundle in app's Resources directory (distribution)
        if let resourceURL = Bundle.main.resourceURL,
           let resourceBundle = Bundle(url: resourceURL.appendingPathComponent("PriType_PriTypeCore.bundle")) {
            return resourceBundle
        }
        
        // 2. Try Bundle.module for SPM development environment
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        // 3. Fallback to main bundle (localization files directly in Resources)
        return Bundle.main
        #endif
    }()
    
    /// Helper to get localized string
    private static func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: bundle, comment: "")
    }

    // MARK: - Key Binding
    
    public enum keyBinding {
        public static var toggleKey: String { localized("keyBinding.toggleKey") }
        public static var hanjaKey: String { localized("keyBinding.hanjaKey") }
        public static var toggleTrigger: String { localized("keyBinding.toggleTrigger") }
        public static var toggleTriggerPress: String { localized("keyBinding.toggleTriggerPress") }
        public static var toggleTriggerTap: String { localized("keyBinding.toggleTriggerTap") }
        public static var toggleTriggerPressDescription: String { localized("keyBinding.toggleTriggerPressDescription") }
        public static var toggleTriggerTapDescription: String { localized("keyBinding.toggleTriggerTapDescription") }
        public static var toggleTriggerOnlyModifiers: String { localized("keyBinding.toggleTriggerOnlyModifiers") }
        public static var hanjaEnabled: String { localized("keyBinding.hanjaEnabled") }
        public static var hanjaEnabledDescription: String { localized("keyBinding.hanjaEnabledDescription") }
        public static var disabledByHanjaOff: String { localized("keyBinding.disabledByHanjaOff") }
        public static var recording: String { localized("keyBinding.recording") }
        public static var conflict: String { localized("keyBinding.conflict") }
        public static var conflictRestored: String { localized("keyBinding.conflictRestored") }
        public static var capsLockStatusTitle: String { localized("keyBinding.capsLockStatusTitle") }
        public static var capsLockStatusOn: String { localized("keyBinding.capsLockStatusOn") }
        public static var capsLockStatusOff: String { localized("keyBinding.capsLockStatusOff") }
        public static var capsLockOnDescription: String { localized("keyBinding.capsLockOnDescription") }
        public static var capsLockOffDescription: String { localized("keyBinding.capsLockOffDescription") }
        public static var disabledByCapsLock: String { localized("keyBinding.disabledByCapsLock") }
        public static var managedByMacOS: String { localized("keyBinding.managedByMacOS") }
        public static var capsLockBlockedTitle: String { localized("keyBinding.capsLockBlockedTitle") }
        public static var capsLockBlockedMessage: String { localized("keyBinding.capsLockBlockedMessage") }
        public static var capsLockOpenSettings: String { localized("keyBinding.capsLockOpenSettings") }
    }
    
    // MARK: - About
    
    public enum about {
        public static var description: String { localized("about.description") }
        public static var version: String { localized("about.version") }
    }
    
    // MARK: - Input Menu

    /// Items PriType adds to the system input menu.
    public enum menu {
        public static var settings: String { localized("menu.settings") }
        public static var about: String { localized("menu.about") }
    }

    // MARK: - App
    
    public enum app {
        public static var name: String { "PriType" }
        public static var copyright: String { localized("app.copyright") }
    }
    
    // MARK: - Update
    
    public enum update {
        public static var title: String { localized("update.title") }
        public static var checkButton: String { localized("update.checkButton") }
        public static var checking: String { localized("update.checking") }
        public static var upToDate: String { localized("update.upToDate") }
        public static var available: String { localized("update.available") }
        public static var download: String { localized("update.download") }
        public static var error: String { localized("update.error") }
        public static var notificationTitle: String { localized("update.notificationTitle") }
        public static var notificationBody: String { localized("update.notificationBody") }
        public static var autoCheck: String { localized("update.autoCheck") }
    }
    
    // MARK: - System
    
    public enum system {
        public static var accessibility: String { localized("system.accessibility") }
        public static var accessibilityGranted: String { localized("system.accessibilityGranted") }
        public static var accessibilityRequest: String { localized("system.accessibilityRequest") }
        public static var accessibilitySubtitle: String { localized("system.accessibilitySubtitle") }
        public static var inputMonitoring: String { localized("system.inputMonitoring") }
        public static var inputMonitoringSubtitle: String { localized("system.inputMonitoringSubtitle") }
        public static var openSystemSettings: String { localized("system.openSystemSettings") }
        public static var removeABC: String { localized("system.removeABC") }
        public static var removeABCSubtitle: String { localized("system.removeABCSubtitle") }
        public static var removeABCButton: String { localized("system.removeABCButton") }
        public static var removeABCSuccess: String { localized("system.removeABCSuccess") }
        public static var removeABCFailed: String { localized("system.removeABCFailed") }
    }

    // MARK: - System Shortcut Conflicts

    public enum shortcut {
        /// Warning shown when a binding shadows a macOS shortcut.
        public static func conflictWarning(_ shortcutName: String) -> String {
            String(format: localized("shortcut.conflictWarning"), shortcutName)
        }

        public static func name(_ key: String) -> String { localized(key) }
    }

    // MARK: - Toggle Key App Exclusions

    public enum exclusions {
        public static var subtitle: String { localized("exclusions.subtitle") }
        public static var addButton: String { localized("exclusions.addButton") }
        public static var removeButton: String { localized("exclusions.removeButton") }
        public static var empty: String { localized("exclusions.empty") }
    }

    // MARK: - Settings Panes

    public enum pane {
        public static var switchingTitle: String { localized("pane.switching.title") }
        public static var switchingDescription: String { localized("pane.switching.description") }
        public static var hanjaTitle: String { localized("pane.hanja.title") }
        public static var hanjaDescription: String { localized("pane.hanja.description") }
        public static var exclusionsTitle: String { localized("pane.exclusions.title") }
        public static var systemTitle: String { localized("pane.system.title") }
        public static var systemDescription: String { localized("pane.system.description") }
        public static var updateDescription: String { localized("pane.update.description") }
        public static var experimentalTitle: String { localized("pane.experimental.title") }
        public static var experimentalDescription: String { localized("pane.experimental.description") }
    }

    // MARK: - Experimental

    public enum experimental {
        public static var directInsertion: String { localized("experimental.directInsertion") }
        public static var directInsertionDescription: String { localized("experimental.directInsertionDescription") }
    }
}
