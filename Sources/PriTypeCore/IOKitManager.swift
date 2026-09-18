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
/// The main entry point (`main.swift`) first attempts to start `RightCommandSuppressor`.
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
    
    /// Callback when toggle key is pressed
    public var onRightCommandToggle: (@Sendable () -> Void)?
    
    private var shortcutState = HIDShortcutState()

    /// Callback when hanja key is pressed
    public var onRightOptionHanja: (@Sendable () -> Void)?
    
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
    
    // MARK: - Start/Stop
    
    /// Start monitoring keyboard events via IOHIDManager
    /// - Returns: `true` if successfully started, `false` otherwise
    @discardableResult
    public func start() -> Bool {
        guard manager == nil else {
            DebugLogger.log("IOKitManager: Already running")
            return true
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
                            device: Self.identity(of: IOHIDElementGetDevice(element)))
    }

    /// Internal entry point for hardware-event tests without opening devices.
    func handleKeyboardEvent(usage: UInt32, pressed: Bool, device: UInt64 = 0,
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
        let callback: (@Sendable () -> Void)?
        switch action {
        case .toggle: callback = onRightCommandToggle
        case .hanja: callback = onRightOptionHanja
        case nil: return
        }
        DispatchQueue.main.async { callback?() }
    }
}
