import Foundation
import InputMethodKit
import Cocoa
import PriTypeCore

let kConnectionName = "PriType_InputString_v2"

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    
    private let updateCheckScheduler = NSBackgroundActivityScheduler(identifier: "com.pritype.inputmethod.v2.updatecheck")

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLogger.log("AppDelegate: applicationDidFinishLaunching")
        
        // Initialize IMK Server
        _ = IMKServer(name: kConnectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
        DebugLogger.log("IMKServer initialized")
        
        // Do not rewrite HIToolbox preference snapshots on every launch.
        // Registration/migration belongs to installation, while TIS owns live state.
        
        // Persist legacy/unsafe key bindings before any monitor reads them, so the
        // running binding and the stored binding cannot disagree.
        ConfigurationManager.shared.migrateKeyBindingsIfNeeded()

        // Track the frontmost app so the event-tap callback can consult the user's
        // toggle exclusion list without querying the workspace on the hot path.
        ToggleExclusionPolicy.shared.start()

        // Toggle/Hanja key monitoring. Without Accessibility, show the system
        // prompt once; the monitors start by themselves when it is granted.
        if !IOKitManager.hasAccessibilityPermission() {
            IOKitManager.requestAccessibilityPermission()
        }
        KeyMonitors.start()
        
        // Pre-load Hanja dictionary in background for instant lookup
        if ConfigurationManager.shared.hanjaEnabled {
            HanjaManager.shared.preload()
        }
        
        // Setup update notifications
        UpdateNotifier.shared.setup()
        
        // Check for updates now and then daily. An input method runs from login to
        // logout, often for weeks, so a check only at launch would rarely run.
        // The scheduler lets the system pick an idle moment; the 24h throttle
        // inside `checkForUpdatesIfNeeded` decides whether to ask GitHub. It
        // wakes every 6h, not 24h: a wake exactly 24h after the last check lands
        // a moment short of the throttle and would be skipped, stretching
        // "daily" to every other day. Skipped wakes cost no network.
        Self.checkForUpdates {}
        updateCheckScheduler.repeats = true
        updateCheckScheduler.interval = 6 * 60 * 60
        updateCheckScheduler.qualityOfService = .utility
        updateCheckScheduler.schedule { completion in
            Self.checkForUpdates { completion(.finished) }
        }
    }
    
    /// One automatic check, if the user allows them (and 24h have passed).
    private static func checkForUpdates(then done: @escaping @Sendable () -> Void) {
        guard ConfigurationManager.shared.autoUpdateCheckEnabled else { return done() }
        Task.detached(priority: .utility) {
            let result = await UpdateChecker.shared.checkForUpdatesIfNeeded()
            if case .updateAvailable(let info) = result {
                UpdateNotifier.shared.notifyUpdateAvailable(info)
            }
            done()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DebugLogger.log("AppDelegate: applicationShouldHandleReopen")
        // Only show settings when explicitly launched from Launchpad/Finder (reopen)
        DispatchQueue.main.async {
            SettingsWindowController.shared.showSettings()
        }
        return true
    }
}

// MARK: - Main Entry Point

// Only a fresh process can observe the ABC-layout removal (see
// ABCLayoutStatusProbe). Answer and exit before AppKit or IMK start.
ABCLayoutStatusProbe.runIfRequested()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
