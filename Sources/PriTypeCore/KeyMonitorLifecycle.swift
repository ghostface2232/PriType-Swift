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

/// Device-specific masks from IOKit hidsystem/IOLLEvent.h. Aggregate Command
/// cannot distinguish releasing Right Command while Left Command stays down.
enum ModifierKeyState {
    static func mask(for key: Int64) -> UInt64 {
        switch key {
        case 54: return 0x10
        case 55: return 0x08
        case 61: return 0x40
        case 58: return 0x20
        case 62: return 0x2000
        case 59: return 0x01
        case 56: return 0x02
        case 60: return 0x04
        default: return 0
        }
    }

    static func isDown(_ key: Int64, flags: UInt64) -> Bool {
        flags & mask(for: key) != 0
    }

    static func opposite(_ key: Int64) -> Int64 {
        switch key {
        case 54: return 55
        case 55: return 54
        case 61: return 58
        case 58: return 61
        case 62: return 59
        case 59: return 62
        case 56: return 60
        case 60: return 56
        default: return -1
        }
    }
}
