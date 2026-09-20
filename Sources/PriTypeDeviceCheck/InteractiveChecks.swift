import Foundation
import os
import PriTypeCore

// The checks a person has to take part in.
//
// These exist because the keyboard is the one part of this program that cannot
// be simulated into a real answer. `IOHIDManager` is fed by the HID driver
// stack, so an event posted with `CGEventPost` or `osascript` never reaches it
// at all — the fallback path has no synthetic form. The event tap does see
// posted events, which is worse than not seeing them: a run driven by a script
// would report the toggle key working without a finger having touched it. So the
// tap check records where its event came from and refuses a posted one.

/// Somewhere for a callback on another thread to leave its answer.
private final class Latch<Value: Sendable>: Sendable {
    private let storage = OSAllocatedUnfairLock<Value?>(initialState: nil)
    private let arrived = DispatchSemaphore(value: 0)

    /// Records the first value only: a second toggle must not overwrite the one
    /// being waited on.
    func signal(_ value: Value) {
        let isFirst = storage.withLock { state -> Bool in
            guard state == nil else { return false }
            state = value
            return true
        }
        if isFirst { arrived.signal() }
    }

    /// The value, or nil if none arrived in time.
    func wait(timeout: TimeInterval) -> Value? {
        _ = arrived.wait(timeout: .now() + timeout)
        return storage.withLock { $0 }
    }
}

/// How the operator is asked for a key press, and how long the check waits.
public struct OperatorPrompt: Sendable {
    public var timeout: TimeInterval
    public var say: @Sendable (String) -> Void

    public init(timeout: TimeInterval = 15,
                say: @escaping @Sendable (String) -> Void = { message in
                    print(message)
                    fflush(stdout)
                }) {
        self.timeout = timeout
        self.say = say
    }
}

/// The toggle key, pressed by a person, through the CGEventTap path.
public struct PhysicalToggleTapCheck: DeviceCheck {
    public let id = "physical-toggle-tap"
    public let title = "A physically pressed toggle key reaches the event tap"
    public let requiresOperator = true

    let prompt: OperatorPrompt

    public init(prompt: OperatorPrompt = OperatorPrompt()) {
        self.prompt = prompt
    }

    public func run() -> DeviceCheckFinding {
        guard IOKitManager.hasAccessibilityPermission() else {
            return .skipped("Accessibility is not granted for this binary")
        }
        let tap = RightCommandSuppressor.shared
        guard !tap.isRunning else {
            return .skipped("this process already holds a tap")
        }

        if let reason = Self.toggleDisabledReason() {
            return .skipped(reason)
        }
        let latch = Latch<TimeInterval>()
        let binding = ConfigurationManager.shared.toggleKeyBinding
        tap.onToggle = { eventTime in latch.signal(eventTime) }
        defer {
            tap.stop()
            tap.onToggle = nil
        }
        guard tap.start() else {
            return .failed("the event tap did not come up")
        }

        prompt.say("  → press your toggle key (\(binding.displayName)) on the keyboard, "
                 + "within \(Int(prompt.timeout))s…")
        guard latch.wait(timeout: prompt.timeout) != nil else {
            return .failed("no toggle reached the tap in \(Int(prompt.timeout))s",
                           evidence: "bound to \(binding.displayName); a conflicting remapper "
                                   + "(Karabiner-Elements and the like) can consume it first")
        }
        // The callback carries only a time. Where the key came from is recorded by
        // the suppressor itself, from the event it actually processed.
        guard let provenance = tap.lastToggleProvenance else {
            return .failed("the tap reported a toggle but recorded no provenance for it")
        }
        guard provenance.isHardware else {
            return .failed("the toggle was posted by another process, not typed",
                           evidence: "event source pid \(provenance.sourcePID); "
                                   + "a posted key proves nothing about the hardware path")
        }
        return .passed("a hardware-sourced toggle (\(binding.displayName)) reached the tap")
    }
}

/// The toggle key, pressed by a person, through the IOKit fallback.
///
/// This is the path that has never had a verification route. It cannot be faked
/// from the outside — `IOHIDManager` reports hardware and nothing else — so a
/// pass here needs no provenance check: the only way to produce one is to press
/// the key.
public struct PhysicalToggleHIDCheck: DeviceCheck {
    public let id = "physical-toggle-hid"
    public let title = "A physically pressed toggle key reaches the IOKit fallback"
    public let requiresOperator = true

    let prompt: OperatorPrompt

    public init(prompt: OperatorPrompt = OperatorPrompt()) {
        self.prompt = prompt
    }

    public func run() -> DeviceCheckFinding {
        if let reason = Self.toggleDisabledReason() {
            return .skipped(reason)
        }
        let manager = IOKitManager.shared
        let latch = Latch<TimeInterval>()
        let binding = ConfigurationManager.shared.toggleKeyBinding
        manager.onRightCommandToggle = { eventTime in latch.signal(eventTime) }
        defer {
            manager.stop()
            manager.onRightCommandToggle = nil
        }

        switch manager.start(promptForInputMonitoring: false) {
        case .success:
            break
        case .failure(.keyboardsExclusivelyOwned(let code)):
            return .skipped(KeyboardOwners.currentAdvice(),
                            evidence: "IOReturn \(code) (kIOReturnExclusiveAccess)")
        case .failure(.inputMonitoringDenied):
            return .failed("Input Monitoring is denied, so the fallback can never read a key")
        case .failure(.inputMonitoringNotDetermined):
            return .skipped("this binary has never been granted Input Monitoring")
        case .failure(.openFailed(let code)):
            return .failed("IOHIDManagerOpen failed", evidence: "IOReturn \(code)")
        }

        prompt.say("  → press your toggle key (\(binding.displayName)) on the keyboard, "
                 + "within \(Int(prompt.timeout))s…")
        // `IOKitManager` schedules its HID source on the run loop of the thread
        // that started it and delivers the toggle on the main queue, so this
        // thread has to keep running its loop rather than block on the latch.
        guard waitSpinningRunLoop(for: latch, timeout: prompt.timeout) != nil else {
            return .failed("no toggle reached the IOKit fallback in \(Int(prompt.timeout))s",
                           evidence: "bound to \(binding.displayName); the key must be pressed on a "
                                   + "physical keyboard — a posted event never enters the HID stack")
        }
        return .passed("a hardware toggle (\(binding.displayName)) reached the fallback")
    }

    /// Run this thread's run loop until the latch has a value or time runs out.
    private func waitSpinningRunLoop<Value>(for latch: Latch<Value>,
                                            timeout: TimeInterval) -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = latch.wait(timeout: 0) { return value }
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
        }
        return latch.wait(timeout: 0)
    }
}

extension DeviceCheck {
    /// Why PriType's own toggle key is switched off right now, if it is.
    ///
    /// Both monitors ignore the custom toggle while macOS's Caps Lock
    /// input-source switch is on — by design, so the two cannot fight. Without
    /// this, that configuration produced "no toggle reached the tap", with
    /// evidence blaming a key remapper: a user with a normal setting told their
    /// install was broken, which is worse than no check at all.
    static func toggleDisabledReason() -> String? {
        guard ConfigurationManager.shared.capsLockInputSourceSwitchEnabled else { return nil }
        return "macOS's Caps Lock input-source switch is on, so PriType's toggle key is disabled"
    }
}

/// The checks that need a person, in the order they are worth running.
public func interactiveChecks(prompt: OperatorPrompt = OperatorPrompt()) -> [any DeviceCheck] {
    [
        PhysicalToggleTapCheck(prompt: prompt),
        PhysicalToggleHIDCheck(prompt: prompt),
    ]
}
