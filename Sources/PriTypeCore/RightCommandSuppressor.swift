import Foundation
import Cocoa
import ApplicationServices

/// Primary toggle key handler using CGEventTap.
///
/// ## Role
/// Intercepts user-configured toggle and hanja key events at the system level
/// using CGEventTap to provide instant language mode switching.
///
/// ## Dynamic Key Binding
/// Instead of hardcoded keys, this class reads `ConfigurationManager.toggleKeyBinding`
/// and `ConfigurationManager.hanjaKeyBinding` to determine which keys to intercept.
/// Users can configure any modifier key or key combination via the Settings UI.
///
/// ## Relationship with IOKitManager
/// - **Primary handler**: `RightCommandSuppressor` (this class)
/// - **Backup handler**: `IOKitManager`
///
/// This class uses `IOKitManager.hasAccessibilityPermission()` to check permissions.
/// If CGEventTap creation fails (e.g., permission issues), `IOKitManager` takes over.
///
/// ## Key Features
/// - **Instant toggle**: Switches on key press, not release
/// - **Modifier stripping**: When toggle modifier is held, removes its modifier from other keys
/// - **Dynamic binding**: Supports any key via KeyBinding struct
///
/// ## Threading
/// The tap runs on its own thread (`EventTapThread`), not the main run loop. Every
/// keystroke on the system waits for this callback before any app sees it, and the
/// main thread is regularly busy with IMK work, synchronous client IPC and the
/// settings UI. On main, any of those would delay typing everywhere and could get
/// the tap disabled for timing out.
///
/// All mutable state is guarded by `lock`, which the callback holds for the whole
/// event. It is recursive because the callback itself can call `stop()` when it
/// hands off to IOKit. Nothing holding it waits on the tap thread, so it cannot
/// deadlock against the callback.
public final class RightCommandSuppressor: @unchecked Sendable {
    
    // Singleton - accessed from CGEventTap callback context
    public static let shared = RightCommandSuppressor()
    
    private let lock = NSRecursiveLock()

    private var eventTap: CFMachPort?
    private var tapThread: EventTapThread?
    
    /// Whether the event tap is currently running
    public var isRunning: Bool {
        lock.withLock { eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    }
    
    /// Callback for toggle. Called on the event-tap thread at the moment the key is
    /// seen, so it must be thread-safe and must not block.
    /// `InputModeCoordinator.requestToggle` is both.
    ///
    /// `eventTime` is when the key was pressed, on the same clock as
    /// `NSEvent.timestamp` (seconds of uptime), so the owner can tell keystrokes
    /// typed before the toggle from those typed after it.
    public var onToggle: (@Sendable (_ eventTime: TimeInterval) -> Void)? {
        get { lock.withLock { _onToggle } }
        set { lock.withLock { _onToggle = newValue } }
    }
    private var _onToggle: (@Sendable (_ eventTime: TimeInterval) -> Void)?
    
    /// Callback for Hanja lookup. Called on the event-tap thread with the key's
    /// time, like `onToggle`, so it must be thread-safe and must not block.
    /// `InputModeCoordinator.requestHanjaLookup` is both.
    public var onHanjaLookup: (@Sendable (_ eventTime: TimeInterval) -> Void)? {
        get { lock.withLock { _onHanjaLookup } }
        set { lock.withLock { _onHanjaLookup = newValue } }
    }
    private var _onHanjaLookup: (@Sendable (_ eventTime: TimeInterval) -> Void)?
    
    /// Track toggle modifier state
    private var toggleModifierIsDown = false
    
    /// Track hanja modifier state
    private var hanjaModifierIsDown = false
    
    /// Debounce timer for Hanja trigger to prevent double-fire
    private var lastHanjaTriggerTime: DispatchTime = .init(uptimeNanoseconds: 0)

    /// Track Control state for Control+Space
    private var controlIsDown = false
    
    /// Tracks recovery and makes the CGEventTap → IOKit handoff exactly-once.
    private var failureTracker = EventTapFailureTracker()
    
    /// Callback for when CGEventTap permanently fails and IOKit should take over.
    /// Delivered on the main queue.
    public var onTapFailed: (@Sendable () -> Void)? {
        get { lock.withLock { _onTapFailed } }
        set { lock.withLock { _onTapFailed = newValue } }
    }
    private var _onTapFailed: (@Sendable () -> Void)?
    
    /// Whether recording mode is active (for Key Recorder in settings)
    public var isRecordingKey: Bool {
        get { lock.withLock { _isRecordingKey } }
        set {
            lock.withLock {
                _isRecordingKey = newValue
                recordingState = KeyRecordingState()
            }
        }
    }
    private var _isRecordingKey = false
    private var recordingState = KeyRecordingState()
    
    /// Callback for key recording (settings UI). Delivered on the main queue.
    public var onKeyRecorded: ((_ keyCode: Int64, _ modifiers: UInt64) -> Void)? {
        get { lock.withLock { _onKeyRecorded } }
        set { lock.withLock { _onKeyRecorded = newValue } }
    }
    private var _onKeyRecorded: ((_ keyCode: Int64, _ modifiers: UInt64) -> Void)?
    
    init() {}
    
    // MARK: - Start/Stop
    
    /// Start monitoring toggle keys
    /// - Returns: `true` if CGEventTap was created successfully, `false` otherwise
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if eventTap != nil && !isRunning { stop() }
        guard eventTap == nil else {
            // Enforce single ownership even if another caller redundantly starts the
            // primary monitor after an IOKit fallback was active.
            IOKitManager.shared.stop()
            DebugLogger.log("RightCommandSuppressor: Already running")
            return true
        }
        
        guard IOKitManager.hasAccessibilityPermission() else {
            DebugLogger.log("RightCommandSuppressor: No Accessibility permission")
            return false
        }
        
        // Monitor flagsChanged AND keyDown events
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        
        // Create event tap
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let suppressor = Unmanaged<RightCommandSuppressor>.fromOpaque(refcon).takeUnretainedValue()
                return suppressor.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let eventTap = eventTap else {
            DebugLogger.log("RightCommandSuppressor: Failed to create event tap")
            return false
        }

        failureTracker.reset()
        
        // Service the tap from its own thread, never the main run loop.
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            DebugLogger.log("RightCommandSuppressor: Failed to create run loop source")
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
            return false
        }
        let thread = EventTapThread(source: source)
        guard thread.startAndWait() else {
            DebugLogger.log("RightCommandSuppressor: Event tap thread did not start")
            thread.stopRunLoop()
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
            return false
        }
        tapThread = thread

        // CGEventTap now owns keyboard monitoring. Stop a prior hardware fallback
        // before enabling the tap so a physical press has only one active producer.
        IOKitManager.shared.stop()
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        let config = ConfigurationManager.shared
        DebugLogger.log("RightCommandSuppressor: Started (toggle=\(config.toggleKeyBinding.displayName), hanja=\(config.hanjaKeyBinding.displayName))")
        return true
    }
    
    /// Stop monitoring. Callable from main or from the tap callback itself.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        // Never waits for the thread: the callback may be the caller, and a waiting
        // main thread would hold `lock` against a callback that needs it.
        tapThread?.stopRunLoop()
        tapThread = nil
        eventTap = nil
        toggleModifierIsDown = false
        hanjaModifierIsDown = false
        controlIsDown = false
        DebugLogger.log("RightCommandSuppressor: Stopped")
    }
    
    // MARK: - Event Handling
    
    // Internal entry point permits event-sequence tests without installing a tap.
    func handleEvent(type: CGEventType, event: CGEvent,
                     toggle: KeyBinding? = nil, hanja: KeyBinding? = nil,
                     toggleEnabled: Bool? = nil, hanjaEnabled: Bool? = nil,
                     recoveryFlags: UInt64? = nil,
                     excludedOverride: Bool? = nil) -> Unmanaged<CGEvent>? {
        lock.lock()
        defer { lock.unlock() }
        // Re-enable tap if disabled by system
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            switch failureTracker.recordDisable(at: CFAbsoluteTimeGetCurrent()) {
            case .handoffToIOKit:
                // Stop/remove the tap before notifying the owner. The callback starts
                // IOKit on the main queue, so there is never an overlap window.
                DebugLogger.log("RightCommandSuppressor: Tap repeatedly disabled; stopping before IOKit handoff")
                let callback = _onTapFailed
                stop()
                DispatchQueue.main.async {
                    callback?()
                }
            case .reenable(let attempt):
                DebugLogger.log("RightCommandSuppressor: Tap disabled (\(attempt)/\(failureTracker.maxRetries)), re-enabling")
                let flags = recoveryFlags ?? CGEventSource.flagsState(.combinedSessionState).rawValue
                toggleModifierIsDown = ModifierKeyState.isDown((toggle ?? ConfigurationManager.shared.toggleKeyBinding).keyCode, flags: flags)
                hanjaModifierIsDown = ModifierKeyState.isDown((hanja ?? ConfigurationManager.shared.hanjaKeyBinding).keyCode, flags: flags)
                if let tap = eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            case .ignore:
                break
            }
            return Unmanaged.passUnretained(event)
        }
        
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let config = ConfigurationManager.shared
        let toggleBinding = toggle ?? config.toggleKeyBinding
        let hanjaBinding = hanja ?? config.hanjaKeyBinding
        // The frontmost app may be excluded by the user (remote desktop / VM, which
        // runs its own IME and needs the physical key). This is a cached lookup —
        // never query the workspace or Accessibility from a tap callback.
        let excluded = excludedOverride ?? ToggleExclusionPolicy.shared.isTogglePaused
        let priTypeToggleEnabled = (toggleEnabled ?? !config.capsLockInputSourceSwitchEnabled) && !excluded
        if !priTypeToggleEnabled {
            toggleModifierIsDown = false
        }
        // Hanja conversion turned off: its key is an ordinary key again.
        let priTypeHanjaEnabled = hanjaEnabled ?? config.hanjaEnabled
        if !priTypeHanjaEnabled {
            hanjaModifierIsDown = false
        }
        // Exclusion is enforced by this single early return, NOT by per-branch
        // guards below. Keep it that way: with two mechanisms, removing this return
        // would silently leave the toggle branch unguarded while hanja stayed safe.
        // Recording still needs the key; everything else — including modifier
        // stripping — must leave the event exactly as the app expects it.
        if excluded {
            hanjaModifierIsDown = false
            if !_isRecordingKey {
                return Unmanaged.passUnretained(event)
            }
        }
        
        // Wait for modifier release or a regular key before deciding the binding.
        if _isRecordingKey {
            if type == .flagsChanged || type == .keyDown {
                if let recorded = recordingState.consume(keyCode: keyCode, flags: event.flags.rawValue,
                                                         isModifierChange: type == .flagsChanged) {
                    let callback = _onKeyRecorded
                    DispatchQueue.main.async { callback?(recorded.keyCode, recorded.modifiers) }
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // Handle flagsChanged (modifier keys)
        if type == .flagsChanged {
            let flags = event.flags
            
            // Track Control key state (for Control+Space combo)
            controlIsDown = flags.contains(.maskControl)

            if keyCode == 57 {
                return Unmanaged.passUnretained(event)
            }
            
            // Dynamic toggle key — modifier key, single-key binding
            if priTypeToggleEnabled && toggleBinding.isModifierKey && toggleBinding.isModifierOnly && keyCode == toggleBinding.keyCode {
                let isPressed = ModifierKeyState.isDown(keyCode, flags: flags.rawValue)
                
                if isPressed && !toggleModifierIsDown {
                    // Toggle modifier pressed - toggle immediately!
                    toggleModifierIsDown = true
                    DebugLogger.log("RightCommandSuppressor: Toggle key DOWN (\(toggleBinding.displayName)) - TOGGLE (instant)")
                    triggerToggle(event)
                    return nil  // Suppress the modifier event
                } else if !isPressed && toggleModifierIsDown {
                    // Toggle modifier released
                    toggleModifierIsDown = false
                    DebugLogger.log("RightCommandSuppressor: Toggle key UP (\(toggleBinding.displayName))")
                    return nil  // Suppress release
                }
            }
            
            // Dynamic hanja key — modifier key, single-key binding (only if different from toggle key)
            if priTypeHanjaEnabled && hanjaBinding.isModifierKey && hanjaBinding.isModifierOnly
                && keyCode == hanjaBinding.keyCode && keyCode != toggleBinding.keyCode {
                let isPressed = ModifierKeyState.isDown(keyCode, flags: flags.rawValue)
                
                if isPressed && !hanjaModifierIsDown {
                    hanjaModifierIsDown = true
                    
                    // Debounce: ignore if last trigger was within 500ms
                    let now = DispatchTime.now()
                    let elapsed = now.uptimeNanoseconds - lastHanjaTriggerTime.uptimeNanoseconds
                    let elapsedMs = elapsed / 1_000_000
                    if elapsedMs < 500 {
                        DebugLogger.log("RightCommandSuppressor: Hanja key DEBOUNCED (\(elapsedMs)ms)")
                        return nil
                    }
                    lastHanjaTriggerTime = now
                    
                    DebugLogger.log("RightCommandSuppressor: Hanja key DOWN (\(hanjaBinding.displayName)) - HANJA")
                    triggerHanjaLookup(event)
                    return nil  // Suppress
                } else if !isPressed && hanjaModifierIsDown {
                    hanjaModifierIsDown = false
                    DebugLogger.log("RightCommandSuppressor: Hanja key UP (\(hanjaBinding.displayName))")
                    return nil  // Suppress release
                }
            }
            
            return Unmanaged.passUnretained(event)
        }
        
        // Handle keyDown
        if type == .keyDown {
            // Reconcile on every key: a release may have been lost while disabled.
            toggleModifierIsDown = ModifierKeyState.isDown(toggleBinding.keyCode, flags: event.flags.rawValue)
            hanjaModifierIsDown = priTypeHanjaEnabled
                && ModifierKeyState.isDown(hanjaBinding.keyCode, flags: event.flags.rawValue)
            // The window server keeps generating keyDown while an ordinary key is
            // held, so acting on every one flaps the input source for as long as
            // the user leans on it. Keep suppressing the repeats — the key must
            // still never reach the app — but act only on the first press. Each
            // binding checks this after it has matched, so an unrelated held key
            // is delivered normally.
            let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // Regular key (non-modifier) as toggle — single key or combo
            if priTypeToggleEnabled && keyCode == toggleBinding.keyCode && !toggleBinding.isModifierKey {
                if toggleBinding.isModifierOnly {
                    if isAutorepeat { return nil }
                    // Single regular key as toggle (e.g., F13, Caps Lock via keyDown)
                    DebugLogger.log("RightCommandSuppressor: Regular key toggle (\(toggleBinding.displayName)) - TOGGLE")
                    triggerToggle(event)
                    return nil
                } else {
                    // Combo toggle (e.g., Control+Space, Option+G)
                    let requiredFlags = CGEventFlags(rawValue: toggleBinding.modifiers)
                    if Self.hasRequiredModifiers(flags: event.flags, required: requiredFlags) {
                        if isAutorepeat { return nil }
                        DebugLogger.log("RightCommandSuppressor: Combo toggle (\(toggleBinding.displayName)) - TOGGLE triggered")
                        triggerToggle(event)
                        return nil
                    }
                }
            }
            
            // Regular key (non-modifier) as hanja — single key or combo
            // A matching toggle already returned above. Sharing a physical key is
            // valid when the two bindings require different modifiers.
            if priTypeHanjaEnabled && keyCode == hanjaBinding.keyCode && !hanjaBinding.isModifierKey {
                if hanjaBinding.isModifierOnly || Self.hasRequiredModifiers(flags: event.flags, required: CGEventFlags(rawValue: hanjaBinding.modifiers)) {
                    if isAutorepeat { return nil }
                    DebugLogger.log("RightCommandSuppressor: Regular key hanja (\(hanjaBinding.displayName)) - HANJA")
                    triggerHanjaLookup(event)
                    return nil
                }
            }
            
            // Candidate keys while the Hanja window is up. Routed here rather than
            // through IMK because some clients (Terminal) never pass Escape, the
            // arrows or Return to the input method once nothing is marked.
            if HanjaCandidateWindow.isAcceptingKeys {
                switch HanjaCandidateWindow.route(keyCode: keyCode, flags: event.flags) {
                case .consume(let digit):
                    let code = UInt16(keyCode)
                    DispatchQueue.main.async {
                        HanjaCandidateWindow.shared.handleRoutedKey(keyCode: code, digit: digit)
                    }
                    return nil
                case .dismissAndPass:
                    DispatchQueue.main.async {
                        HanjaCandidateWindow.shared.dismiss()
                    }
                    return Unmanaged.passUnretained(event)
                case .ignore:
                    break
                }
            }

            // When toggle modifier is held, strip its modifier from key events
            // This makes keys act as regular character input, not shortcuts
            if priTypeToggleEnabled && toggleModifierIsDown && toggleBinding.isModifierKey {
                let modifierMask = Self.modifierMask(for: toggleBinding.keyCode)
                var newFlags = event.flags
                newFlags.remove(CGEventFlags(rawValue: ModifierKeyState.mask(for: toggleBinding.keyCode)))
                if !ModifierKeyState.isDown(ModifierKeyState.opposite(toggleBinding.keyCode), flags: event.flags.rawValue) {
                    newFlags.remove(modifierMask)
                }
                event.flags = newFlags
                DebugLogger.log("RightCommandSuppressor: Key with toggle modifier - stripped modifier (normal input)")
                return Unmanaged.passUnretained(event)
            }
        }
        
        return Unmanaged.passUnretained(event)
    }
    
    // MARK: - Helpers
    
    /// Get the CGEventFlags modifier mask for a given keyCode
    private static func modifierMask(for keyCode: Int64) -> CGEventFlags {
        switch keyCode {
        case 54, 55: return .maskCommand       // Right/Left Command
        case 61, 58: return .maskAlternate      // Right/Left Option
        case 62, 59: return .maskControl        // Right/Left Control
        case 56, 60: return .maskShift          // Left/Right Shift
        case 57:     return .maskAlphaShift     // Caps Lock
        default:     return CGEventFlags(rawValue: 0)
        }
    }
    
    /// Check if event flags contain required modifier flags
    private static func hasRequiredModifiers(flags: CGEventFlags, required: CGEventFlags) -> Bool {
        return flags.intersection(required) == required
    }

    private func triggerToggle(_ event: CGEvent) {
        // Hand the toggle over right here, on the tap thread. The owner records it
        // with the key's time and applies it on main (`InputModeCoordinator
        // .requestToggle`), so the keystroke typed next cannot overtake it. IMK
        // commit and keyboard-override work still stay off this callback, which
        // protects against `kCGEventTapDisabledByTimeout`.
        _onToggle?(Self.eventTime(of: event))
    }

    /// The event's time on `NSEvent.timestamp`'s clock. AppKit reads a CGEvent
    /// timestamp as nanoseconds of uptime; a synthetic event may carry 0, so fall
    /// back to now.
    static func eventTime(of event: CGEvent) -> TimeInterval {
        event.timestamp == 0
            ? ProcessInfo.processInfo.systemUptime
            : TimeInterval(event.timestamp) / 1_000_000_000
    }
    
    private func triggerHanjaLookup(_ event: CGEvent) {
        // Same hand-over as the toggle, so the two keep their relative order and a
        // key typed after the Hanja key reaches the candidate window.
        _onHanjaLookup?(Self.eventTime(of: event))
    }
}

/// The thread whose run loop services the event tap.
///
/// The run loop exits when `stopRunLoop()` removes the source, which ends the
/// thread. One instance serves one `start()`; a restart creates a new thread.
final class EventTapThread: Thread, @unchecked Sendable {
    private let source: CFRunLoopSource
    private let started = DispatchSemaphore(value: 0)
    private let loopLock = NSLock()
    private var runLoop: CFRunLoop?

    init(source: CFRunLoopSource) {
        self.source = source
        super.init()
        name = "com.pritype.eventtap"
        // Every keystroke on the system waits on this thread.
        qualityOfService = .userInteractive
    }

    override func main() {
        let loop = CFRunLoopGetCurrent()
        // Attaching the source and publishing the loop happen under the same lock
        // that `stopRunLoop()` takes, so a stop can never fall between them.
        let attached = loopLock.withLock { () -> Bool in
            guard !isCancelled else { return false }
            CFRunLoopAddSource(loop, source, .commonModes)
            runLoop = loop
            return true
        }
        started.signal()
        guard attached else { return }
        // Returns once `stopRunLoop()` has removed the only source.
        CFRunLoopRun()
    }

    /// Start the thread and wait until its run loop owns the tap source.
    func startAndWait(timeout: DispatchTimeInterval = .seconds(2)) -> Bool {
        start()
        return started.wait(timeout: .now() + timeout) == .success && !isCancelled
    }

    /// Wake the run loop so a signalled version-0 source is serviced (for tests;
    /// a mach-port source such as the tap wakes the loop on its own).
    func wake() {
        loopLock.withLock { runLoop.map(CFRunLoopWakeUp) }
    }

    /// Detach the source and let the run loop exit. Safe from any thread,
    /// including this one, and before the thread has attached the source.
    func stopRunLoop() {
        loopLock.withLock {
            guard let loop = runLoop else {
                // Not attached yet: `main()` sees this and never attaches.
                cancel()
                return
            }
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFRunLoopStop(loop)
            CFRunLoopWakeUp(loop)
            runLoop = nil
        }
    }
}
