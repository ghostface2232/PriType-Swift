import Foundation

/// Starts the toggle/Hanja key monitors and hands them over to each other.
///
/// The only place either monitor is started from. Launch and the settings
/// window's Accessibility button both come here, so every start of the event
/// tap wires the same callbacks — including `onTapFailed`, without which a tap
/// that later dies repeatedly would leave the toggle key dead instead of
/// handing over to IOKit.
@MainActor
public enum KeyMonitors {
    /// Waits for Accessibility when it is missing at start.
    private static var accessibilityPoll: Timer?
    /// Waits for Input Monitoring when the IOKit fallback needs it.
    private static var inputMonitoringPoll: Timer?
    /// Brings the event tap back after a handoff to IOKit.
    private static var tapRetry: Timer?

    /// How long the IOKit fallback runs before the event tap is tried again.
    static let tapRetryInterval: TimeInterval = 60

    /// Start the event tap, or IOKit when the tap cannot run. Without
    /// Accessibility, wait for the grant and start then. Safe to call again.
    public static func start() {
        guard IOKitManager.hasAccessibilityPermission() else {
            waitForAccessibility()
            return
        }
        accessibilityPoll?.invalidate()
        accessibilityPoll = nil

        let tap = RightCommandSuppressor.shared
        tap.onToggle = { eventTime in
            InputModeCoordinator.shared.requestToggle(source: .customKey, eventTime: eventTime)
        }
        tap.onHanjaLookup = { eventTime in
            InputModeCoordinator.shared.requestHanjaLookup(eventTime: eventTime)
        }
        tap.onCommandDown = { eventTime in
            InputModeCoordinator.shared.requestShortcutCommit(eventTime: eventTime)
        }
        tap.onKeyPassed = { keyCode, eventTime in
            InputModeCoordinator.shared.notePassedKey(keyCode: keyCode, at: eventTime)
        }
        // Delivered on main, after the tap has removed itself.
        tap.onTapFailed = {
            MainActor.assumeIsolated {
                DebugLogger.log("CGEventTap failed repeatedly — activating IOKit fallback")
                startIOKitFallback()
            }
        }
        if tap.start() {
            DebugLogger.log("Primary: CGEventTap started")
        } else {
            DebugLogger.log("Primary: CGEventTap FAILED - IOKit taking over")
            startIOKitFallback()
        }
    }

    /// Try the event tap again after a while; `start()` hands back to IOKit if it
    /// still cannot run. One pending retry at a time.
    private static func retryTapLater() {
        tapRetry?.invalidate()
        let timer = Timer(timeInterval: tapRetryInterval, repeats: false) { _ in
            MainActor.assumeIsolated {
                tapRetry = nil
                guard !RightCommandSuppressor.shared.isRunning else { return }
                DebugLogger.log("Retrying the event tap after an IOKit handoff")
                start()
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        tapRetry = timer
    }

    /// Poll for the grant: there is no notification for it. One poll at a time.
    private static func waitForAccessibility() {
        guard accessibilityPoll == nil else { return }
        accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard IOKitManager.hasAccessibilityPermission() else { return }
                DebugLogger.log("Accessibility granted — starting key monitoring")
                start()
            }
        }
    }

    /// Hand key monitoring to IOKit. It needs Input Monitoring; when that is
    /// missing, `start()` prompts (first time only) and this waits for the grant
    /// instead of leaving the toggle and Hanja keys dead until the next launch.
    ///
    /// Never for good: the tap is retried after `tapRetryInterval`. The tap is
    /// handed off when the system keeps disabling it for timeouts, and those are
    /// stalls of the whole machine (wake, memory pressure) — the callback itself
    /// takes well under a microsecond. The fallback cannot swallow keys (Right ⌘
    /// + C both toggles and copies) and needs Input Monitoring, which is rarely
    /// granted, so it is a bridge over the stall, not a new home.
    private static func startIOKitFallback() {
        retryTapLater()
        IOKitManager.shared.onRightCommandToggle = { eventTime in
            InputModeCoordinator.shared.requestToggle(source: .iokitFallback, eventTime: eventTime)
        }
        IOKitManager.shared.onRightOptionHanja = { eventTime in
            InputModeCoordinator.shared.requestHanjaLookup(eventTime: eventTime)
        }
        guard !IOKitManager.shared.start() else { return }
        DebugLogger.log("IOKit fallback waiting for Input Monitoring permission")
        // Replaced, never stacked: the tap can fail again after a restart.
        inputMonitoringPoll?.invalidate()
        inputMonitoringPoll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
            // The event tap may have come back (e.g. Accessibility re-granted
            // from Settings); only one monitor may own the keys.
            if RightCommandSuppressor.shared.isRunning {
                timer.invalidate()
                return
            }
            guard IOKitManager.inputMonitoringAccess() == .granted else { return }
            timer.invalidate()
            let started = IOKitManager.shared.start()
            DebugLogger.log("Input Monitoring granted — IOKit fallback start = \(started)")
        }
    }
}
