import Foundation
import PriTypeCore

// The unattended checks: everything a real machine can answer without a person
// pressing anything. Each one drives the same type the app drives, so a check
// that passes says something about the shipped code rather than about a copy of
// its formula kept next to it.

/// Accessibility, which `CGEvent.tapCreate` requires.
public struct AccessibilityCheck: DeviceCheck {
    public let id = "accessibility"
    public let title = "Accessibility is granted, so the event tap may be created"

    public init() {}

    public func run() -> DeviceCheckFinding {
        guard IOKitManager.hasAccessibilityPermission() else {
            return .failed("AXIsProcessTrusted() is false for this binary",
                           evidence: "grant it in System Settings › Privacy & Security › Accessibility")
        }
        return .passed("AXIsProcessTrusted() is true")
    }
}

/// Input Monitoring, which `IOHIDManager` requires and the event tap does not.
public struct InputMonitoringCheck: DeviceCheck {
    public let id = "input-monitoring"
    public let title = "Input Monitoring is granted, so the IOKit fallback may read keyboards"

    public init() {}

    public func run() -> DeviceCheckFinding {
        switch IOKitManager.inputMonitoringAccess() {
        case .granted:
            return .passed("IOHIDCheckAccess reports granted")
        case .denied:
            return .failed("Input Monitoring is denied for this binary",
                           evidence: "only System Settings › Privacy & Security › Input Monitoring can undo a denial")
        case .notDetermined:
            // Prompting here would change the machine mid-measurement, and the
            // prompt names this binary rather than PriType, which is not the
            // grant the user needs anyway.
            return .skipped("this binary has never been granted Input Monitoring",
                            evidence: "add it in System Settings › Privacy & Security › Input Monitoring")
        }
    }
}

/// Whether the system will actually hand this process a session event tap.
///
/// The in-process suite drives `handleEvent` directly and never creates a tap,
/// so `tapCreate` returning nil — the failure that sends a real install onto the
/// IOKit fallback — is invisible to it.
public struct EventTapCheck: DeviceCheck {
    public let id = "event-tap"
    public let title = "A session event tap can be created, enabled and serviced"

    public init() {}

    public func run() -> DeviceCheckFinding {
        guard IOKitManager.hasAccessibilityPermission() else {
            return .skipped("Accessibility is not granted for this binary")
        }
        let tap = RightCommandSuppressor.shared
        guard !tap.isRunning else {
            return .skipped("this process already holds a tap")
        }
        // The tap is live for the length of this check, and the configured toggle
        // key is suppressed while it is. Nothing handles a toggle here, so a key
        // pressed inside this window is swallowed; it is milliseconds long and
        // nothing about it survives the call.
        guard tap.start() else {
            return .failed("CGEvent.tapCreate or its run-loop thread did not come up")
        }
        defer { tap.stop() }
        guard tap.isRunning else {
            return .failed("the tap was created but CGEvent.tapIsEnabled reports it disabled")
        }
        return .passed("tap created, enabled, and serviced by its own run loop")
    }
}

/// Whether `IOHIDManager` will open the keyboards in this process.
///
/// This is the precondition the IOKit fallback lives or dies by, and the one the
/// suite cannot reach: `IOHIDManagerOpen` either succeeds against real devices
/// or it does not. Its two interesting failures look alike as numbers and have
/// nothing in common as remedies, so they are reported apart.
public struct HIDOpenCheck: DeviceCheck {
    public let id = "hid-open"
    public let title = "IOHIDManager opens the keyboards, so the fallback can run"

    public init() {}

    public func run() -> DeviceCheckFinding {
        let manager = IOKitManager.shared
        switch manager.start(promptForInputMonitoring: false) {
        case .success:
            manager.stop()
            return .passed("IOHIDManagerOpen succeeded and the keyboards were released again")
        case .failure(.keyboardsExclusivelyOwned(let code)):
            // The installed input method is holding them, which is the normal
            // state of a working Mac — and the reason this cannot be a failure.
            return .skipped("another process owns the keyboards; quit PriTypeV2 and re-run",
                            evidence: "IOReturn \(code) (kIOReturnExclusiveAccess)")
        case .failure(.inputMonitoringDenied):
            return .failed("Input Monitoring is denied, so the fallback can never read a key")
        case .failure(.inputMonitoringNotDetermined):
            return .skipped("this binary has never been granted Input Monitoring")
        case .failure(.openFailed(let code)):
            return .failed("IOHIDManagerOpen failed", evidence: "IOReturn \(code)")
        }
    }
}

/// Whether the fresh-process input-source probe still answers.
///
/// HIToolbox caches the enabled-source list per process and, since macOS 26,
/// never refreshes it. Re-launching the executable is the only way PriType can
/// observe the list it just changed, so the mechanism working is a load-bearing
/// fact about this machine — and it is a fact no in-process test can establish,
/// by construction.
public struct FreshProcessProbeCheck: DeviceCheck {
    public let id = "fresh-process-probe"
    public let title = "The input-source probe answers from a freshly launched process"

    public init() {}

    public func run() -> DeviceCheckFinding {
        guard let answer = ABCLayoutStatusProbe.answerFromFreshProcess() else {
            return .failed("the child process produced no usable answer",
                           evidence: "re-exec of \(Bundle.main.executableURL?.lastPathComponent ?? "this binary") "
                                   + "with \(ABCLayoutStatusProbe.argument)")
        }
        // Either answer is a pass: what is under test is the mechanism, not the
        // machine's current layout list.
        return .passed("probe answered: ABC layout is \(answer ? "disabled" : "enabled")")
    }
}

/// Whether the installed PriType is actually enabled as an input source.
///
/// A build can be installed, signed and launchable while macOS has it listed and
/// switched off, in which case nothing else in this report matters.
public struct InputSourceRegistrationCheck: DeviceCheck {
    public let id = "input-source-registered"
    public let title = "PriType is enabled in Text Input Sources"

    /// The prefix both PriType input modes share.
    static let bundlePrefix = "com.pritype.inputmethod.v2"

    public init() {}

    public func run() -> DeviceCheckFinding {
        guard let ids = InputSourceManager.shared.enabledKeyboardInputSourceIDs() else {
            return .failed("TIS would not list the enabled keyboard input sources")
        }
        let mine = ids.filter { $0.hasPrefix(Self.bundlePrefix) }
        guard !mine.isEmpty else {
            return .failed("no enabled input source carries the PriType bundle id",
                           evidence: "enabled: \(ids.joined(separator: ", "))")
        }
        return .passed("enabled: \(mine.joined(separator: ", "))")
    }
}

/// The unattended checks, in the order they are worth reading.
public let unattendedChecks: [any DeviceCheck] = [
    AccessibilityCheck(),
    InputMonitoringCheck(),
    InputSourceRegistrationCheck(),
    EventTapCheck(),
    HIDOpenCheck(),
    FreshProcessProbeCheck(),
]
