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
        wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(200)) }
    ) async throws -> Bool {
        try Task.checkCancellation()
        switch result {
        case .failed: return false
        case .removed, .alreadyAbsent: break
        }

        // Check immediately, then allow up to three seconds for TIS propagation.
        // Task.sleep uses a monotonic clock; changing wall time cannot extend this.
        if await isDisabled() { return true }
        for _ in 0..<15 {
            try await wait()
            try Task.checkCancellation()
            if await isDisabled() { return true }
        }
        return false
    }
}
