import Foundation
import IOKit
import IOKit.hid
import ApplicationServices

/// Manager for IOHIDManager to detect toggle/hanja keys at hardware level.
///
/// ## Role
/// Provides hardware-level keyboard monitoring via IOHIDManager.
/// This class serves as a **backup fallback** when CGEventTap fails to start.
///
/// ## Dynamic Key Binding
/// Reads `ConfigurationManager.toggleKeyBinding` and `ConfigurationManager.hanjaKeyBinding`
/// to determine which keys to monitor, supporting any user-configured key.
///
/// ## Relationship with RightCommandSuppressor
/// - **Primary handler**: `RightCommandSuppressor` (CGEventTap)
/// - **Backup handler**: `IOKitManager` (IOHIDManager)
///
/// `KeyMonitors.start()` first attempts to start `RightCommandSuppressor`.
/// If that fails, `IOKitManager` takes over as the primary toggle handler.
/// When CGEventTap succeeds, `IOKitManager` is stopped so only one monitor owns a
/// physical key press at a time.
///
/// ## Primary Use Cases
/// - Accessibility permission check (`hasAccessibilityPermission()`)
/// - Hardware-level key event monitoring when CGEventTap is unavailable
public final class IOKitManager: @unchecked Sendable {
    
    // Singleton - accessed from IOKit callback context
    public static let shared = IOKitManager()
    
    private var manager: IOHIDManager?
    
    /// Callback when toggle key is pressed, with when the key was pressed on
    /// `NSEvent.timestamp`'s clock.
    public var onRightCommandToggle: (@Sendable (TimeInterval) -> Void)?
    
    private var shortcutState = HIDShortcutState()

    /// Callback when hanja key is pressed, with its press time.
    public var onRightOptionHanja: (@Sendable (TimeInterval) -> Void)?
    
    init() {}
    
    // MARK: - Accessibility Permission
    
    /// Check if Accessibility permission is granted
    public static func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }
    
    /// Request Accessibility permission (shows system dialog)
    public static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
    
    // MARK: - Input Monitoring Permission

    public enum InputMonitoringAccess: Sendable, Equatable {
        case granted
        case denied
        /// Never asked: `requestInputMonitoringPermission()` shows the system prompt.
        case notDetermined
    }

    /// Input Monitoring, which IOHIDManager needs to read keyboards. The
    /// CGEventTap path needs Accessibility instead, so this matters only once
    /// the IOKit fallback takes over — without it the fallback cannot open any
    /// keyboard and the toggle and Hanja keys stop working.
    public static func inputMonitoringAccess() -> InputMonitoringAccess {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .notDetermined
        }
    }

    /// Ask for Input Monitoring. Shows the system prompt the first time only;
    /// after a denial the user must change it in System Settings.
    /// - Returns: whether access is granted now.
    @discardableResult
    public static func requestInputMonitoringPermission() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: - Start/Stop
    
    /// Start monitoring keyboard events via IOHIDManager
    /// - Returns: `true` if successfully started, `false` otherwise
    @discardableResult
    public func start() -> Bool {
        guard manager == nil else {
            DebugLogger.log("IOKitManager: Already running")
            return true
        }

        // Without Input Monitoring, IOHIDManagerOpen fails with a bare
        // kIOReturnNotPermitted. Say why, and prompt if the user was never asked.
        switch Self.inputMonitoringAccess() {
        case .granted:
            break
        case .notDetermined:
            DebugLogger.log("IOKitManager: Input Monitoring not determined — requesting")
            guard Self.requestInputMonitoringPermission() else { return false }
        case .denied:
            DebugLogger.log("IOKitManager: Input Monitoring denied — cannot read keyboards")
            return false
        }

        // A new ownership lifecycle must not inherit a half-pressed modifier from a
        // previous IOKit run; otherwise its first key-up could emit a phantom toggle.
        shortcutState = HIDShortcutState()
        
        DebugLogger.log("IOKitManager: Starting IOKit-only toggle detection...")
        
        // Create HID Manager
        let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = hidManager
        
        // Match keyboard devices
        let matchingDict: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(hidManager, matchingDict as CFDictionary)
        
        // No input value matching - receive ALL keyboard events
        IOHIDManagerSetInputValueMatching(hidManager, nil)
        
        // Set input value callback
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(hidManager, { context, result, sender, value in
            guard let context = context else { return }
            let manager = Unmanaged<IOKitManager>.fromOpaque(context).takeUnretainedValue()
            manager.handleInputValue(value)
        }, context)
        
        IOHIDManagerRegisterDeviceRemovalCallback(hidManager, { context, _, _, _ in
            guard let context else { return }
            let owner = Unmanaged<IOKitManager>.fromOpaque(context).takeUnretainedValue()
            owner.shortcutState.handleDeviceRemoval()
        }, context)

        // Schedule with current run loop (like Gureum)
        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        
        // Open manager
        let result = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            DebugLogger.log("IOKitManager: Failed to open IOHIDManager: \(result)")
            manager = nil
            return false
        }
        
        let config = ConfigurationManager.shared
        DebugLogger.log("IOKitManager: Started successfully (toggle=\(config.toggleKeyBinding.displayName), hanja=\(config.hanjaKeyBinding.displayName))")
        return true
    }
    
    /// Stop monitoring
    public func stop() {
        if let hidManager = manager {
            IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
            manager = nil
            DebugLogger.log("IOKitManager: Stopped")
        }

        shortcutState = HIDShortcutState()
    }
    
    // MARK: - Input Handling

    /// Identifies the keyboard an event came from. The manager retains its
    /// IOHIDDevice objects for as long as the devices are present, so the
    /// object's address distinguishes two keyboards holding the same key.
    /// IOHIDDeviceGetService is the wrong key for this: it can be
    /// MACH_PORT_NULL, which collapses every such keyboard onto one identity,
    /// and mach port names are recycled once freed.
    private static func identity(of device: IOHIDDevice) -> UInt64 {
        UInt64(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque()))
    }

    /// The mach timebase, read once. On Apple silicon it is 1/1, but a ratio that
    /// happens to be the identity today is not one to hard-code.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// A HID event's timestamp on `NSEvent.timestamp`'s clock.
    ///
    /// Both are mach absolute time since boot, which is what lets a toggle seen
    /// here be ordered against a keystroke seen by IMK. A value of 0 means the
    /// event carries no time of its own (a synthesized one), and now is the
    /// closest true answer available.
    static func uptimeSeconds(fromMachAbsolute ticks: UInt64) -> TimeInterval {
        guard ticks > 0 else { return ProcessInfo.processInfo.systemUptime }
        let nanoseconds = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
        return nanoseconds / 1_000_000_000
    }

    private func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)
        let pressed = intValue > 0
        
        // Only interested in keyboard page
        guard usagePage == kHIDPage_KeyboardOrKeypad else { return }
        // Reject the page's non-key usages. 0x00 (Reserved) and 0x01 (ErrorRollOver,
        // reported on every slot when a boot-protocol keyboard exceeds rollover)
        // arrive as ordinary elements and would otherwise be tracked as held keys.
        guard usage >= 0x04, usage <= 0xE7 else { return }
        
        handleKeyboardEvent(usage: usage, pressed: pressed,
                            device: Self.identity(of: IOHIDElementGetDevice(element)),
                            eventTime: Self.uptimeSeconds(fromMachAbsolute: IOHIDValueGetTimeStamp(value)))
    }

    /// Internal entry point for hardware-event tests without opening devices.
    func handleKeyboardEvent(usage: UInt32, pressed: Bool, device: UInt64 = 0,
                             eventTime: TimeInterval? = nil,
                             toggle: KeyBinding? = nil, hanja: KeyBinding? = nil,
                             toggleEnabled: Bool? = nil, hanjaEnabled: Bool? = nil,
                             trigger: ToggleTrigger? = nil, paused: Bool? = nil) {
        let config = ConfigurationManager.shared
        let action = shortcutState.consume(
            usage: usage, pressed: pressed, device: device,
            toggle: toggle ?? config.toggleKeyBinding,
            hanja: hanja ?? config.hanjaKeyBinding,
            toggleEnabled: toggleEnabled ?? !config.capsLockInputSourceSwitchEnabled,
            hanjaEnabled: hanjaEnabled ?? config.hanjaEnabled,
            trigger: trigger ?? config.toggleTrigger,
            paused: paused ?? (ToggleExclusionPolicy.shared.isTogglePaused || RightCommandSuppressor.shared.isRecordingKey)
        )
        let callback: (@Sendable (TimeInterval) -> Void)?
        switch action {
        case .toggle: callback = onRightCommandToggle
        case .hanja: callback = onRightOptionHanja
        case nil: return
        }
        // Handed over here, with the time the key was pressed, exactly as the event
        // tap does it. The hop to main and the ordering against keystrokes belong to
        // `InputModeCoordinator`, which is the one place that knows what is still in
        // flight; this callback used to hop first and arrive with no press time at
        // all, which left the fallback unable to make that ordering at all.
        callback?(eventTime ?? ProcessInfo.processInfo.systemUptime)
    }
}
