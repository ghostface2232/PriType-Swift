import Testing
import Foundation
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

    /// Scratch domain so the migration never touches the developer's real defaults.
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "com.pritype.tests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func storedBinding(_ defaults: UserDefaults, _ key: String) -> KeyBinding? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyBinding.self, from: data)
    }

    @Test("Legacy toggleKey is written out as a KeyBinding and then dropped")
    func legacyToggleKeyIsPersisted() {
        let defaults = makeDefaults("legacy")
        defaults.set(ToggleKey.controlSpace.rawValue, forKey: "com.pritype.toggleKey")

        #expect(ConfigurationManager.migrateKeyBindings(in: defaults))

        let migrated = storedBinding(defaults, "com.pritype.toggleKeyBinding")
        #expect(migrated?.keyCode == ToggleKey.controlSpace.asKeyBinding.keyCode)
        #expect(migrated?.modifiers == ToggleKey.controlSpace.asKeyBinding.modifiers)
        // The legacy key has no readers left; leaving it would let it resurface.
        #expect(defaults.object(forKey: "com.pritype.toggleKey") == nil)
    }

    @Test("Migration is idempotent and leaves an explicit binding alone")
    func migrationIsIdempotent() {
        let defaults = makeDefaults("idempotent")
        let chosen = KeyBinding(keyCode: 122, modifiers: 0, displayName: "F1")
        defaults.set(try! JSONEncoder().encode(chosen), forKey: "com.pritype.toggleKeyBinding")

        #expect(!ConfigurationManager.migrateKeyBindings(in: defaults))
        #expect(storedBinding(defaults, "com.pritype.toggleKeyBinding")?.keyCode == 122)
        #expect(!ConfigurationManager.migrateKeyBindings(in: defaults))
    }

    @Test("A stored binding is preferred over a leftover legacy value")
    func storedBindingWinsOverLegacy() {
        let defaults = makeDefaults("both")
        let chosen = KeyBinding(keyCode: 122, modifiers: 0, displayName: "F1")
        defaults.set(try! JSONEncoder().encode(chosen), forKey: "com.pritype.toggleKeyBinding")
        defaults.set(ToggleKey.controlSpace.rawValue, forKey: "com.pritype.toggleKey")

        #expect(ConfigurationManager.migrateKeyBindings(in: defaults))
        #expect(storedBinding(defaults, "com.pritype.toggleKeyBinding")?.keyCode == 122)
        #expect(defaults.object(forKey: "com.pritype.toggleKey") == nil)
    }

    @Test("Unsafe and unreadable stored bindings are repaired on disk")
    func unsafeStoredBindingsAreRepaired() {
        let defaults = makeDefaults("unsafe")
        // A bare letter key would swallow ordinary typing globally.
        let unsafe = KeyBinding(keyCode: 0, modifiers: 0, displayName: "A")
        #expect(!unsafe.isSafeGlobalBinding)
        defaults.set(try! JSONEncoder().encode(unsafe), forKey: "com.pritype.toggleKeyBinding")
        defaults.set(Data("not json".utf8), forKey: "com.pritype.hanjaKeyBinding")

        #expect(ConfigurationManager.migrateKeyBindings(in: defaults))
        #expect(storedBinding(defaults, "com.pritype.toggleKeyBinding")?.keyCode == KeyBinding.defaultToggle.keyCode)
        #expect(storedBinding(defaults, "com.pritype.hanjaKeyBinding")?.keyCode == KeyBinding.defaultHanja.keyCode)
        // Repaired values are now safe, so a second pass is a no-op.
        #expect(!ConfigurationManager.migrateKeyBindings(in: defaults))
    }

    @Test("A clean install needs no migration")
    func cleanInstallIsUntouched() {
        let defaults = makeDefaults("clean")
        #expect(!ConfigurationManager.migrateKeyBindings(in: defaults))
        #expect(defaults.data(forKey: "com.pritype.toggleKeyBinding") == nil)
    }
}
