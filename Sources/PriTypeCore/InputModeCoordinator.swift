import Foundation
import os

/// Coordinates PriType-owned language toggles.
///
/// Custom toggle keys must not select the real macOS ABC input source. Doing so
/// hands the active text session to another input source and reintroduces
/// first-key races. This coordinator keeps the custom toggle path inside
/// PriType: key monitor -> controller -> composer.
public final class InputModeCoordinator: @unchecked Sendable {
    public static let shared = InputModeCoordinator()

    public enum ToggleSource: Sendable {
        case customKey
        case iokitFallback

        /// Whether the caller already consulted `ToggleExclusionPolicy` at key time.
        ///
        /// Both monitors decide before consuming the event, then hop to main. Asking
        /// again here would re-decide against a *newer* frontmost app: if an excluded
        /// app activates during that hop, the key has already been swallowed by the
        /// tap and dropping the toggle too leaves the user with nothing — the one
        /// outcome neither policy wants. A future non-key caller gets the check.
        var isGatedAtKeyTime: Bool {
            switch self {
            case .customKey, .iokitFallback: return true
            }
        }
    }

    /// A key action seen by a key monitor, waiting to run on main.
    enum KeyAction: Equatable {
        case toggle(ToggleSource)
        case hanja
    }

    private struct PendingAction {
        let action: KeyAction
        /// When the key was pressed, on `NSEvent.timestamp`'s clock.
        let eventTime: TimeInterval
    }

    /// Key actions requested off the main thread that have not run yet.
    ///
    /// The key monitor runs on its own thread, so an action is recorded here the
    /// moment its key is seen, before the hop to main. Keystrokes travel
    /// host → IMK → `handle()` on main, and nothing orders that message against the
    /// hop in either direction. `handle()` therefore runs exactly the actions
    /// pressed before its key: a key typed after the toggle lands in the new mode,
    /// one typed just before it — still in flight to IMK — stays in the old one,
    /// and a key typed after the Hanja key reaches the candidate window.
    ///
    /// Toggles and Hanja lookups share this one list because their order matters
    /// to each other: Hanja then toggle must look up in the mode it was pressed in.
    private let pendingActions = OSAllocatedUnfairLock<[PendingAction]>(initialState: [])

    /// The app has exactly one of these — `shared`. Tests make their own, because
    /// the ordering this class implements is about timers and threads, and a test
    /// that has to suspend to observe a timer cannot also share its queue with
    /// every other suite running alongside it.
    init() {}

    /// Request a toggle. Callable from any thread: off main it records the toggle
    /// and applies it on main, or earlier if a later keystroke reaches `handle()`
    /// first. `eventTime` is when the toggle key was pressed (`NSEvent.timestamp`'s
    /// clock); without it the toggle counts as pressed now.
    public func requestToggle(source: ToggleSource, eventTime: TimeInterval? = nil) {
        request(.toggle(source), eventTime: eventTime)
    }

    /// Request a Hanja lookup, ordered with toggles and keystrokes exactly like
    /// `requestToggle`.
    public func requestHanjaLookup(eventTime: TimeInterval? = nil) {
        request(.hanja, eventTime: eventTime)
    }

    private func request(_ action: KeyAction, eventTime: TimeInterval?) {
        // A press time is what makes an action orderable against keystrokes, and a
        // key monitor always has one. Which thread it calls from does not decide
        // this: the event tap runs on its own thread, while the IOKit fallback's
        // HID callback runs on the main run loop, and both are watching the same
        // physical keyboard with the same need to stay in order with what is typed.
        if let eventTime {
            pendingActions.withLock {
                $0.append(PendingAction(action: action, eventTime: eventTime))
            }
            if Thread.isMainThread {
                drainAfterKeyMonitorHop(pressedAt: eventTime)
            } else {
                DispatchQueue.main.async {
                    self.drainAfterKeyMonitorHop(pressedAt: eventTime)
                }
            }
            return
        }

        // No press time: there is nothing to order this against, so it runs as
        // soon as it reaches main, after everything recorded before it.
        guard Thread.isMainThread else {
            let pending = PendingAction(
                action: action,
                eventTime: ProcessInfo.processInfo.systemUptime
            )
            pendingActions.withLock { $0.append(pending) }
            DispatchQueue.main.async {
                self.applyPendingKeyActions()
            }
            return
        }

        // Actions recorded earlier must run before this one.
        applyPendingKeyActions()
        perform(action)
    }

    /// How long an action that reached main waits for a key pressed BEFORE it that
    /// has not arrived yet.
    ///
    /// This bounds the wait; it does not order the two producers. Nothing can: the
    /// key monitor's hop and the host → IMK → `handle()` message are independent,
    /// and "no earlier key is still in flight" is not a question either side can
    /// answer. What the wait buys is that the common case — an IMK message already
    /// on its way — resolves itself, because a key that does arrive drains the queue
    /// with its own press time (`applyPendingKeyActions(before:)`) and lands in the
    /// mode it was pressed in. What it costs is nothing in typing latency: the very
    /// next keystroke applies the action ahead of itself, so the wait is only ever
    /// paid by an action no key follows.
    ///
    /// The bound is what keeps a host that never forwards a key to IMK (a shortcut
    /// field, a non-text view) from leaving the toggle pending forever.
    static let inFlightKeyGrace: TimeInterval = 0.03

    /// Hands the deferred drain over instead of scheduling it (tests only).
    ///
    /// What a deferred drain REACHES is the behaviour worth testing, and it has
    /// nothing to do with how long the wait is. A test that waits out a real timer
    /// is testing the machine it runs on as much as the code — a loaded CI runner
    /// spent a whole grace period inside one `await` and failed a check that had
    /// nothing to do with timing. With this the work is fired by hand, in the order
    /// the test chooses, and the result is the same on any machine.
    var deferDrainOverride: ((@escaping @Sendable () -> Void) -> Void)?

    /// The press time of the newest keystroke that has reached `handle()`.
    /// Main thread only, like everything it is compared against.
    private var lastHandledKeyTime: TimeInterval = -.infinity

    /// An action has reached main from the key-monitor thread. Run it now if every
    /// key pressed before it has already been handled; otherwise give those keys
    /// the bounded moment above to arrive on their own.
    ///
    /// Either way the drain reaches only as far as THIS action. A drain that ran
    /// the whole queue would carry later actions with it, and those are the ones
    /// with keys still in flight: an action already run by a keystroke leaves its
    /// timer armed, and that timer firing would apply an action pressed after it
    /// with none of the wait this exists to give — the reordering it was meant to
    /// prevent, arrived at from the other side.
    private func drainAfterKeyMonitorHop(pressedAt eventTime: TimeInterval) {
        // `runPendingActions(before:)` runs what was pressed strictly earlier, and
        // this action is the one being waited on, so the bound includes it.
        let throughThisAction = eventTime.nextUp
        guard lastHandledKeyTime < eventTime else {
            runPendingActions(before: throughThisAction)
            return
        }
        let drain: @Sendable () -> Void = { [self] in
            runPendingActions(before: throughThisAction)
        }
        guard let deferDrainOverride else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.inFlightKeyGrace) { drain() }
            return
        }
        deferDrainOverride(drain)
    }

    /// Run key actions recorded off the main thread, in order. Main thread only.
    /// A no-op when nothing is pending, so every caller can invoke it freely.
    ///
    /// - Parameter keyTime: the `NSEvent.timestamp` of a keystroke about to be
    ///   handled. Only actions pressed before it run; later ones stay pending for
    ///   their own hop. `nil` runs everything.
    public func applyPendingKeyActions(before keyTime: TimeInterval? = nil) {
        // Only a real keystroke moves this: it is the evidence that everything
        // pressed before it has arrived. An action's own drain bound must not count,
        // or one toggle reaching main would tell the next one that the keys between
        // them are all in.
        if let keyTime { lastHandledKeyTime = max(lastHandledKeyTime, keyTime) }
        runPendingActions(before: keyTime)
    }

    /// Run the due prefix of the queue without recording anything about keystrokes.
    private func runPendingActions(before keyTime: TimeInterval?) {
        let due = pendingActions.withLock { pending -> [PendingAction] in
            guard let keyTime else {
                defer { pending.removeAll() }
                return pending
            }
            // Pending actions arrive in key order, so the due ones are a prefix.
            let count = pending.prefix { $0.eventTime < keyTime }.count
            defer { pending.removeFirst(count) }
            return Array(pending.prefix(count))
        }
        for pending in due {
            perform(pending.action)
        }
    }

    /// Number of recorded key actions still waiting for main (for tests).
    var pendingActionCount: Int {
        pendingActions.withLock { $0.count }
    }

    /// Replaces running actions, so tests can observe their order (tests only).
    var performOverride: ((KeyAction) -> Void)?

    private func perform(_ action: KeyAction) {
        if let performOverride {
            performOverride(action)
            return
        }
        switch action {
        case .toggle(let source):
            performToggle(source: source)
        case .hanja:
            PriTypeInputController.sharedComposer.triggerHanjaLookup()
        }
    }

    private func performToggle(source: ToggleSource) {
        guard !ConfigurationManager.shared.capsLockInputSourceSwitchEnabled else {
            DebugLogger.log("InputModeCoordinator: ignored custom toggle because Caps Lock owns switching")
            return
        }

        // Backstop for callers that did not already gate at key time, so the user's
        // exclusion list cannot be bypassed by a future entry point.
        guard source.isGatedAtKeyTime || !ToggleExclusionPolicy.shared.isTogglePaused else {
            DebugLogger.log("InputModeCoordinator: ignored custom toggle because the frontmost app is excluded")
            return
        }

        guard let controller = PriTypeInputController.sharedController else {
            DebugLogger.log("InputModeCoordinator: ignored custom toggle because no active controller exists")
            return
        }

        controller.performPriTypeModeTransition(source: source)
    }
}

/// Recognizes macOS echoing back a mode PriType reported itself.
///
/// A custom toggle switches the composer at once and then reports the result
/// with `TISSelectInputSource`, which macOS answers later with `setValue`. With two
/// quick toggles (K→E→K) the echo of the first report can arrive after the
/// second toggle, and applying it would flip the composer back to English until
/// the second echo lands — keys typed in between come out in the wrong mode.
/// Echoes carry no information the composer lacks, so they are consumed instead.
///
/// A report whose echo never comes (the selection only moved the menu-bar icon,
/// or failed) expires, so it cannot swallow a real selection later.
struct SystemModeEchoFilter {
    static let lifetime: TimeInterval = 1.0

    private var outstanding: [(mode: InputMode, deadline: TimeInterval)] = []

    /// Record a report that is about to be sent.
    mutating func expect(_ mode: InputMode, at now: TimeInterval) {
        outstanding.append((mode, now + Self.lifetime))
    }

    /// Take back the latest report, whose selection failed and so will not echo.
    mutating func withdrawLatest() {
        _ = outstanding.popLast()
    }

    /// Forget every report. A real selection supersedes them: the echoes still
    /// in flight describe a state the user has since moved away from, and one
    /// that never arrives must not swallow the user's next selection.
    mutating func reset() {
        outstanding.removeAll()
    }

    /// Whether `mode` is the echo of a report. Consumes it and every older report,
    /// since echoes arrive in order and the system may coalesce them.
    mutating func consumeEcho(of mode: InputMode, at now: TimeInterval) -> Bool {
        outstanding.removeAll { $0.deadline < now }
        guard let index = outstanding.firstIndex(where: { $0.mode == mode }) else { return false }
        outstanding.removeFirst(index + 1)
        return true
    }
}

/// A mode notification received before its controller owns the engine is only
/// valid until another explicit mode selection supersedes it.
struct DeferredInputMode {
    let mode: InputMode
    let revision: UInt64

    func resolve(currentRevision: UInt64) -> InputMode? {
        revision == currentRevision ? mode : nil
    }
}
