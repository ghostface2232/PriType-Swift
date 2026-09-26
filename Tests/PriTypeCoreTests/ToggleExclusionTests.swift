import Testing
import Foundation
import Cocoa
@testable import PriTypeCore
import PriTypeIMKHarness

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

private let remoteDesktop = "com.microsoft.rdc.macos"
/// What IMK names Spotlight's search field on macOS 27, seen on a real device.
private let spotlight = "com.apple.campo"

/// Keyboard focus against the frontmost app. Every test has a policy of its own,
/// so none of this touches `ToggleExclusionPolicy.shared`.
@Suite("Toggle exclusion follows keyboard focus")
struct ToggleExclusionFocusTests {

    /// Two input controllers, standing in for the fields IMK activates.
    private final class Controller {}
    private let first = Controller()
    private let second = Controller()

    /// A policy excluding `excluded`, with `frontmost` in front and no field focused.
    private func policy(excluding excluded: [String] = [remoteDesktop],
                        frontmost: String? = remoteDesktop) -> ToggleExclusionPolicy {
        let configuration = MockConfiguration()
        configuration.toggleExcludedBundleIDs = excluded
        let policy = ToggleExclusionPolicy()
        policy.refreshExcludedBundleIDs(from: configuration)
        policy.updateFrontmostBundleID(frontmost)
        return policy
    }

    @Test("Spotlight over an excluded app gets the toggle")
    func spotlightOverExcludedApp() {
        let policy = policy()
        #expect(policy.isTogglePaused)

        // A non-activating panel: the remote client stays frontmost, and only
        // IMK's activation says the keys now go to Spotlight.
        policy.focusDidMove(to: spotlight, owner: ObjectIdentifier(first))
        #expect(policy.currentFrontmostBundleID == remoteDesktop)
        #expect(!policy.isTogglePaused)
    }

    @Test("Closing Spotlight hands the key back to the excluded app")
    func spotlightClosed() {
        let policy = policy()
        policy.focusDidMove(to: spotlight, owner: ObjectIdentifier(first))
        #expect(!policy.isTogglePaused)

        // Escape: Spotlight's field is deactivated, no activation follows (the
        // remote session has no field of its own), and no app activates.
        policy.focusDidLeave(owner: ObjectIdentifier(first))
        #expect(policy.currentFocusOwnerBundleID == nil)
        #expect(policy.isTogglePaused)

        // A remote client with a field of its own is excluded by its own name.
        policy.focusDidMove(to: remoteDesktop, owner: ObjectIdentifier(second))
        #expect(policy.isTogglePaused)
    }

    @Test("With no focus owner to name, the frontmost app decides")
    func focusLookupFails() {
        let excludedInFront = policy()
        let ordinaryInFront = policy(frontmost: "com.apple.TextEdit")
        // No bundle ID from the client, a blank one, or no client at all.
        for bundleID in [nil, "", "   "] as [String?] {
            excludedInFront.focusDidMove(to: bundleID, owner: ObjectIdentifier(first))
            ordinaryInFront.focusDidMove(to: bundleID, owner: ObjectIdentifier(first))
            #expect(excludedInFront.currentFocusOwnerBundleID == nil)
            #expect(excludedInFront.isTogglePaused, "failing to name the owner must not lift the exclusion")
            #expect(!ordinaryInFront.isTogglePaused, "nor exclude an app the user did not list")
        }
        // Nothing known at all still never pauses.
        #expect(!policy(frontmost: nil).isTogglePaused)
    }

    @Test("A field that is already focused decides even when its app is not frontmost")
    func excludedOwnerOverOrdinaryApp() {
        let policy = policy(frontmost: "com.apple.TextEdit")
        #expect(!policy.isTogglePaused)
        policy.focusDidMove(to: "COM.MICROSOFT.RDC.MACOS", owner: ObjectIdentifier(first))
        #expect(policy.isTogglePaused)
    }

    @Test("A late deactivation of the field left behind keeps the new owner")
    func lateDeactivation() {
        let policy = policy()
        policy.focusDidMove(to: "com.apple.TextEdit", owner: ObjectIdentifier(first))
        policy.focusDidMove(to: spotlight, owner: ObjectIdentifier(second))
        policy.focusDidLeave(owner: ObjectIdentifier(first))
        #expect(policy.currentFocusOwnerBundleID == spotlight.lowercased())
        #expect(!policy.isTogglePaused)
    }

    @Test("An app activating forgets a field whose deactivation never came")
    func activationForgetsStaleOwner() {
        let policy = policy(frontmost: "com.apple.TextEdit")
        policy.focusDidMove(to: "com.apple.TextEdit", owner: ObjectIdentifier(first))
        policy.updateFrontmostBundleID(remoteDesktop)
        #expect(policy.currentFocusOwnerBundleID == nil)
        #expect(policy.isTogglePaused)
    }

    @Test("The pure rule puts the focus owner first")
    func pureRule() {
        #expect(!ToggleExclusionPolicy.isPaused(
            frontmostBundleID: remoteDesktop, focusOwnerBundleID: spotlight,
            excludedBundleIDs: [remoteDesktop]))
        #expect(ToggleExclusionPolicy.isPaused(
            frontmostBundleID: remoteDesktop, focusOwnerBundleID: " ",
            excludedBundleIDs: [remoteDesktop]))
        #expect(ToggleExclusionPolicy.isPaused(
            frontmostBundleID: nil, focusOwnerBundleID: remoteDesktop,
            excludedBundleIDs: [remoteDesktop]))
    }
}

/// The IMK lifecycle is what reports the focus owner.
@Suite("Toggle exclusion hears focus from IMK", .serialized)
@MainActor
struct ToggleExclusionIMKTests {

    @Test("Activation names the focused app, and its deactivation clears it")
    func activationReportsFocusOwner() {
        PriTypeInputController.resetSystemModeTracking()
        let harness = IMKHarness()
        defer { harness.finish() }
        let policy = harness.focusPolicy
        let configuration = MockConfiguration()
        configuration.toggleExcludedBundleIDs = [remoteDesktop]
        policy.refreshExcludedBundleIDs(from: configuration)
        policy.updateFrontmostBundleID(remoteDesktop)
        #expect(policy.isTogglePaused)

        let search = harness.makeField(bundleID: spotlight)
        harness.focus(search)
        #expect(policy.currentFocusOwnerBundleID == spotlight.lowercased())
        #expect(!policy.isTogglePaused)

        // Moving to another field of another app names that one; the field left
        // behind is deactivated first, the order IMK uses.
        let notes = harness.makeField(bundleID: "com.apple.Notes")
        harness.focus(notes)
        #expect(policy.currentFocusOwnerBundleID == "com.apple.notes")

        // A late deactivation of the old field changes nothing.
        let late = harness.makeField(bundleID: spotlight)
        harness.activateAhead(late)
        notes.controller.deactivateServer(notes.client)
        #expect(policy.currentFocusOwnerBundleID == spotlight.lowercased())

        harness.blur()
        #expect(policy.currentFocusOwnerBundleID == nil)
        #expect(policy.isTogglePaused)
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

/// Counts a callback firing across the suppressor's `@Sendable` boundary.
private final class CallbackCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func fire() {
        lock.lock(); value += 1; lock.unlock()
    }

    var times: Int {
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
        tap.onHanjaLookup = { _ in hanjaFired.fire() }

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

/// Focus moving while the toggle or Hanja key is held. Each key's press and
/// release must reach the same place: both to the app, or neither.
@Suite("Toggle exclusion with a key held across a focus change")
struct ToggleExclusionHeldKeyTests {

    private static let rightCommand: Int64 = 54
    private static let rightOption: Int64 = 61

    /// A modifier key's edge as a real tap delivers it: `down` sets its device bit.
    private func modifier(_ keyCode: Int64, down: Bool) throws -> CGEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down))
        event.type = .flagsChanged
        let shared: UInt64 = keyCode == Self.rightCommand ? 0x100000 : 0x80000
        event.flags = CGEventFlags(rawValue: down ? shared | ModifierKeyState.mask(for: keyCode) : 0)
        return event
    }

    private func send(_ tap: RightCommandSuppressor, _ event: CGEvent, excluded: Bool,
                      trigger: ToggleTrigger = .press) -> Bool {
        tap.handleEvent(type: event.type, event: event,
                        toggle: .defaultToggle, hanja: .defaultHanja,
                        toggleEnabled: true, hanjaEnabled: true,
                        trigger: trigger, excludedOverride: excluded) != nil
    }

    @Test("A toggle press swallowed before focus moved to an excluded app keeps its release")
    func swallowedPressEndsInExcludedApp() throws {
        let tap = RightCommandSuppressor()
        let toggles = CallbackCount()
        tap.onToggle = { _ in toggles.fire() }

        // Toggled in Spotlight; Escape closes it over the remote session while the
        // key is still down.
        #expect(!send(tap, try modifier(Self.rightCommand, down: true), excluded: false))
        #expect(toggles.times == 1)
        // The remote app never saw the press, so it must not see the release.
        #expect(!send(tap, try modifier(Self.rightCommand, down: false), excluded: true))
        // The press is over: the next one in the excluded app is the app's…
        #expect(send(tap, try modifier(Self.rightCommand, down: true), excluded: true))
        #expect(send(tap, try modifier(Self.rightCommand, down: false), excluded: true))
        // …and the next one elsewhere toggles again.
        #expect(!send(tap, try modifier(Self.rightCommand, down: true), excluded: false))
        #expect(!send(tap, try modifier(Self.rightCommand, down: false), excluded: false))
        #expect(toggles.times == 2)
    }

    @Test("A toggle press the excluded app saw keeps its release too")
    func passedPressEndsInOrdinaryApp() throws {
        let tap = RightCommandSuppressor()
        let toggles = CallbackCount()
        tap.onToggle = { _ in toggles.fire() }

        // Down in the remote session, then Spotlight opens over it.
        #expect(send(tap, try modifier(Self.rightCommand, down: true), excluded: true))
        #expect(send(tap, try modifier(Self.rightCommand, down: false), excluded: false))
        #expect(toggles.times == 0, "a key the excluded app took must not toggle")
    }

    @Test("A repeated press edge while the swallowed press is held stays swallowed")
    func repeatedEdgeStaysSwallowed() throws {
        let tap = RightCommandSuppressor()
        #expect(!send(tap, try modifier(Self.rightCommand, down: true), excluded: false))
        // Its release was lost; passing this on would give the app a press
        // whose release is then swallowed, leaving ⌘ stuck in the app.
        #expect(!send(tap, try modifier(Self.rightCommand, down: true), excluded: true))
        #expect(!send(tap, try modifier(Self.rightCommand, down: false), excluded: true))
    }

    @Test("A key typed in the excluded app ends a press whose release was lost")
    func lostReleaseIsForgotten() throws {
        let tap = RightCommandSuppressor()
        let toggles = CallbackCount()
        tap.onToggle = { _ in toggles.fire() }
        #expect(!send(tap, try modifier(Self.rightCommand, down: true), excluded: false))

        // While the key is held, the excluded app's keys still pass untouched.
        let held = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        held.flags = CGEventFlags(rawValue: 0x100000 | ModifierKeyState.mask(for: Self.rightCommand))
        #expect(send(tap, held, excluded: true))
        #expect(ModifierKeyState.isDown(Self.rightCommand, flags: held.flags.rawValue))

        // A key whose flags show ⌘ up: the release never reached the tap.
        let after = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        after.flags = []
        #expect(send(tap, after, excluded: true))

        #expect(!send(tap, try modifier(Self.rightCommand, down: true), excluded: false))
        #expect(toggles.times == 2, "the next press must toggle, not be taken for the lost one")
    }

    @Test("A Hanja press swallowed before focus moved keeps its release")
    func hanjaPressEndsInExcludedApp() throws {
        let tap = RightCommandSuppressor()
        let lookups = CallbackCount()
        tap.onHanjaLookup = { _ in lookups.fire() }

        #expect(!send(tap, try modifier(Self.rightOption, down: true), excluded: false))
        #expect(lookups.times == 1)
        #expect(!send(tap, try modifier(Self.rightOption, down: false), excluded: true))
        // Over: the excluded app's own ⌥ passes both ways and looks nothing up.
        #expect(send(tap, try modifier(Self.rightOption, down: true), excluded: true))
        #expect(send(tap, try modifier(Self.rightOption, down: false), excluded: true))
        #expect(lookups.times == 1)
    }

    @Test("In tap mode both edges always pass, and focus moving mid-tap cancels it")
    func tapModeAcrossFocusChange() throws {
        let tap = RightCommandSuppressor()
        let toggles = CallbackCount()
        tap.onToggle = { _ in toggles.fire() }

        #expect(send(tap, try modifier(Self.rightCommand, down: true), excluded: false, trigger: .tapAlone))
        #expect(send(tap, try modifier(Self.rightCommand, down: false), excluded: true, trigger: .tapAlone))
        #expect(send(tap, try modifier(Self.rightCommand, down: true), excluded: true, trigger: .tapAlone))
        #expect(send(tap, try modifier(Self.rightCommand, down: false), excluded: false, trigger: .tapAlone))
        #expect(toggles.times == 0)

        // A tap entirely outside the excluded app still toggles.
        #expect(send(tap, try modifier(Self.rightCommand, down: true), excluded: false, trigger: .tapAlone))
        #expect(send(tap, try modifier(Self.rightCommand, down: false), excluded: false, trigger: .tapAlone))
        #expect(toggles.times == 1)
    }
}
