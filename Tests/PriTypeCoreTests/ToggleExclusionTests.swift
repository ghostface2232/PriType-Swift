import Testing
import Foundation
import Cocoa
@testable import PriTypeCore

// Three of these tests mutate process-wide singletons (ConfigurationManager.shared
// → UserDefaults.standard, and ToggleExclusionPolicy.shared). swift-testing runs a
// suite's tests in parallel by default, which let one test's write land inside
// another's assert — a reproducible ~25% failure rate.
@Suite("Toggle exclusion policy", .serialized)
struct ToggleExclusionPolicyTests {

    @Test("An excluded frontmost app pauses the toggle")
    func excludedAppPauses() {
        #expect(ToggleExclusionPolicy.isPaused(
            frontmostBundleID: "com.microsoft.rdc.macos",
            excludedBundleIDs: ["com.microsoft.rdc.macos"]
        ))
    }

    @Test("Unlisted, unknown, and empty-list cases never pause")
    func nonExcludedCases() {
        #expect(!ToggleExclusionPolicy.isPaused(
            frontmostBundleID: "com.apple.TextEdit",
            excludedBundleIDs: ["com.microsoft.rdc.macos"]
        ))
        #expect(!ToggleExclusionPolicy.isPaused(
            frontmostBundleID: "com.apple.TextEdit",
            excludedBundleIDs: []
        ))
        // No frontmost app must never be treated as excluded — failing open here
        // would silently disable the toggle instead of a single app.
        #expect(!ToggleExclusionPolicy.isPaused(
            frontmostBundleID: nil,
            excludedBundleIDs: ["com.apple.TextEdit"]
        ))
    }

    @Test("Bundle IDs match case-insensitively and ignore surrounding whitespace")
    func matchingIsNormalized() {
        #expect(ToggleExclusionPolicy.isPaused(
            frontmostBundleID: "com.Microsoft.RDC.macOS",
            excludedBundleIDs: ["  com.microsoft.rdc.macos "]
        ))
    }

    @Test("List editing rejects duplicates and blanks")
    func listEditing() {
        var list: [String] = []
        list = ToggleExclusionPolicy.adding("com.apple.TextEdit", to: list)
        list = ToggleExclusionPolicy.adding("com.apple.textedit", to: list)  // same app
        list = ToggleExclusionPolicy.adding("   ", to: list)
        #expect(list == ["com.apple.TextEdit"])

        list = ToggleExclusionPolicy.adding("com.apple.Terminal", to: list)
        #expect(list.count == 2)

        // Removal is case-insensitive too, so an entry can always be deleted.
        list = ToggleExclusionPolicy.removing("COM.APPLE.TEXTEDIT", from: list)
        #expect(list == ["com.apple.Terminal"])
        list = ToggleExclusionPolicy.removing("com.apple.Safari", from: list)
        #expect(list == ["com.apple.Terminal"])
    }

    @Test("The shared policy reads a cached frontmost app, not a live query")
    func sharedPolicyUsesCachedFrontmostApp() {
        let policy = ToggleExclusionPolicy.shared
        let originalList = ConfigurationManager.shared.toggleExcludedBundleIDs
        let originalFrontmost = policy.currentFrontmostBundleID
        defer {
            ConfigurationManager.shared.toggleExcludedBundleIDs = originalList
            policy.updateFrontmostBundleID(originalFrontmost)
        }

        ConfigurationManager.shared.toggleExcludedBundleIDs = ["com.example.remote"]
        policy.updateFrontmostBundleID("com.example.remote")
        #expect(policy.isTogglePaused)

        // Activating another app lifts the pause with no further configuration read.
        policy.updateFrontmostBundleID("com.apple.TextEdit")
        #expect(!policy.isTogglePaused)

        // Losing the frontmost app must not leave the toggle paused.
        policy.updateFrontmostBundleID(nil)
        #expect(!policy.isTogglePaused)
    }

    @Test("Clearing the list takes effect immediately")
    func clearingListLiftsPause() {
        let policy = ToggleExclusionPolicy.shared
        let originalList = ConfigurationManager.shared.toggleExcludedBundleIDs
        let originalFrontmost = policy.currentFrontmostBundleID
        defer {
            ConfigurationManager.shared.toggleExcludedBundleIDs = originalList
            policy.updateFrontmostBundleID(originalFrontmost)
        }

        ConfigurationManager.shared.toggleExcludedBundleIDs = ["com.example.remote"]
        policy.updateFrontmostBundleID("com.example.remote")
        #expect(policy.isTogglePaused)

        // The setter refreshes the policy snapshot; no restart required.
        ConfigurationManager.shared.toggleExcludedBundleIDs = []
        #expect(!policy.isTogglePaused)
    }

    @Test("Duplicates are collapsed when the list is persisted")
    func persistedListIsDeduplicated() {
        let original = ConfigurationManager.shared.toggleExcludedBundleIDs
        defer { ConfigurationManager.shared.toggleExcludedBundleIDs = original }

        ConfigurationManager.shared.toggleExcludedBundleIDs = [
            "com.example.remote", "COM.EXAMPLE.REMOTE", " ", "com.example.other"
        ]
        #expect(ConfigurationManager.shared.toggleExcludedBundleIDs == ["com.example.remote", "com.example.other"])
    }
}

/// Records a callback firing across the suppressor's `@Sendable` boundary.
private final class CallbackFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func fire() {
        lock.lock(); value = true; lock.unlock()
    }

    var didFire: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

@Suite("Toggle exclusion at the event tap")
struct ToggleExclusionEventTapTests {

    /// Right Command down, as the suppressor sees it from a real tap.
    private func rightCommandDown() throws -> CGEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: true))
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: 0x100010 | ModifierKeyState.mask(for: 54))
        return event
    }

    @Test("An excluded app receives the toggle key untouched")
    func excludedAppKeepsItsKey() throws {
        let tap = RightCommandSuppressor()
        let toggled = CallbackFlag()
        tap.onToggle = { _ in toggled.fire() }

        let event = try rightCommandDown()
        let result = tap.handleEvent(
            type: .flagsChanged, event: event,
            toggle: .defaultToggle, hanja: .defaultHanja,
            toggleEnabled: true, excludedOverride: true
        )

        // Passed through (non-nil) and unmodified — the remote app's own IME needs
        // both the event and its Command flag.
        #expect(result != nil, "excluded app must still receive the event")
        #expect(event.flags.contains(.maskCommand))
        #expect(!toggled.didFire)
    }

    @Test("The same key still toggles when the app is not excluded")
    func nonExcludedAppStillToggles() throws {
        let tap = RightCommandSuppressor()
        let event = try rightCommandDown()
        let result = tap.handleEvent(
            type: .flagsChanged, event: event,
            toggle: .defaultToggle, hanja: .defaultHanja,
            toggleEnabled: true, excludedOverride: false
        )
        #expect(result == nil, "toggle key is consumed for non-excluded apps")
    }

    @Test("Excluded apps keep the toggle modifier on ordinary keys")
    func excludedAppKeepsModifierOnOtherKeys() throws {
        let tap = RightCommandSuppressor()
        let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))  // C
        key.flags = CGEventFlags(rawValue: 0x100010 | ModifierKeyState.mask(for: 54))

        _ = tap.handleEvent(
            type: .keyDown, event: key,
            toggle: .defaultToggle, hanja: .defaultHanja,
            toggleEnabled: true, excludedOverride: true
        )

        // Modifier stripping would turn the guest's Command+C into a plain "c".
        #expect(key.flags.contains(.maskCommand))
        #expect(ModifierKeyState.isDown(54, flags: key.flags.rawValue))
    }

    @Test("Excluded apps do not trigger hanja lookup")
    func excludedAppSuppressesHanja() throws {
        let tap = RightCommandSuppressor()
        let hanjaFired = CallbackFlag()
        tap.onHanjaLookup = { hanjaFired.fire() }

        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: true))
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: ModifierKeyState.mask(for: 61))

        let result = tap.handleEvent(
            type: .flagsChanged, event: event,
            toggle: .defaultToggle, hanja: .defaultHanja,
            toggleEnabled: true, excludedOverride: true
        )
        #expect(result != nil)
        #expect(!hanjaFired.didFire)
    }
}
