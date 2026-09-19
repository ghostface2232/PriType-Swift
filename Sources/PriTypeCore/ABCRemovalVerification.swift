import Foundation

/// A preference write and a live input-source change are separate operations.
/// The initial removal and a retry must use exactly the same success criterion.
///
/// `isDisabled` must not consult this process's own TIS view: HIToolbox never
/// refreshes it after a preference write, so it would report "still enabled"
/// forever (see `ABCLayoutStatusProbe`).
@MainActor
enum ABCRemovalVerification {
    static func confirm(
        result: InputSourceManager.ABCRemovalResult,
        isDisabled: () async -> Bool,
        wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(200)) },
        deadline: ContinuousClock.Instant = .now + .seconds(3)
    ) async throws -> Bool {
        try Task.checkCancellation()
        switch result {
        case .failed: return false
        case .removed, .alreadyAbsent: break
        }

        // Check immediately, then allow up to three seconds for TIS propagation.
        // The deadline bounds the whole loop, not just the waits: each check
        // launches a probe process that may take seconds to answer, and fifteen
        // slow probes would keep the spinner up for over a minute. Monotonic, so
        // changing wall time cannot extend it.
        if await isDisabled() { return true }
        for _ in 0..<15 where ContinuousClock.now < deadline {
            try await wait()
            try Task.checkCancellation()
            if await isDisabled() { return true }
        }
        return false
    }
}
