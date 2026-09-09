import Testing
import Foundation
import CoreGraphics
@testable import PriTypeCore

// MARK: - ConfigurationManager Tests

@Suite("ConfigurationManager", .serialized)
struct ConfigurationManagerTests {
    
    // MARK: - Keyboard Layout Tests
    
    @Test("Default keyboard ID is Dubeolsik (2)")
    func defaultKeyboardId() {
        #expect(ConfigurationManager.shared.keyboardId == "2")
    }
    
    @Test("Keyboard ID persists to UserDefaults")
    func keyboardIdPersistence() {
        let original = ConfigurationManager.shared.keyboardId
        defer { ConfigurationManager.shared.keyboardId = original }
        
        ConfigurationManager.shared.keyboardId = "3"
        #expect(ConfigurationManager.shared.keyboardId == "3")
        
        let stored = UserDefaults.standard.string(forKey: "com.pritype.keyboardId")
        #expect(stored == "3")
    }
    
    // MARK: - Toggle Key Tests (Legacy)
    
    @Test("Default toggle key is rightCommand")
    func defaultToggleKey() {
        #expect(ConfigurationManager.shared.toggleKey == .rightCommand)
    }
    
    @Test("Toggle key persists correctly")
    func toggleKeyPersistence() {
        let original = ConfigurationManager.shared.toggleKey
        defer { ConfigurationManager.shared.toggleKey = original }
        
        ConfigurationManager.shared.toggleKey = .controlSpace
        #expect(ConfigurationManager.shared.toggleKey == .controlSpace)
    }
    
    // MARK: - KeyBinding Tests
    
    @Test("Default toggle key binding is Right Command")
    func defaultToggleKeyBinding() {
        let binding = KeyBinding.defaultToggle
        #expect(binding.keyCode == 54)
        #expect(binding.modifiers == 0)
        #expect(binding.isModifierOnly)
        #expect(binding.displayName == "우측 Command")
    }
    
    @Test("Default hanja key binding is Right Option")
    func defaultHanjaKeyBinding() {
        let binding = KeyBinding.defaultHanja
        #expect(binding.keyCode == 61)
        #expect(binding.modifiers == 0)
        #expect(binding.isModifierOnly)
        #expect(binding.displayName == "우측 Option")
    }
    
    @Test("KeyBinding Codable round-trip")
    func keyBindingCodable() throws {
        let original = KeyBinding(keyCode: 62, modifiers: 0, displayName: "우측 Control")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KeyBinding.self, from: data)
        #expect(original == decoded)
    }
    
    @Test("KeyBinding displayName generation for modifier-only keys")
    func keyBindingDisplayNameModifierOnly() {
        #expect(KeyBinding.generateDisplayName(keyCode: 54, modifiers: 0) == "우측 Command")
        #expect(KeyBinding.generateDisplayName(keyCode: 61, modifiers: 0) == "우측 Option")
        #expect(KeyBinding.generateDisplayName(keyCode: 62, modifiers: 0) == "우측 Control")
        #expect(KeyBinding.generateDisplayName(keyCode: 59, modifiers: 0) == "좌측 Control")
        #expect(KeyBinding.generateDisplayName(keyCode: 57, modifiers: 0) == "Caps Lock")
    }
    
    @Test("KeyBinding displayName generation for regular keys")
    func keyBindingDisplayNameRegularKeys() {
        #expect(KeyBinding.generateDisplayName(keyCode: 0, modifiers: 0) == "A")
        #expect(KeyBinding.generateDisplayName(keyCode: 5, modifiers: 0) == "G")
        #expect(KeyBinding.generateDisplayName(keyCode: 49, modifiers: 0) == "Space")
        #expect(KeyBinding.generateDisplayName(keyCode: 122, modifiers: 0) == "F1")
        #expect(KeyBinding.generateDisplayName(keyCode: 18, modifiers: 0) == "1")
    }
    
    @Test("KeyBinding isModifierKey distinguishes modifier from regular keys")
    func keyBindingIsModifierKey() {
        let rightCmd = KeyBinding(keyCode: 54, modifiers: 0, displayName: "우측 Command")
        #expect(rightCmd.isModifierKey)
        
        let gKey = KeyBinding(keyCode: 5, modifiers: 0, displayName: "G")
        #expect(!gKey.isModifierKey)
        
        let f13 = KeyBinding(keyCode: 105, modifiers: 0, displayName: "F13")
        #expect(!f13.isModifierKey)
    }
    @Test("KeyBinding Equatable detects conflicts")
    func keyBindingConflictDetection() {
        let toggle = KeyBinding(keyCode: 54, modifiers: 0, displayName: "우측 Command")
        let hanja = KeyBinding(keyCode: 61, modifiers: 0, displayName: "우측 Option")
        let duplicate = KeyBinding(keyCode: 54, modifiers: 0, displayName: "우측 Command")
        
        #expect(toggle != hanja)
        #expect(toggle == duplicate)
    }
    
    @Test("Legacy ToggleKey migration to KeyBinding")
    func legacyToggleKeyMigration() {
        let rightCmd = ToggleKey.rightCommand.asKeyBinding
        #expect(rightCmd.keyCode == 54)
        #expect(rightCmd.isModifierOnly)
        
        let ctrlSpace = ToggleKey.controlSpace.asKeyBinding
        #expect(ctrlSpace.keyCode == 49)
        #expect(!ctrlSpace.isModifierOnly)
        #expect(ctrlSpace.modifiers != 0)
    }
    
    @Test("Toggle key binding persists correctly")
    func toggleKeyBindingPersistence() {
        let original = ConfigurationManager.shared.toggleKeyBinding
        defer { ConfigurationManager.shared.toggleKeyBinding = original }
        
        let newBinding = KeyBinding(keyCode: 62, modifiers: 0, displayName: "우측 Control")
        ConfigurationManager.shared.toggleKeyBinding = newBinding
        #expect(ConfigurationManager.shared.toggleKeyBinding == newBinding)
        #expect(!ConfigurationManager.shared.rightCommandAsToggle)
    }
    
    @Test("Hanja key binding persists correctly")
    func hanjaKeyBindingPersistence() {
        let original = ConfigurationManager.shared.hanjaKeyBinding
        defer { ConfigurationManager.shared.hanjaKeyBinding = original }
        
        let newBinding = KeyBinding(keyCode: 62, modifiers: 0, displayName: "우측 Control")
        ConfigurationManager.shared.hanjaKeyBinding = newBinding
        #expect(ConfigurationManager.shared.hanjaKeyBinding == newBinding)
    }
    
    @Test("Convenience properties reflect key bindings")
    func conveniencePropertiesReflectBindings() {
        let original = ConfigurationManager.shared.toggleKeyBinding
        defer { ConfigurationManager.shared.toggleKeyBinding = original }
        
        ConfigurationManager.shared.toggleKeyBinding = .defaultToggle
        #expect(ConfigurationManager.shared.rightCommandAsToggle)
        #expect(!ConfigurationManager.shared.controlSpaceAsToggle)
    }
    
    @Test("System double-space-period setting is readable")
    func systemDoubleSpacePeriodSettingIsReadable() {
        let value = ConfigurationManager.shared.doubleSpacePeriodEnabled
        #expect(value == true || value == false)
    }

}

// MARK: - Key Binding Migration Tests

@Suite("KeyBinding defaults migration")
struct KeyBindingMigrationTests {

    private let toggleKey = "com.pritype.toggleKeyBinding"
    private let hanjaKey = "com.pritype.hanjaKeyBinding"
    private let legacyKey = "com.pritype.toggleKey"

    /// Scratch domain so the migration never touches the developer's real defaults.
    ///
    /// Scoped, not merely created: without the teardown every run left a populated
    /// plist in ~/Library/Preferences forever (the suite name carries a fresh
    /// UUID), and those files held real binding data. `removeSuite` is what
    /// actually detaches the domain — `removePersistentDomain` alone leaves a stub.
    private func withScratchDefaults(_ name: String, _ body: (UserDefaults) -> Void) {
        let suite = "com.pritype.tests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.removeSuite(named: suite)
            // removeSuite detaches the domain but cfprefsd still leaves the plist on
            // disk; delete it so scratch suites do not accumulate in ~/Library/Preferences.
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suite).plist")
            try? FileManager.default.removeItem(at: plist)
        }
        body(defaults)
    }

    private func storedBinding(_ defaults: UserDefaults, _ key: String) -> KeyBinding? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyBinding.self, from: data)
    }

    @Test("Legacy toggleKey is written out as a KeyBinding and then dropped")
    func legacyToggleKeyIsPersisted() {
        withScratchDefaults("legacy") { defaults in
            defaults.set(ToggleKey.controlSpace.rawValue, forKey: legacyKey)

            #expect(ConfigurationManager.migrateKeyBindings(in: defaults))

            let migrated = storedBinding(defaults, toggleKey)
            #expect(migrated?.keyCode == ToggleKey.controlSpace.asKeyBinding.keyCode)
            #expect(migrated?.modifiers == ToggleKey.controlSpace.asKeyBinding.modifiers)
            // The legacy key has no readers left; leaving it would let it resurface.
            #expect(defaults.object(forKey: legacyKey) == nil)
        }
    }

    @Test("Migration is idempotent and leaves an explicit binding alone")
    func migrationIsIdempotent() {
        withScratchDefaults("idempotent") { defaults in
            let chosen = KeyBinding(keyCode: 122, modifiers: 0, displayName: "F1")
            defaults.set(try! JSONEncoder().encode(chosen), forKey: toggleKey)

            #expect(!ConfigurationManager.migrateKeyBindings(in: defaults))
            #expect(storedBinding(defaults, toggleKey)?.keyCode == 122)
            #expect(!ConfigurationManager.migrateKeyBindings(in: defaults))
        }
    }

    @Test("A stored binding is preferred over a leftover legacy value")
    func storedBindingWinsOverLegacy() {
        withScratchDefaults("both") { defaults in
            let chosen = KeyBinding(keyCode: 122, modifiers: 0, displayName: "F1")
            defaults.set(try! JSONEncoder().encode(chosen), forKey: toggleKey)
            defaults.set(ToggleKey.controlSpace.rawValue, forKey: legacyKey)

            #expect(ConfigurationManager.migrateKeyBindings(in: defaults))
            #expect(storedBinding(defaults, toggleKey)?.keyCode == 122)
            #expect(defaults.object(forKey: legacyKey) == nil)
        }
    }

    @Test("An unreadable blob falls back to the legacy value, not to the default")
    func corruptBlobRecoversFromLegacy() {
        withScratchDefaults("corrupt") { defaults in
            // The getter treats "undecodable" and "absent" identically and uses the
            // legacy enum for both, so the running app was on Control+Space.
            // Splitting on `data != nil` would overwrite it with Right Command and
            // then delete the legacy key — silent, irrecoverable preference loss.
            defaults.set(Data("not json".utf8), forKey: toggleKey)
            defaults.set(ToggleKey.controlSpace.rawValue, forKey: legacyKey)

            #expect(ConfigurationManager.migrateKeyBindings(in: defaults))
            let migrated = storedBinding(defaults, toggleKey)
            #expect(migrated?.keyCode == ToggleKey.controlSpace.asKeyBinding.keyCode)
            #expect(migrated?.keyCode != KeyBinding.defaultToggle.keyCode)
            #expect(defaults.object(forKey: legacyKey) == nil)
        }
    }

    @Test("Unsafe and unreadable stored bindings are repaired on disk")
    func unsafeStoredBindingsAreRepaired() {
        withScratchDefaults("unsafe") { defaults in
            // A bare letter key would swallow ordinary typing globally.
            let unsafe = KeyBinding(keyCode: 0, modifiers: 0, displayName: "A")
            #expect(!unsafe.isSafeGlobalBinding)
            defaults.set(try! JSONEncoder().encode(unsafe), forKey: toggleKey)
            defaults.set(Data("not json".utf8), forKey: hanjaKey)

            #expect(ConfigurationManager.migrateKeyBindings(in: defaults))
            #expect(storedBinding(defaults, toggleKey)?.keyCode == KeyBinding.defaultToggle.keyCode)
            #expect(storedBinding(defaults, hanjaKey)?.keyCode == KeyBinding.defaultHanja.keyCode)
            // Repaired values are now safe, so a second pass is a no-op.
            #expect(!ConfigurationManager.migrateKeyBindings(in: defaults))
        }
    }

    @Test("An unreadable blob with no legacy source falls back to the default")
    func corruptBlobWithoutLegacyUsesDefault() {
        withScratchDefaults("corruptOnly") { defaults in
            defaults.set(Data("not json".utf8), forKey: toggleKey)

            #expect(ConfigurationManager.migrateKeyBindings(in: defaults))
            #expect(storedBinding(defaults, toggleKey)?.keyCode == KeyBinding.defaultToggle.keyCode)
            #expect(!ConfigurationManager.migrateKeyBindings(in: defaults))
        }
    }

    @Test("A clean install needs no migration")
    func cleanInstallIsUntouched() {
        withScratchDefaults("clean") { defaults in
            #expect(!ConfigurationManager.migrateKeyBindings(in: defaults))
            #expect(defaults.data(forKey: toggleKey) == nil)
        }
    }
}

// MARK: - System Shortcut Conflict Tests

@Suite("System shortcut conflicts")
struct SystemShortcutConflictTests {

    private func binding(_ keyCode: Int64, _ modifiers: CGEventFlags...) -> KeyBinding {
        let mask = modifiers.reduce(UInt64(0)) { $0 | $1.rawValue }
        return KeyBinding(keyCode: keyCode, modifiers: mask,
                          displayName: KeyBinding.generateDisplayName(keyCode: keyCode, modifiers: mask))
    }

    @Test("Input-source and Spotlight space combos are reported")
    func spaceCombosConflict() {
        #expect(binding(49, .maskControl).systemShortcutConflict?.nameKey == "shortcut.previousInputSource")
        #expect(binding(49, .maskControl, .maskAlternate).systemShortcutConflict?.nameKey == "shortcut.nextInputSource")
        #expect(binding(49, .maskCommand).systemShortcutConflict?.nameKey == "shortcut.spotlight")
        #expect(binding(49, .maskCommand, .maskControl).systemShortcutConflict?.nameKey == "shortcut.emojiPicker")
    }

    @Test("Screenshot combos are reported")
    func screenshotCombosConflict() {
        #expect(binding(20, .maskCommand, .maskShift).systemShortcutConflict?.nameKey == "shortcut.screenshot")
        #expect(binding(21, .maskCommand, .maskShift).systemShortcutConflict?.nameKey == "shortcut.screenshotRegion")
        #expect(binding(23, .maskCommand, .maskShift).systemShortcutConflict?.nameKey == "shortcut.screenshotUI")
    }

    @Test("Defaults and unrelated combos never warn")
    func nonConflictingBindings() {
        // The shipped defaults must be silent, or the warning becomes noise.
        #expect(KeyBinding.defaultToggle.systemShortcutConflict == nil)
        #expect(KeyBinding.defaultHanja.systemShortcutConflict == nil)
        #expect(binding(122).systemShortcutConflict == nil)             // F1
        #expect(binding(5, .maskCommand, .maskAlternate).systemShortcutConflict == nil)  // Cmd+Opt+G
    }

    @Test("Matching is exact — extra or missing modifiers do not warn")
    func matchingIsExact() {
        // Control+Shift+Space is not the input-source shortcut.
        #expect(binding(49, .maskControl, .maskShift).systemShortcutConflict == nil)
        // Bare Space is not Spotlight.
        #expect(binding(49).systemShortcutConflict == nil)
        // Same modifiers on a different key are unrelated.
        #expect(binding(48, .maskControl).systemShortcutConflict == nil)
    }

    @Test("Realistic dirty recorder flags still resolve to a conflict")
    func normalizedRecordedModifiersStillConflict() {
        // What a CGEventTap actually delivers for Control+Space: the bare mask plus
        // the device-specific left-control bit, maskNonCoalesced and a latched Caps
        // Lock. The recorder narrows this to the four bare masks; if that ever
        // stops happening, the exact `==` in `matches` fails and the whole feature
        // dies silently. This is the test standing between those two facts.
        let dirty = CGEventFlags.maskControl.rawValue
            | 0x0001                                   // NX_DEVICELCTLKEYMASK
            | 0x0100                                   // maskNonCoalesced
            | CGEventFlags.maskAlphaShift.rawValue     // latched Caps Lock
        let normalized = dirty & (CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskShift.rawValue)

        #expect(normalized == CGEventFlags.maskControl.rawValue)
        let recorded = KeyBinding(keyCode: 49, modifiers: normalized,
                                  displayName: KeyBinding.generateDisplayName(keyCode: 49, modifiers: normalized))
        #expect(recorded.systemShortcutConflict?.nameKey == "shortcut.previousInputSource")

        // The un-normalized value must NOT match — that is the failure being guarded.
        let unnormalized = KeyBinding(keyCode: 49, modifiers: dirty, displayName: "Control + Space")
        #expect(unnormalized.systemShortcutConflict == nil)
    }

    @Test("Every catalogued shortcut has a distinct localization key")
    func shortcutCatalogIsWellFormed() {
        let keys = KeyBinding.SystemShortcut.all.map(\.nameKey)
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0.hasPrefix("shortcut.") })
    }
}
