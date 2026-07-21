import Foundation

/// One-way recovery policy for repeated CGEventTap disable events.
///
/// Before the threshold, CGEventTap remains the sole owner and is re-enabled. At the
/// threshold, ownership is handed to IOKit exactly once. Later disable notifications
/// from an already-stopped tap are ignored, so they cannot start duplicate fallbacks.
enum EventTapRecoveryAction: Equatable {
    case reenable(attempt: Int)
    case handoffToIOKit
    case ignore
}

struct EventTapFailureTracker {
    private(set) var disableCount = 0
    private(set) var hasHandedOff = false
    private var lastDisableTime: CFAbsoluteTime = 0

    let maxRetries: Int
    let stableResetInterval: CFAbsoluteTime

    init(maxRetries: Int = 3, stableResetInterval: CFAbsoluteTime = 60) {
        precondition(maxRetries > 0)
        self.maxRetries = maxRetries
        self.stableResetInterval = stableResetInterval
    }

    mutating func recordDisable(at time: CFAbsoluteTime) -> EventTapRecoveryAction {
        guard !hasHandedOff else { return .ignore }

        if time - lastDisableTime > stableResetInterval {
            disableCount = 0
        }
        lastDisableTime = time
        disableCount += 1

        if disableCount >= maxRetries {
            hasHandedOff = true
            return .handoffToIOKit
        }
        return .reenable(attempt: disableCount)
    }

    mutating func reset() {
        disableCount = 0
        hasHandedOff = false
        lastDisableTime = 0
    }
}
