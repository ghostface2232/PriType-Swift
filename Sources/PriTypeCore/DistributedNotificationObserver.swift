import Foundation

/// Observes a distributed notification even while PriType is not the active app.
///
/// AppKit holds distributed notifications back from an app that has been active
/// and no longer is — the default suspension behavior, and all the block-based
/// `addObserver(forName:object:queue:using:)` offers. PriType is a background
/// app until its Settings window opens and activates it, so after one visit to
/// Settings every input-source announcement would wait for the next one. These
/// observers ask for immediate delivery instead.
final class DistributedNotificationObserver: NSObject, @unchecked Sendable {
    private let handler: @Sendable () -> Void

    /// `handler` runs on the main queue.
    init(name: String, handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(received(_:)),
            name: Notification.Name(name),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func received(_ notification: Notification) {
        DispatchQueue.main.async(execute: handler)
    }
}
