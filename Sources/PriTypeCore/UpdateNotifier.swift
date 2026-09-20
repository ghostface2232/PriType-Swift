import Foundation
import UserNotifications
import Cocoa

/// Manages update notifications using macOS UserNotification framework
///
/// `UpdateNotifier` handles:
/// - Deferring notification permission until an update notification is needed
/// - Sending local notifications when an update is available
/// - Handling notification click actions (opening the release page)
///
/// ## Usage
/// ```swift
/// await UpdateNotifier.shared.notifyUpdateAvailable(update)
/// ```
///
/// ## Thread Safety
/// This class is designed for main-thread use but async methods are safe from any context.
public final class UpdateNotifier: NSObject, @unchecked Sendable, UNUserNotificationCenterDelegate {
    
    // MARK: - Singleton
    
    public static let shared = UpdateNotifier()
    
    // MARK: - Constants
    
    private let categoryIdentifier = "PRITYPE_UPDATE"
    private let actionIdentifier = "DOWNLOAD_ACTION"
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
    }
    
    // MARK: - Setup
    
    /// Configure the notification center and register action categories.
    ///
    /// This intentionally does not request notification permission at startup.
    /// Permission is requested only when an update notification is about to be sent.
    ///
    /// Call this once during app startup (in `applicationDidFinishLaunching`)
    public func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        
        // Opens the update settings, where the release can be installed without
        // leaving the app.
        let downloadAction = UNNotificationAction(
            identifier: actionIdentifier,
            title: L10n.update.notificationAction,
            options: [.foreground]
        )
        
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [downloadAction],
            intentIdentifiers: [],
            options: []
        )
        
        center.setNotificationCategories([category])
    }
    
    // MARK: - Send Notification
    
    /// Post a local notification informing the user about an available update
    ///
    /// - Parameter update: The update information to display
    public func notifyUpdateAvailable(_ update: UpdateChecker.UpdateInfo) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }

            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self.enqueueUpdateNotification(update)
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error = error {
                        DebugLogger.log("UpdateNotifier: Permission error - \(error.localizedDescription)")
                    } else {
                        DebugLogger.log("UpdateNotifier: Permission \(granted ? "granted" : "denied")")
                    }

                    guard granted else { return }
                    self.enqueueUpdateNotification(update)
                }
            case .denied:
                DebugLogger.log("UpdateNotifier: Permission denied, skipping notification")
            @unknown default:
                DebugLogger.log("UpdateNotifier: Unknown permission state, skipping notification")
            }
        }
    }

    /// Reports the outcome of an install, using permission already granted.
    ///
    /// Unlike an update notice, this never asks for notification permission:
    /// being told an install finished is not worth a permission prompt, and the
    /// user sees the new version in the settings window anyway.
    public func notifyInstallResult(title: String, body: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                DebugLogger.log("UpdateNotifier: No permission, skipping install result")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body

            let request = UNNotificationRequest(
                identifier: "pritype-install-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    DebugLogger.log("UpdateNotifier: Failed to send - \(error.localizedDescription)")
                }
            }
        }
    }

    private func enqueueUpdateNotification(_ update: UpdateChecker.UpdateInfo) {
        
        let content = UNMutableNotificationContent()
        content.title = L10n.update.notificationTitle
        content.body = String(format: L10n.update.notificationBody, update.version)
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier

        // Deliver immediately (no trigger = immediate)
        let request = UNNotificationRequest(
            identifier: "pritype-update-\(update.version)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                DebugLogger.log("UpdateNotifier: Failed to send - \(error.localizedDescription)")
            } else {
                DebugLogger.log("UpdateNotifier: Notification sent for v\(update.version)")
            }
        }
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    /// Handle notification tap (user clicked the notification banner)
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // The settings window, not the browser: the update can be installed from
        // there, and it offers the release page when it cannot be.
        DebugLogger.log("UpdateNotifier: Opening update settings")
        DispatchQueue.main.async {
            SettingsWindowController.shared.showUpdateSettings()
        }

        completionHandler()
    }
    
    /// Show notifications even when the app is in the foreground
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
