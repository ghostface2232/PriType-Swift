import Foundation
import InputMethodKit
import Cocoa
import PriTypeCore

let kConnectionName = "PriType_InputString_v2"

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    
    private var hasLaunchedBefore = false

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

        // Setup toggle key monitoring
        setupIOKit()
        
        // Pre-load Hanja dictionary in background for instant lookup
        if ConfigurationManager.shared.hanjaEnabled {
            DispatchQueue.global(qos: .utility).async {
                HanjaManager.shared.loadIfNeeded()
            }
        }
        
        // Setup update notifications
        UpdateNotifier.shared.setup()
        
        // Check for updates in background (respects user preference and 24h throttle)
        if ConfigurationManager.shared.autoUpdateCheckEnabled {
            Task.detached(priority: .utility) {
                let result = await UpdateChecker.shared.checkForUpdatesIfNeeded()
                if case .updateAvailable(let info) = result {
                    UpdateNotifier.shared.notifyUpdateAvailable(info)
                }
            }
        }
        
        // Mark as launched (don't show settings on first boot)
        hasLaunchedBefore = true
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DebugLogger.log("AppDelegate: applicationShouldHandleReopen")
        // Only show settings when explicitly launched from Launchpad/Finder (reopen)
        DispatchQueue.main.async {
            SettingsWindowController.shared.showSettings()
        }
        return true
    }
    
    private func setupIOKit() {
        // Check/request Accessibility permission
        if !IOKitManager.hasAccessibilityPermission() {
            DebugLogger.log("Requesting Accessibility permission...")
            IOKitManager.requestAccessibilityPermission()
            
            // Poll until user grants permission from the system popup
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                DebugLogger.log("Accessibility granted via system popup — starting key monitoring")
                self.setupIOKit()
            }
            return
        }
        
        // Set callback for CGEventTap toggle handler (handles all toggle keys)
        RightCommandSuppressor.shared.onToggle = { eventTime in
            InputModeCoordinator.shared.requestToggle(source: .customKey, eventTime: eventTime)
        }
        
        // Set callback for Right Option key → Hanja lookup
        RightCommandSuppressor.shared.onHanjaLookup = { eventTime in
            InputModeCoordinator.shared.requestHanjaLookup(eventTime: eventTime)
        }
        
        // Track if CGEventTap started successfully
        let eventTapStarted = RightCommandSuppressor.shared.start()
        
        // IOKit backup: Only start and activate actual toggle if CGEventTap failed
        if eventTapStarted {
            DebugLogger.log("Primary: CGEventTap started successfully")
            // Register fallback: if CGEventTap dies repeatedly, switch to IOKit
            RightCommandSuppressor.shared.onTapFailed = { [weak self] in
                DebugLogger.log("CGEventTap failed repeatedly — activating IOKit fallback")
                // RightCommandSuppressor has already removed and disabled its tap.
                // IOKitManager.start() is idempotent, preserving exactly one owner.
                self?.startIOKitFallback()
            }
        } else {
            DebugLogger.log("Primary: CGEventTap FAILED - IOKit taking over as primary")
            startIOKitFallback()
        }
        
        DebugLogger.log("Toggle key monitoring initialized")
    }

    /// Hand key monitoring to IOKit. It needs Input Monitoring; when that is
    /// missing, `start()` prompts (first time only) and this waits for the grant,
    /// as `setupIOKit` does for Accessibility, instead of leaving the toggle and
    /// Hanja keys dead until the next launch.
    /// The single wait for Input Monitoring. Replaced, never stacked, when the
    /// fallback is started again (the tap can fail again after a restart).
    private var inputMonitoringPoll: Timer?

    private func startIOKitFallback() {
        IOKitManager.shared.onRightCommandToggle = {
            InputModeCoordinator.shared.requestToggle(source: .iokitFallback)
        }
        IOKitManager.shared.onRightOptionHanja = {
            InputModeCoordinator.shared.requestHanjaLookup()
        }
        guard !IOKitManager.shared.start() else { return }
        DebugLogger.log("IOKit fallback waiting for Input Monitoring permission")
        // Polls until granted or until the tap is back: there is no notification
        // for the grant, and IOHIDCheckAccess is a cheap local query.
        inputMonitoringPoll?.invalidate()
        inputMonitoringPoll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
            // The event tap may have come back (e.g. Accessibility re-granted
            // from Settings); only one monitor may own the keys.
            if RightCommandSuppressor.shared.isRunning {
                timer.invalidate()
                return
            }
            guard IOKitManager.inputMonitoringAccess() == .granted else { return }
            timer.invalidate()
            let started = IOKitManager.shared.start()
            DebugLogger.log("Input Monitoring granted — IOKit fallback start = \(started)")
        }
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
