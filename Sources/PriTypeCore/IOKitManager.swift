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
public final class IOKitManager: Sendable {
    
    // Singleton - accessed from IOKit callback context
    public static let shared = IOKitManager()

    /// Everything mutable here.
    ///
    /// None of it used to be protected by anything. The HID value callback runs
    /// on the run loop that opened the manager and reads `shortcutState` and the
    /// callbacks, while `start()` and `stop()` write all three from whoever calls
    /// them — the class simply declared itself `@unchecked Sendable` and left it
    /// there. In practice `KeyMonitors` is `@MainActor` and everything happened
    /// on main, which is a property of the callers rather than of this type, and
    /// nothing here said so or checked it.
    private final class State {
        var manager: IOHIDManager?
        var shortcutState = HIDShortcutState()
        var onToggle: (@Sendable (TimeInterval) -> Void)?
        var onHanja: (@Sendable (TimeInterval) -> Void)?
    }

    private let state = Guarded(State())
    
    /// Callback when toggle key is pressed, with when the key was pressed on
    /// `NSEvent.timestamp`'s clock.
    public var onRightCommandToggle: (@Sendable (TimeInterval) -> Void)? {
        get { state.withLock { $0.onToggle } }
        set { state.withLock { $0.onToggle = newValue } }
    }

    /// Callback when hanja key is pressed, with its press time.
    public var onRightOptionHanja: (@Sendable (TimeInterval) -> Void)? {
        get { state.withLock { $0.onHanja } }
        set { state.withLock { $0.onHanja = newValue } }
    }
    
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

    /// Why a start did not happen, in the terms the operator has to act on.
    ///
    /// `start()` returns a bare `false` because its callers only choose between
    /// the tap and the fallback. The on-device verification tool has to tell a
    /// missing permission from a keyboard another process already owns — the two
    /// have completely different remedies, and `IOHIDManagerOpen` reports them as
    /// two numbers that look alike. This is that distinction, made once, on the
    /// path the app itself takes.
    public enum StartFailure: Error, Sendable, Equatable {
        /// The user has refused Input Monitoring; only System Settings can undo it.
        case inputMonitoringDenied
        /// Never asked, and this caller chose not to prompt.
        case inputMonitoringNotDetermined
        /// Another process holds the keyboards — in practice, a running PriTypeV2.
        case keyboardsExclusivelyOwned(IOReturn)
        /// `IOHIDManagerOpen` failed for some other reason.
        case openFailed(IOReturn)

        public var summary: String {
            switch self {
            case .inputMonitoringDenied:
                return "Input Monitoring is denied for this binary"
            case .inputMonitoringNotDetermined:
                return "Input Monitoring has never been granted for this binary"
            case .keyboardsExclusivelyOwned(let code):
                return "another process owns the keyboards (IOReturn \(code))"
            case .openFailed(let code):
                return "IOHIDManagerOpen failed (IOReturn \(code))"
            }
        }
    }

    /// `kIOReturnExclusiveAccess`. Spelled out because the IOKit constant is not
    /// exposed to Swift and the literal alone reads as noise.
    static let exclusiveAccess: IOReturn = -536_870_203

    /// What a start that did happen actually did.
    ///
    /// A start that found the manager already open opened nothing, and a check
    /// that reports "IOHIDManagerOpen succeeded" off the back of it would be
    /// claiming a syscall that never ran.
    public enum StartOutcome: Sendable, Equatable {
        case opened
        case alreadyRunning
    }

    /// Start monitoring keyboard events via IOHIDManager
    /// - Returns: `true` if successfully started, `false` otherwise
    @discardableResult
    public func start() -> Bool {
        switch start(promptForInputMonitoring: true) {
        case .success:
            return true
        case .failure(let reason):
            DebugLogger.log("IOKitManager: \(reason.summary)")
            return false
        }
    }

    /// The same start, saying why when it does not happen.
    ///
    /// - Parameter promptForInputMonitoring: whether a never-asked permission
    ///   shows the system prompt. The app prompts; a verification run must not,
    ///   because a tool that changes the machine while measuring it cannot be
    ///   run twice and compared.
    ///
    /// ## What is deliberately outside the lock
    ///
    /// `IOHIDManagerOpen` is blocking IPC to `hidd` and can carry a TCC
    /// evaluation with it; scheduling on the run loop and the permission checks
    /// are no better. Holding the lock across them would matter, because
    /// `RightCommandSuppressor.startLocked` calls `stop()` here while holding the
    /// lock the tap callback needs for every keystroke on the system: one thread
    /// inside `IOHIDManagerOpen` would then be enough to stall typing everywhere
    /// until `hidd` answered. So the manager is built and opened unpublished, and
    /// the lock is taken only to publish it.
    @discardableResult
    public func start(promptForInputMonitoring: Bool) -> Result<StartOutcome, StartFailure> {
        guard state.withLock({ $0.manager == nil }) else {
            DebugLogger.log("IOKitManager: Already running")
            return .success(.alreadyRunning)
        }

        // Without Input Monitoring, IOHIDManagerOpen fails with a bare
        // kIOReturnNotPermitted. Say why, and prompt if the user was never asked.
        switch Self.inputMonitoringAccess() {
        case .granted:
            break
        case .notDetermined:
            guard promptForInputMonitoring else { return .failure(.inputMonitoringNotDetermined) }
            DebugLogger.log("IOKitManager: Input Monitoring not determined — requesting")
            guard Self.requestInputMonitoringPermission() else {
                return .failure(.inputMonitoringNotDetermined)
            }
        case .denied:
            return .failure(.inputMonitoringDenied)
        }

        DebugLogger.log("IOKitManager: Starting IOKit-only toggle detection...")

        // Create HID Manager
        let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

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
            owner.state.withLock { $0.shortcutState.handleDeviceRemoval() }
        }, context)

        // A new ownership lifecycle must not inherit a half-pressed modifier from a
        // previous IOKit run; otherwise its first key-up could emit a phantom toggle.
        // Before the source is scheduled, so no callback can land on the old state.
        state.withLock { $0.shortcutState = HIDShortcutState() }

        // Schedule with current run loop (like Gureum)
        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        // Open manager
        let result = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            DebugLogger.log("IOKitManager: Failed to open IOHIDManager: \(result)")
            IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetCurrent(),
                                              CFRunLoopMode.defaultMode.rawValue)
            return .failure(result == Self.exclusiveAccess
                            ? .keyboardsExclusivelyOwned(result)
                            : .openFailed(result))
        }

        // The check at the top of this function was made before the permission
        // checks and the open, so it cannot stand in for this one: two starts can
        // both have passed it. Whoever publishes first owns the keyboards, and the
        // loser closes what it opened rather than overwriting — an abandoned
        // manager stays scheduled and delivers every key press a second time.
        let published = state.withLock { state -> Bool in
            guard state.manager == nil else { return false }
            state.manager = hidManager
            return true
        }
        guard published else {
            IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetCurrent(),
                                              CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
            DebugLogger.log("IOKitManager: Another start won the race; closed this one")
            return .success(.alreadyRunning)
        }

        let config = ConfigurationManager.shared
        DebugLogger.log("IOKitManager: Started successfully (toggle=\(config.toggleKeyBinding.displayName), hanja=\(config.hanjaKeyBinding.displayName))")
        return .success(.opened)
    }
    
    /// Stop monitoring
    public func stop() {
        // Take the manager out under the lock and close it outside: the close is
        // the same blocking IPC the open is, and the tap callback can be waiting
        // behind this lock by way of the suppressor's.
        let manager = state.withLock { state -> IOHIDManager? in
            defer {
                state.manager = nil
                state.shortcutState = HIDShortcutState()
            }
            return state.manager
        }
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        DebugLogger.log("IOKitManager: Stopped")
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
        // Everything this needs from elsewhere is resolved before the lock is
        // taken. All of it — the exclusion policy, the suppressor's recording
        // flag, and every one of the configuration reads, which go through the
        // binding cache's own lock — so this callback holds exactly one lock and
        // no path can acquire two in an order some other path reverses.
        let config = ConfigurationManager.shared
        let isPaused = paused ?? (ToggleExclusionPolicy.shared.isTogglePaused
                                  || RightCommandSuppressor.shared.isRecordingKey)
        let toggleBinding = toggle ?? config.toggleKeyBinding
        let hanjaBinding = hanja ?? config.hanjaKeyBinding
        let isToggleEnabled = toggleEnabled ?? !config.capsLockInputSourceSwitchEnabled
        let isHanjaEnabled = hanjaEnabled ?? config.hanjaEnabled
        let activeTrigger = trigger ?? config.toggleTrigger
        let callback: (@Sendable (TimeInterval) -> Void)? = state.withLock { state in
            let action = state.shortcutState.consume(
                usage: usage, pressed: pressed, device: device,
                toggle: toggleBinding,
                hanja: hanjaBinding,
                toggleEnabled: isToggleEnabled,
                hanjaEnabled: isHanjaEnabled,
                trigger: activeTrigger,
                paused: isPaused
            )
            switch action {
            case .toggle: return state.onToggle
            case .hanja: return state.onHanja
            case nil: return nil
            }
        }
        guard let callback else { return }
        // The press time is what this used to lose, and it is a parameter now, so
        // it survives the hop. The hop itself stays: this run loop is the main one,
        // and performing the toggle inline would run a composition finalize
        // (`insertText` to the host) and `TISSelectInputSource` inside the IOHID
        // value callback. Those can spin the run loop, which would re-enter this
        // callback part-way through a mode transition.
        let pressedAt = eventTime ?? ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { callback(pressedAt) }
    }
}
