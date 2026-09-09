import Foundation

/// Only one settings row may own either producer (tap or local monitor).
/// Ending an old row must not tear down a newer row's global callback.
@MainActor
final class KeyRecordingSessions {
    static let shared = KeyRecordingSessions()
    private var owner: UUID?
    private var cancelOwner: (() -> Void)?

    func begin(owner newOwner: UUID, cancel: @escaping () -> Void) {
        let cancelPrevious = cancelOwner
        owner = nil
        cancelOwner = nil
        cancelPrevious?()
        owner = newOwner
        cancelOwner = cancel
    }

    func owns(_ candidate: UUID) -> Bool { owner == candidate }

    @discardableResult
    func end(owner candidate: UUID) -> Bool {
        guard owns(candidate) else { return false }
        owner = nil
        cancelOwner = nil
        return true
    }
}
