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

@Suite("Event tap disables")
struct EventTapDisableTests {
    @Test("User-input disables are re-enabled every time and never hand off to IOKit")
    func userInputNeverHandsOff() async throws {
        let tap = RightCommandSuppressor()
        let handedOff = HandoffFlag()
        tap.onTapFailed = { handedOff.set() }
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: true))
        for _ in 0..<10 {
            _ = tap.handleEvent(type: .tapDisabledByUserInput, event: event,
                toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true, recoveryFlags: 0)
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(!handedOff.value)
    }

    @Test("Repeated timeouts still hand off, once")
    func timeoutsHandOff() async throws {
        let tap = RightCommandSuppressor()
        let handedOff = HandoffFlag()
        tap.onTapFailed = { handedOff.set() }
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: true))
        for _ in 0..<3 {
            _ = tap.handleEvent(type: .tapDisabledByTimeout, event: event,
                toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true, recoveryFlags: 0)
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(handedOff.value)
    }
}

private final class HandoffFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
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
        let press = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: true))
        press.flags = CGEventFlags(rawValue: 0x100010)
        #expect(tap.handleEvent(type: .flagsChanged, event: press,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true) == nil)
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

    @Test("A press the tap never saw is the app's: its keys keep the modifier and its release passes")
    func unseenPressIsTheApps() throws {
        // The tap started, or was re-enabled, with Right Command already held:
        // the app saw it go down.
        let tap = RightCommandSuppressor()
        let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        key.flags = CGEventFlags(rawValue: 0x100010)
        _ = tap.handleEvent(type: .keyDown, event: key,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true)
        #expect(key.flags.contains(.maskCommand), "⌘C stays the shortcut the app expects")
        let release = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: false))
        release.flags = []
        #expect(tap.handleEvent(type: .flagsChanged, event: release,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true) != nil,
            "swallowing it would leave ⌘ stuck down in the app")
    }

    @Test("After a lost release the next press is still swallowed, so the app never sees half a press")
    func lostReleaseDoesNotLeakPress() throws {
        let tap = RightCommandSuppressor()
        let toggles = ToggleCount()
        tap.onToggle = { _ in toggles.increment() }
        let press = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: true))
        press.flags = CGEventFlags(rawValue: 0x100010)
        #expect(tap.handleEvent(type: .flagsChanged, event: press,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true, trigger: .press) == nil)
        // Its release never arrives; the next event for the key is a press again.
        #expect(tap.handleEvent(type: .flagsChanged, event: press,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true, trigger: .press) == nil)
        let release = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: false))
        release.flags = []
        #expect(tap.handleEvent(type: .flagsChanged, event: release,
            toggle: .defaultToggle, hanja: .defaultHanja, toggleEnabled: true, trigger: .press) == nil)
        #expect(toggles.value == 1, "a repeated DOWN is not a second toggle")
    }

    @Test("Later explicit mode selection invalidates a delayed old controller value")
    func oldModeCannotOverrideNewSelection() {
        let composer = HangulComposer(configuration: MockConfiguration())
        let pending = DeferredInputMode(mode: .english, revision: composer.modeSelectionRevision)
        #expect(pending.resolve(currentRevision: composer.modeSelectionRevision) == .english)
        composer.setInputMode(.korean)
        #expect(pending.resolve(currentRevision: composer.modeSelectionRevision) == nil)
    }

    @Test("Applying a pending mode equal to the current one still retires older pendings")
    func sameModePendingStillBumpsRevision() throws {
        let composer = HangulComposer(configuration: MockConfiguration())
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

    private func waitUntilFinished(_ thread: EventTapThread) -> Bool {
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
            thread.runBody()
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
    /// Wait for one turn of the main queue: everything already queued on it has run.
    private func mainQueueTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func requestOffMain(at times: [TimeInterval],
                                on coordinator: InputModeCoordinator = .shared) {
        let done = DispatchSemaphore(value: 0)
        Thread {
            for time in times {
                coordinator.requestToggle(source: .customKey, eventTime: time)
            }
            done.signal()
        }.start()
        done.wait()
    }

    @Test("An off-main toggle is recorded at once and drained on main")
    func offMainToggleIsRecordedThenDrained() {
        let coordinator = InputModeCoordinator.shared
        coordinator.applyPendingKeyActions()
        requestOffMain(at: [1])
        #expect(coordinator.pendingActionCount == 1)
        coordinator.applyPendingKeyActions()
        #expect(coordinator.pendingActionCount == 0)
    }

    @Test("A keystroke applies only toggles pressed before it")
    func keystrokeAppliesOnlyEarlierToggles() {
        let coordinator = InputModeCoordinator.shared
        coordinator.applyPendingKeyActions()
        requestOffMain(at: [10, 30])
        // A key typed at 20 was in flight when the second toggle was pressed; it
        // takes the first toggle and must leave the second for later.
        coordinator.applyPendingKeyActions(before: 20)
        #expect(coordinator.pendingActionCount == 1)
        // A key typed before both toggles changes nothing.
        coordinator.applyPendingKeyActions(before: 5)
        #expect(coordinator.pendingActionCount == 1)
        coordinator.applyPendingKeyActions(before: 31)
        #expect(coordinator.pendingActionCount == 0)
    }

    @Test("A toggle already run by a keystroke does not drag a later one in with it")
    func aDrainedActionLeavesNoTimerThatRunsTheNextOne() async {
        // Its own coordinator, and its waits fired by hand. What a deferred drain
        // reaches is the behaviour here; how long it waited first is not, and a
        // test that waits out a real timer reports on the machine it runs on.
        let coordinator = InputModeCoordinator()
        var performed: [InputModeCoordinator.KeyAction] = []
        coordinator.performOverride = { performed.append($0) }
        var waits: [() -> Void] = []
        coordinator.deferDrainOverride = { waits.append($0) }

        let now = ProcessInfo.processInfo.systemUptime

        // Toggle A reaches main with no keystroke handled yet, so rather than run
        // it waits for keys that might still be in flight.
        requestOffMain(at: [now + 10], on: coordinator)
        await mainQueueTurn()
        #expect(performed.isEmpty, "A waits for keys pressed before it")
        #expect(waits.count == 1, "and its wait is the one now pending")

        // A key pressed just after A arrives and runs A itself. A's wait is over —
        // but the wait is still pending, with nothing left of A to run.
        coordinator.applyPendingKeyActions(before: now + 11)
        #expect(performed == [.toggle(.customKey)])

        // Toggle B is pressed while a key pressed BEFORE it is still on its way to
        // IMK, so B starts a wait of its own.
        requestOffMain(at: [now + 60], on: coordinator)
        await mainQueueTurn()
        #expect(waits.count == 2)
        #expect(performed == [.toggle(.customKey)], "B waits too")

        // A's orphaned wait ends. A wait that drained the whole queue would take B
        // with it, giving B none of its own — the reordering this exists to
        // prevent, arrived at from the other side.
        waits[0]()
        #expect(performed == [.toggle(.customKey)],
                "B ran early, carried by the earlier toggle's wait")

        // B's own wait ends, and only then does B run.
        waits[1]()
        #expect(performed == [.toggle(.customKey), .toggle(.customKey)])
        #expect(coordinator.pendingActionCount == 0, "nothing is stuck")
    }

    @Test("A toggle no keystroke follows does not stay pending")
    func pendingToggleDrainsWithoutAKeystroke() async {
        let coordinator = InputModeCoordinator.shared
        coordinator.applyPendingKeyActions()
        // Pressed later than any key handled so far, so the queue is waiting for a
        // key that will never arrive — a shortcut field, a non-text view, a host
        // that forwards nothing to IMK. That wait has to be bounded, or the toggle
        // is lost until the user types somewhere else.
        requestOffMain(at: [ProcessInfo.processInfo.systemUptime + 60])
        #expect(coordinator.pendingActionCount == 1)

        var drained = false
        for _ in 0..<40 where !drained {
            try? await Task.sleep(for: .milliseconds(50))
            drained = coordinator.pendingActionCount == 0
        }
        #expect(drained, "the queue ran on its own, with no keystroke to carry it")
    }

    @Test("Hanja and toggle run in the order they were pressed, cut off by the key")
    func hanjaIsOrderedWithToggles() {
        let coordinator = InputModeCoordinator.shared
        coordinator.applyPendingKeyActions()
        var performed: [InputModeCoordinator.KeyAction] = []
        coordinator.performOverride = { performed.append($0) }
        defer { coordinator.performOverride = nil }

        // Hanja at 10, toggle at 30, recorded off main like the event tap does.
        let done = DispatchSemaphore(value: 0)
        Thread {
            coordinator.requestHanjaLookup(eventTime: 10)
            coordinator.requestToggle(source: .customKey, eventTime: 30)
            done.signal()
        }.start()
        done.wait()

        // A key typed at 20 runs the Hanja lookup — in the mode it was pressed
        // in — and leaves the later toggle alone.
        coordinator.applyPendingKeyActions(before: 20)
        #expect(performed == [.hanja])
        coordinator.applyPendingKeyActions()
        #expect(performed == [.hanja, .toggle(.customKey)])
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

    @Test("A withdrawn report is not waited for")
    func withdrawnReport() {
        var filter = SystemModeEchoFilter()
        filter.expect(.english, at: 0)
        filter.withdrawLatest()
        let echo = filter.consumeEcho(of: .english, at: 0.05)
        #expect(!echo)
    }

    @Test("After a reset, a real selection is never taken for an echo")
    func resetRetiresReports() {
        var filter = SystemModeEchoFilter()
        filter.expect(.english, at: 0)      // its echo never arrives
        filter.reset()                      // the user then selects Korean for real
        let echo = filter.consumeEcho(of: .english, at: 0.3)
        #expect(!echo, "a later real English selection must apply")
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

private final class ToggleCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
