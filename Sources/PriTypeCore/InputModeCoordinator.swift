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

    /// Toggles requested off the main thread that have not been applied yet.
    ///
    /// The key monitor runs on its own thread, so a toggle is recorded here the
    /// moment its key is seen, before the hop to main. The keystroke typed right
    /// after the toggle travels host → IMK → `handle()` on main, and nothing orders
    /// that message against the hop. `handle()` therefore drains this list before
    /// composing, which makes "the first key after a toggle is already in the new
    /// mode" a property of the code rather than of queue timing.
    private let pendingToggles = OSAllocatedUnfairLock<[ToggleSource]>(initialState: [])

    private init() {}

    /// Request a toggle. Callable from any thread: off main it records the toggle
    /// and applies it on main, or earlier if a keystroke reaches `handle()` first.
    public func requestToggle(source: ToggleSource) {
        guard Thread.isMainThread else {
            pendingToggles.withLock { $0.append(source) }
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
    public func applyPendingToggles() {
        let sources = pendingToggles.withLock { pending -> [ToggleSource] in
            defer { pending.removeAll() }
            return pending
        }
        for source in sources {
            performToggle(source: source)
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

/// A mode notification received before its controller owns the engine is only
/// valid until another explicit mode selection supersedes it.
struct DeferredInputMode {
    let mode: InputMode
    let revision: UInt64

    func resolve(currentRevision: UInt64) -> InputMode? {
        revision == currentRevision ? mode : nil
    }
}
