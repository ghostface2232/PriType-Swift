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

    private struct PendingToggle {
        let source: ToggleSource
        /// When the toggle key was pressed, on `NSEvent.timestamp`'s clock.
        let eventTime: TimeInterval
    }

    /// Toggles requested off the main thread that have not been applied yet.
    ///
    /// The key monitor runs on its own thread, so a toggle is recorded here the
    /// moment its key is seen, before the hop to main. Keystrokes travel
    /// host → IMK → `handle()` on main, and nothing orders that message against the
    /// hop in either direction. `handle()` therefore applies exactly the toggles
    /// pressed before its key: a key typed after the toggle lands in the new mode,
    /// and one typed just before it — still in flight to IMK — stays in the old one.
    private let pendingToggles = OSAllocatedUnfairLock<[PendingToggle]>(initialState: [])

    private init() {}

    /// Request a toggle. Callable from any thread: off main it records the toggle
    /// and applies it on main, or earlier if a later keystroke reaches `handle()`
    /// first. `eventTime` is when the toggle key was pressed (`NSEvent.timestamp`'s
    /// clock); without it the toggle counts as pressed now.
    public func requestToggle(source: ToggleSource, eventTime: TimeInterval? = nil) {
        guard Thread.isMainThread else {
            let toggle = PendingToggle(
                source: source,
                eventTime: eventTime ?? ProcessInfo.processInfo.systemUptime
            )
            pendingToggles.withLock { $0.append(toggle) }
            DispatchQueue.main.async {
                self.applyPendingToggles()
            }
            return
        }

        // Toggles recorded earlier must land before this one.
        applyPendingToggles()
        performToggle(source: source)
    }

    /// Apply toggles recorded off the main thread, in order. Main thread only.
    /// A no-op when nothing is pending, so every caller can invoke it freely.
    ///
    /// - Parameter keyTime: the `NSEvent.timestamp` of a keystroke about to be
    ///   handled. Only toggles pressed before it are applied; later ones stay
    ///   pending for their own hop. `nil` applies everything.
    public func applyPendingToggles(before keyTime: TimeInterval? = nil) {
        let due = pendingToggles.withLock { pending -> [PendingToggle] in
            guard let keyTime else {
                defer { pending.removeAll() }
                return pending
            }
            // Pending toggles arrive in key order, so the due ones are a prefix.
            let count = pending.prefix { $0.eventTime < keyTime }.count
            defer { pending.removeFirst(count) }
            return Array(pending.prefix(count))
        }
        for toggle in due {
            performToggle(source: toggle.source)
        }
    }

    /// Number of recorded toggles still waiting for main (for tests).
    var pendingToggleCount: Int {
        pendingToggles.withLock { $0.count }
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
