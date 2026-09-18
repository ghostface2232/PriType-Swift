import Testing
import Cocoa
@testable import PriTypeCore

@Suite("Event tap failure handoff")
struct EventTapFailureTrackerTests {
    @Test("Third disable hands off exactly once and never re-enables the tap")
    func oneShotHandoff() {
        var tracker = EventTapFailureTracker(maxRetries: 3, stableResetInterval: 60)

        #expect(tracker.recordDisable(at: 1) == .reenable(attempt: 1))
        #expect(tracker.recordDisable(at: 2) == .reenable(attempt: 2))
        #expect(tracker.recordDisable(at: 3) == .handoffToIOKit)
        #expect(tracker.recordDisable(at: 4) == .ignore)
        #expect(tracker.hasHandedOff)
    }

    @Test("A stable interval resets transient failure count")
    func stableIntervalReset() {
        var tracker = EventTapFailureTracker(maxRetries: 3, stableResetInterval: 60)

        #expect(tracker.recordDisable(at: 1) == .reenable(attempt: 1))
        #expect(tracker.recordDisable(at: 2) == .reenable(attempt: 2))
        #expect(tracker.recordDisable(at: 63) == .reenable(attempt: 1))
        #expect(!tracker.hasHandedOff)
    }

    @Test("A new CGEventTap lifecycle can recover independently")
    func lifecycleReset() {
        var tracker = EventTapFailureTracker(maxRetries: 1)
        #expect(tracker.recordDisable(at: 1) == .handoffToIOKit)

        tracker.reset()

        #expect(tracker.recordDisable(at: 2) == .handoffToIOKit)
    }
}

@Suite("Modifier physical state")
struct ModifierKeyStateTests {
    @Test("Right Command release is detected while Left Command stays held")
    func sidesAreIndependent() {
        let both: UInt64 = 0x100018
        #expect(ModifierKeyState.isDown(54, flags: both))
        #expect(!ModifierKeyState.isDown(54, flags: 0x100008))
        #expect(ModifierKeyState.isDown(55, flags: 0x100008))
        #expect(!ModifierKeyState.isDown(54, flags: 0))
    }

    @Test("Ordinary typing cannot become a global single-key binding")
    func rejectsTyping() {
        for code: Int64 in [0, 18, 49, 36, 51, 48, 117, 57, 63] {
            #expect(!KeyBinding(keyCode: code, modifiers: 0, displayName: "test").isSafeGlobalBinding)
        }
        #expect(!KeyBinding(keyCode: 0, modifiers: 0x20000, displayName: "Shift A").isSafeGlobalBinding)
        #expect(KeyBinding.defaultToggle.isSafeGlobalBinding)
        #expect(KeyBinding.defaultHanja.isSafeGlobalBinding)
        #expect(ToggleKey.controlSpace.asKeyBinding.isSafeGlobalBinding)
        #expect(KeyBinding(keyCode: 105, modifiers: 0, displayName: "F13").isSafeGlobalBinding)
    }
}

@Suite("Toggle recovery event sequences")
struct ToggleRecoveryEventTests {
    @Test("Lost right release never strips a left Command shortcut")
    func lostRelease() throws {
        let tap = RightCommandSuppressor()
        let press = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: true))
        press.flags = CGEventFlags(rawValue: 0x100010)
        #expect(tap.handleEvent(type: .flagsChanged, event: press,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true) == nil)
        _ = tap.handleEvent(type: .tapDisabledByTimeout, event: press,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true, recoveryFlags: 0)
        let shortcut = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        shortcut.flags = CGEventFlags(rawValue: 0x100008)
        #expect(tap.handleEvent(type: .keyDown, event: shortcut,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true) != nil)
        #expect(shortcut.flags.contains(.maskCommand))
        // A subsequent right press is recognized, rather than stuck in held state.
        #expect(tap.handleEvent(type: .flagsChanged, event: press,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true) == nil)
    }

    @Test("Holding both Commands preserves left shortcut semantics")
    func bothCommands() throws {
        let tap = RightCommandSuppressor()
        let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        key.flags = CGEventFlags(rawValue: 0x100018)
        _ = tap.handleEvent(type: .keyDown, event: key,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true)
        #expect(key.flags.contains(.maskCommand))
        #expect(!ModifierKeyState.isDown(54, flags: key.flags.rawValue))
        #expect(ModifierKeyState.isDown(55, flags: key.flags.rawValue))
        key.flags = CGEventFlags(rawValue: 0x100010)
        _ = tap.handleEvent(type: .keyDown, event: key,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true)
        #expect(!key.flags.contains(.maskCommand))
    }

    @Test("Later explicit mode selection invalidates a delayed old controller value")
    func oldModeCannotOverrideNewSelection() {
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        let pending = DeferredInputMode(mode: .english, revision: composer.modeSelectionRevision)
        #expect(pending.resolve(currentRevision: composer.modeSelectionRevision) == .english)
        composer.setInputMode(.korean)
        #expect(pending.resolve(currentRevision: composer.modeSelectionRevision) == nil)
    }

    @Test("Applying a pending mode equal to the current one still retires older pendings")
    func sameModePendingStillBumpsRevision() throws {
        let composer = HangulComposer(statusBar: MockStatusBar(), configuration: MockConfiguration())
        #expect(composer.inputMode == .korean)
        // An old English value and a newer Korean value are both parked while
        // neither controller owns the engine, so both carry the same revision.
        let staleEnglish = DeferredInputMode(mode: .english, revision: composer.modeSelectionRevision)
        let recentKorean = DeferredInputMode(mode: .korean, revision: composer.modeSelectionRevision)

        // The newer controller activates first. Korean is already the current mode,
        // but applying it must still count as an explicit selection.
        let resolvedKorean = recentKorean.resolve(currentRevision: composer.modeSelectionRevision)
        #expect(resolvedKorean == .korean)
        composer.setInputMode(try #require(resolvedKorean))

        // The older controller activates afterwards; its English value is now stale.
        #expect(staleEnglish.resolve(currentRevision: composer.modeSelectionRevision) == nil)
        #expect(composer.inputMode == .korean)
    }
}

@Suite("Event tap thread")
struct EventTapThreadTests {
    private final class Fired: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var onMain: Bool?
    }

    /// A version-0 source that records which thread serviced it.
    private func makeSource(_ fired: Fired) -> CFRunLoopSource {
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(fired).toOpaque()
        context.perform = { info in
            let fired = Unmanaged<Fired>.fromOpaque(info!).takeUnretainedValue()
            fired.lock.withLock { fired.onMain = Thread.isMainThread }
            fired.semaphore.signal()
        }
        return CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
    }

    private func waitUntilFinished(_ thread: Thread) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !thread.isFinished && Date() < deadline { usleep(1_000) }
        return thread.isFinished
    }

    @Test("The source is serviced off the main thread and the thread ends on stop")
    func servicesOffMainAndStops() throws {
        let fired = Fired()
        let source = makeSource(fired)
        let thread = EventTapThread(source: source)
        #expect(thread.startAndWait())

        CFRunLoopSourceSignal(source)
        thread.wake()
        #expect(fired.semaphore.wait(timeout: .now() + 2) == .success)
        #expect(fired.lock.withLock { fired.onMain } == false)

        thread.stopRunLoop()
        #expect(waitUntilFinished(thread))
    }

    @Test("Stopping before the thread attaches its source still ends the thread")
    func stopBeforeAttach() {
        let fired = Fired()
        let thread = EventTapThread(source: makeSource(fired))
        thread.stopRunLoop()          // never attached: cancels
        #expect(!thread.startAndWait())
        #expect(waitUntilFinished(thread))
    }
}

@Suite("Toggle ordering across threads")
@MainActor
struct PendingToggleTests {
    @Test("An off-main toggle is recorded at once and drained on main")
    func offMainToggleIsRecordedThenDrained() {
        let coordinator = InputModeCoordinator.shared
        coordinator.applyPendingToggles()
        // A real thread (GCD `sync` may run the block on main itself); waiting for
        // it blocks main, so the hop to main cannot drain it before we look.
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            coordinator.requestToggle(source: .customKey)
            done.signal()
        }
        thread.start()
        done.wait()
        #expect(coordinator.pendingToggleCount == 1)
        coordinator.applyPendingToggles()
        #expect(coordinator.pendingToggleCount == 0)
    }
}
