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

    @Test("A stop that lands before the source is attached keeps main() from attaching")
    func stopBeforeAttach() {
        let fired = Fired()
        let thread = EventTapThread(source: makeSource(fired))
        thread.stopRunLoop()          // not attached yet: cancels
        // Run the body directly so the cancelled branch of main() is what executes.
        // Had it attached the source, CFRunLoopRun would never return.
        let returned = DispatchSemaphore(value: 0)
        Thread {
            thread.main()
            returned.signal()
        }.start()
        #expect(returned.wait(timeout: .now() + 2) == .success)
    }

    @Test("A cancelled thread reports that it did not start")
    func cancelledThreadDoesNotStart() {
        let thread = EventTapThread(source: makeSource(Fired()))
        thread.stopRunLoop()
        #expect(!thread.startAndWait(timeout: .milliseconds(100)))
    }
}

@Suite("Toggle ordering across threads")
@MainActor
struct PendingToggleTests {
    /// Record toggles from a real thread (GCD `sync` may run the block on main
    /// itself). Waiting blocks main, so the hop to main cannot drain them first.
    private func requestOffMain(at times: [TimeInterval]) {
        let done = DispatchSemaphore(value: 0)
        Thread {
            for time in times {
                InputModeCoordinator.shared.requestToggle(source: .customKey, eventTime: time)
            }
            done.signal()
        }.start()
        done.wait()
    }

    @Test("An off-main toggle is recorded at once and drained on main")
    func offMainToggleIsRecordedThenDrained() {
        let coordinator = InputModeCoordinator.shared
        coordinator.applyPendingToggles()
        requestOffMain(at: [1])
        #expect(coordinator.pendingToggleCount == 1)
        coordinator.applyPendingToggles()
        #expect(coordinator.pendingToggleCount == 0)
    }

    @Test("A keystroke applies only toggles pressed before it")
    func keystrokeAppliesOnlyEarlierToggles() {
        let coordinator = InputModeCoordinator.shared
        coordinator.applyPendingToggles()
        requestOffMain(at: [10, 30])
        // A key typed at 20 was in flight when the second toggle was pressed; it
        // takes the first toggle and must leave the second for later.
        coordinator.applyPendingToggles(before: 20)
        #expect(coordinator.pendingToggleCount == 1)
        // A key typed before both toggles changes nothing.
        coordinator.applyPendingToggles(before: 5)
        #expect(coordinator.pendingToggleCount == 1)
        coordinator.applyPendingToggles(before: 31)
        #expect(coordinator.pendingToggleCount == 0)
    }

    @Test("Toggle times use NSEvent's clock")
    func eventTimeMatchesNSEvent() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: true))
        event.timestamp = 1_234_567_890_000
        let expected = try #require(NSEvent(cgEvent: event)).timestamp
        #expect(abs(RightCommandSuppressor.eventTime(of: event) - expected) < 0.001)

        // A synthetic event without a timestamp counts as pressed now.
        event.timestamp = 0
        let now = ProcessInfo.processInfo.systemUptime
        #expect(abs(RightCommandSuppressor.eventTime(of: event) - now) < 1)
    }
}

@Suite("System mode echo filter")
struct SystemModeEchoFilterTests {
    @Test("A late echo of an earlier toggle is consumed, not applied")
    func lateEchoAfterSecondToggle() {
        var filter = SystemModeEchoFilter()
        filter.expect(.english, at: 0)   // K→E reported
        filter.expect(.korean, at: 0.01) // E→K reported before the first echo
        let echo1 = filter.consumeEcho(of: .english, at: 0.05)
        #expect(echo1)
        let echo2 = filter.consumeEcho(of: .korean, at: 0.06)
        #expect(echo2)
        // Nothing outstanding: a real selection afterwards goes through.
        let echo3 = filter.consumeEcho(of: .english, at: 0.2)
        #expect(!echo3)
    }

    @Test("A coalesced echo retires the older reports with it")
    func coalescedEcho() {
        var filter = SystemModeEchoFilter()
        filter.expect(.english, at: 0)
        filter.expect(.korean, at: 0.01)
        let echo4 = filter.consumeEcho(of: .korean, at: 0.05)
        #expect(echo4)
        let echo5 = filter.consumeEcho(of: .english, at: 0.06)
        #expect(!echo5)
    }

    @Test("A report whose echo never came cannot swallow a later selection")
    func expiredReport() {
        var filter = SystemModeEchoFilter()
        filter.expect(.english, at: 0)
        let echo6 = filter.consumeEcho(of: .english, at: SystemModeEchoFilter.lifetime + 0.1)
        #expect(!echo6)
    }

    @Test("A selection of the other mode is never taken for an echo")
    func otherModeIsReal() {
        var filter = SystemModeEchoFilter()
        filter.expect(.english, at: 0)
        let echo7 = filter.consumeEcho(of: .korean, at: 0.05)
        #expect(!echo7)
        let echo8 = filter.consumeEcho(of: .english, at: 0.06)
        #expect(echo8)
    }
}
