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
/// - **Toggle trigger**: A lone-modifier toggle key switches on press (default),
///   or on a tap with no other key (`ToggleTrigger.tapAlone`)
/// - **Modifier stripping**: In press mode, while the toggle modifier is held,
///   removes its modifier from other keys
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
public final class RightCommandSuppressor: Sendable {
    
    // Singleton - accessed from CGEventTap callback context
    public static let shared = RightCommandSuppressor()

    /// Everything mutable in the tap path, behind one lock.
    ///
    /// This is a class rather than a struct because the callback re-enters the
    /// lock: handing a toggle over to IOKit calls `stop()` from inside the event
    /// it is handling. A re-entrant `withLock` on a struct would be a second
    /// `inout` view of one value, which is an exclusivity violation; on a class
    /// it is the same object, which is what the code already assumed.
    private final class State {
        var eventTap: CFMachPort?
        var tapThread: EventTapThread?

        /// Called on the event-tap thread at the moment the key is seen.
        var onToggle: (@Sendable (_ eventTime: TimeInterval) -> Void)?
        var onHanjaLookup: (@Sendable (_ eventTime: TimeInterval) -> Void)?
        /// Called on the event-tap thread for a keystroke passed on to the app.
        var onKeyPassed: (@Sendable (_ eventTime: TimeInterval) -> Void)?
        /// Delivered on the main queue.
        var onTapFailed: (@Sendable () -> Void)?
        /// Delivered on the main queue.
        var onKeyRecorded: (@Sendable (_ keyCode: Int64, _ modifiers: UInt64) -> Void)?

        /// Track toggle modifier state
        var toggleModifierIsDown = false
        /// In tap mode, whether the current toggle-modifier press can still be a tap.
        var toggleTap = ModifierTapDetector()
        /// Track hanja modifier state
        var hanjaModifierIsDown = false
        /// Debounce timer for Hanja trigger to prevent double-fire
        var lastHanjaTriggerTime: DispatchTime = .init(uptimeNanoseconds: 0)
        /// Track Control state for Control+Space
        var controlIsDown = false
        /// Tracks recovery and makes the CGEventTap -> IOKit handoff exactly-once.
        var failureTracker = EventTapFailureTracker()

        /// Whether recording mode is active (for Key Recorder in settings)
        var isRecordingKey = false
        var recordingState = KeyRecordingState()

        var lastToggleProvenance: ToggleProvenance?

        /// Whether the tap exists and the system still has it enabled.
        var isRunning: Bool { eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    }

    private let state = Guarded(State())

    /// Whether the event tap is currently running
    public var isRunning: Bool {
        state.withLock { $0.isRunning }
    }

    /// Callback for toggle. Called on the event-tap thread at the moment the key is
    /// seen, so it must be thread-safe and must not block.
    /// `InputModeCoordinator.requestToggle` is both.
    ///
    /// `eventTime` is when the key was pressed, on the same clock as
    /// `NSEvent.timestamp` (seconds of uptime), so the owner can tell keystrokes
    /// typed before the toggle from those typed after it.
    public var onToggle: (@Sendable (_ eventTime: TimeInterval) -> Void)? {
        get { state.withLock { $0.onToggle } }
        set { state.withLock { $0.onToggle = newValue } }
    }

    /// Callback for Hanja lookup. Called on the event-tap thread with the key's
    /// time, like `onToggle`, so it must be thread-safe and must not block.
    /// `InputModeCoordinator.requestHanjaLookup` is both.
    public var onHanjaLookup: (@Sendable (_ eventTime: TimeInterval) -> Void)? {
        get { state.withLock { $0.onHanjaLookup } }
        set { state.withLock { $0.onHanjaLookup = newValue } }
    }

    /// Callback for every keystroke the tap lets through to the app, with its
    /// time. Called on the event-tap thread, so it must be thread-safe and must not
    /// block. `InputModeCoordinator.notePassedKey` is both: it lets a toggle wait
    /// for the key typed just before it to reach IMK.
    ///
    /// Keys carrying ⌘ are left out. A menu takes those as shortcuts before any
    /// input method sees them, so waiting for one only delays the toggle.
    public var onKeyPassed: (@Sendable (_ eventTime: TimeInterval) -> Void)? {
        get { state.withLock { $0.onKeyPassed } }
        set { state.withLock { $0.onKeyPassed = newValue } }
    }

    /// Callback for when CGEventTap permanently fails and IOKit should take over.
    /// Delivered on the main queue.
    public var onTapFailed: (@Sendable () -> Void)? {
        get { state.withLock { $0.onTapFailed } }
        set { state.withLock { $0.onTapFailed = newValue } }
    }

    /// Whether recording mode is active (for Key Recorder in settings)
    public var isRecordingKey: Bool {
        get { state.withLock { $0.isRecordingKey } }
        set {
            state.withLock { state in
                state.isRecordingKey = newValue
                state.recordingState = KeyRecordingState()
            }
        }
    }

    /// Callback for key recording (settings UI). Delivered on the main queue.
    ///
    /// `@Sendable` because it is handed to `DispatchQueue.main.async` from the
    /// tap thread — which it always was, without the annotation that says so.
    public var onKeyRecorded: (@Sendable (_ keyCode: Int64, _ modifiers: UInt64) -> Void)? {
        get { state.withLock { $0.onKeyRecorded } }
        set { state.withLock { $0.onKeyRecorded = newValue } }
    }
    
    init() {}

    // MARK: - Start/Stop
    
    /// Start monitoring toggle keys. Main thread.
    /// - Returns: `true` if CGEventTap was created successfully, `false` otherwise
    @discardableResult
    public func start() -> Bool {
        state.withLock { startLocked($0) }
    }

    /// The body of `start()`, with the lock already held.
    ///
    /// The public entry points take the lock and call these; the internal paths
    /// call these directly. Splitting them is what lets one non-recursive
    /// acquisition cover a whole event, and it makes the re-entrant call sites
    /// visible instead of implicit in the lock's type.
    private func startLocked(_ state: State) -> Bool {
        if state.eventTap != nil && !state.isRunning { stopLocked(state) }
        guard state.eventTap == nil else {
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
        
        // Monitor flagsChanged AND keyDown events. In tap mode clicks too, since
        // a ⌘-click is not a tap of ⌘; press mode keeps clicks off this thread.
        var eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        if ConfigurationManager.shared.toggleTrigger == .tapAlone {
            eventMask |= (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
                | (1 << CGEventType.otherMouseDown.rawValue)
        }
        
        // Create event tap
        state.eventTap = CGEvent.tapCreate(
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
        
        guard let tap = state.eventTap else {
            DebugLogger.log("RightCommandSuppressor: Failed to create event tap")
            return false
        }
        // A tap is live the moment it is created. Until its source is on a run
        // loop nothing services it, and every keystroke on the system would
        // queue behind it — for up to `startAndWait`'s timeout, long enough for
        // the system to disable it. Off until the thread below owns it.
        CGEvent.tapEnable(tap: tap, enable: false)

        state.failureTracker.reset()
        
        // Service the tap from its own thread, never the main run loop.
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            DebugLogger.log("RightCommandSuppressor: Failed to create run loop source")
            CGEvent.tapEnable(tap: tap, enable: false)
            state.eventTap = nil
            return false
        }
        let thread = EventTapThread(source: source)
        guard thread.startAndWait() else {
            DebugLogger.log("RightCommandSuppressor: Event tap thread did not start")
            thread.stopRunLoop()
            CGEvent.tapEnable(tap: tap, enable: false)
            state.eventTap = nil
            return false
        }
        state.tapThread = thread

        // The hand-over from IOKit, at the last moment and not before: the
        // fallback keeps watching the keys until the tap is ready to, so a press
        // in between is seen by exactly one of them — never by neither (a gap
        // while the tap was being prepared) nor by both (a double toggle). The
        // close is a blocking IPC to hidd, and it runs under this lock; that is
        // safe only because the tap is still disabled, so no keystroke is
        // waiting on this lock yet.
        IOKitManager.shared.stop()
        CGEvent.tapEnable(tap: tap, enable: true)
        
        let config = ConfigurationManager.shared
        DebugLogger.log("RightCommandSuppressor: Started (toggle=\(config.toggleKeyBinding.displayName), hanja=\(config.hanjaKeyBinding.displayName))")
        return true
    }
    
    /// Recreate a running tap so its event mask matches the current toggle
    /// trigger (clicks are watched only in tap mode). Main thread.
    public func restartForTriggerChange() {
        state.withLock { state in
            guard state.eventTap != nil else { return }
            stopLocked(state)
            _ = startLocked(state)
        }
    }

    /// Stop monitoring. Callable from main or from the tap callback itself.
    public func stop() {
        state.withLock { stopLocked($0) }
    }

    /// The body of `stop()`, with the lock already held.
    private func stopLocked(_ state: State) {
        if let eventTap = state.eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        // Never waits for the thread: the callback may be the caller, and a waiting
        // main thread would hold the lock against a callback that needs it.
        state.tapThread?.stopRunLoop()
        state.tapThread = nil
        state.eventTap = nil
        state.toggleModifierIsDown = false
        state.toggleTap.interrupt()
        state.hanjaModifierIsDown = false
        state.controlIsDown = false
        DebugLogger.log("RightCommandSuppressor: Stopped")
    }
    
    // MARK: - Event Handling
    
    // Internal entry point permits event-sequence tests without installing a tap.
    func handleEvent(type: CGEventType, event: CGEvent,
                     toggle: KeyBinding? = nil, hanja: KeyBinding? = nil,
                     toggleEnabled: Bool? = nil, hanjaEnabled: Bool? = nil,
                     trigger: ToggleTrigger? = nil, recoveryFlags: UInt64? = nil,
                     excludedOverride: Bool? = nil) -> Unmanaged<CGEvent>? {
        state.withLock { state in
            handleEventLocked(state, type: type, event: event,
                              toggle: toggle, hanja: hanja,
                              toggleEnabled: toggleEnabled, hanjaEnabled: hanjaEnabled,
                              trigger: trigger, recoveryFlags: recoveryFlags,
                              excludedOverride: excludedOverride)
        }
    }

    // swiftlint:disable:next function_parameter_count cyclomatic_complexity function_body_length
    private func handleEventLocked(_ state: State, type: CGEventType, event: CGEvent,
                                   toggle: KeyBinding?, hanja: KeyBinding?,
                                   toggleEnabled: Bool?, hanjaEnabled: Bool?,
                                   trigger: ToggleTrigger?, recoveryFlags: UInt64?,
                                   excludedOverride: Bool?) -> Unmanaged<CGEvent>? {
        // Re-enable tap if disabled by system. Only timeouts count toward the
        // IOKit handoff: a user-input disable says nothing about the tap's
        // health, and re-enabling is all it asks for.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let recovery = type == .tapDisabledByTimeout
                ? state.failureTracker.recordDisable(at: CFAbsoluteTimeGetCurrent())
                : .reenable(attempt: 0)
            switch recovery {
            case .handoffToIOKit:
                // Stop/remove the tap before notifying the owner. The callback starts
                // IOKit on the main queue, so there is never an overlap window.
                DebugLogger.log("RightCommandSuppressor: Tap repeatedly disabled; stopping before IOKit handoff")
                let callback = state.onTapFailed
                stopLocked(state)
                DispatchQueue.main.async {
                    callback?()
                }
            case .reenable(let attempt):
                DebugLogger.log("RightCommandSuppressor: Tap disabled (\(attempt)/\(state.failureTracker.maxRetries)), re-enabling")
                let flags = recoveryFlags ?? CGEventSource.flagsState(.combinedSessionState).rawValue
                Self.forgetReleased(state, toggle: toggle ?? ConfigurationManager.shared.toggleKeyBinding,
                                    hanja: hanja ?? ConfigurationManager.shared.hanjaKeyBinding,
                                    flags: flags, hanjaEnabled: true)
                // A press that began while the tap was off was never seen whole.
                state.toggleTap.interrupt()
                if let tap = state.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            case .ignore:
                break
            }
            return Unmanaged.passUnretained(event)
        }
        
        // A click while the toggle modifier is down makes it a ⌘-click, not a tap.
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            state.toggleTap.interrupt()
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
        let toggleTrigger = trigger ?? config.toggleTrigger
        // Exclusion is enforced by this single early return, NOT by per-branch
        // guards below. Keep it that way: with two mechanisms, removing this return
        // would silently leave the toggle branch unguarded while hanja stayed safe.
        // Recording still needs the key; everything else — including modifier
        // stripping — must leave the event exactly as the app expects it. The one
        // exception is the release of a press this tap swallowed before focus
        // moved to the excluded app (see `endsSwallowedPress`).
        if excluded && !state.isRecordingKey {
            let swallow = Self.endsSwallowedPress(state, type: type, keyCode: keyCode,
                                                  flags: event.flags.rawValue, toggle: toggleBinding,
                                                  hanja: hanjaBinding, trigger: toggleTrigger)
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        let priTypeToggleEnabled = (toggleEnabled ?? !config.capsLockInputSourceSwitchEnabled) && !excluded
        if !priTypeToggleEnabled {
            state.toggleModifierIsDown = false
            state.toggleTap.interrupt()
        }
        // Hanja conversion turned off: its key is an ordinary key again.
        let priTypeHanjaEnabled = hanjaEnabled ?? config.hanjaEnabled
        if !priTypeHanjaEnabled || excluded {
            state.hanjaModifierIsDown = false
        }
        
        // Wait for modifier release or a regular key before deciding the binding.
        if state.isRecordingKey {
            if type == .flagsChanged || type == .keyDown {
                if let recorded = state.recordingState.consume(keyCode: keyCode, flags: event.flags.rawValue,
                                                         isModifierChange: type == .flagsChanged) {
                    let callback = state.onKeyRecorded
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
            state.controlIsDown = flags.contains(.maskControl)

            if keyCode == 57 {
                return Unmanaged.passUnretained(event)
            }
            
            // Dynamic toggle key — modifier key, single-key binding
            if priTypeToggleEnabled && toggleBinding.isModifierKey && toggleBinding.isModifierOnly && keyCode == toggleBinding.keyCode {
                let isPressed = ModifierKeyState.isDown(keyCode, flags: flags.rawValue)

                if toggleTrigger == .tapAlone {
                    // The modifier stays a modifier, so both edges reach the app.
                    if isPressed && !state.toggleModifierIsDown {
                        state.toggleModifierIsDown = true
                        state.toggleTap.press(at: Self.eventTime(of: event))
                    } else if !isPressed && state.toggleModifierIsDown {
                        state.toggleModifierIsDown = false
                        if state.toggleTap.release(at: Self.eventTime(of: event)) {
                            DebugLogger.log("RightCommandSuppressor: Toggle key tapped alone (\(toggleBinding.displayName)) - TOGGLE")
                            triggerToggle(state, event)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }

                if isPressed {
                    // Every press is swallowed, the app never sees this key go
                    // down. A press while one is already recorded means its
                    // release was lost (or the key reported DOWN twice): it does
                    // not toggle again, but passing it on would hand the app a
                    // press whose release this tap then swallows — a modifier
                    // stuck down in the app.
                    if !state.toggleModifierIsDown {
                        state.toggleModifierIsDown = true
                        DebugLogger.log("RightCommandSuppressor: Toggle key DOWN (\(toggleBinding.displayName)) - TOGGLE (instant)")
                        triggerToggle(state, event)
                    }
                    return nil  // Suppress the modifier event
                } else if state.toggleModifierIsDown {
                    // Toggle modifier released
                    state.toggleModifierIsDown = false
                    DebugLogger.log("RightCommandSuppressor: Toggle key UP (\(toggleBinding.displayName))")
                    return nil  // Suppress release
                }
            }
            
            // Dynamic hanja key — modifier key, single-key binding (only if different from toggle key)
            if priTypeHanjaEnabled && hanjaBinding.isModifierKey && hanjaBinding.isModifierOnly
                && keyCode == hanjaBinding.keyCode && keyCode != toggleBinding.keyCode {
                let isPressed = ModifierKeyState.isDown(keyCode, flags: flags.rawValue)
                
                if isPressed {
                    // Swallowed every time, like the toggle key's press above.
                    guard !state.hanjaModifierIsDown else { return nil }
                    state.hanjaModifierIsDown = true
                    state.toggleTap.interrupt()
                    
                    // Debounce: ignore if last trigger was within 500ms
                    let now = DispatchTime.now()
                    let elapsed = now.uptimeNanoseconds - state.lastHanjaTriggerTime.uptimeNanoseconds
                    let elapsedMs = elapsed / 1_000_000
                    if elapsedMs < 500 {
                        DebugLogger.log("RightCommandSuppressor: Hanja key DEBOUNCED (\(elapsedMs)ms)")
                        return nil
                    }
                    state.lastHanjaTriggerTime = now
                    
                    DebugLogger.log("RightCommandSuppressor: Hanja key DOWN (\(hanjaBinding.displayName)) - HANJA")
                    triggerHanjaLookup(state, event)
                    return nil  // Suppress
                } else if state.hanjaModifierIsDown {
                    state.hanjaModifierIsDown = false
                    DebugLogger.log("RightCommandSuppressor: Hanja key UP (\(hanjaBinding.displayName))")
                    return nil  // Suppress release
                }
            }
            
            return Unmanaged.passUnretained(event)
        }
        
        // Handle keyDown
        if type == .keyDown {
            // Any key while the toggle modifier is down makes it a shortcut, not a tap.
            state.toggleTap.interrupt()
            // Reconcile on every key: a release may have been lost while disabled.
            // Only ever down to up. The flags say the key is down, not that this
            // tap swallowed its press; claiming a press the app saw (the tap
            // started mid-hold, or was off) would swallow its release and leave
            // the modifier stuck down in the app.
            Self.forgetReleased(state, toggle: toggleBinding, hanja: hanjaBinding,
                                flags: event.flags.rawValue, hanjaEnabled: priTypeHanjaEnabled)
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
                    triggerToggle(state, event)
                    return nil
                } else {
                    // Combo toggle (e.g., Control+Space, Option+G)
                    let requiredFlags = CGEventFlags(rawValue: toggleBinding.modifiers)
                    if Self.hasExactModifiers(flags: event.flags, required: requiredFlags) {
                        if isAutorepeat { return nil }
                        DebugLogger.log("RightCommandSuppressor: Combo toggle (\(toggleBinding.displayName)) - TOGGLE triggered")
                        triggerToggle(state, event)
                        return nil
                    }
                }
            }
            
            // Regular key (non-modifier) as hanja — single key or combo
            // A matching toggle already returned above. Sharing a physical key is
            // valid when the two bindings require different modifiers.
            if priTypeHanjaEnabled && keyCode == hanjaBinding.keyCode && !hanjaBinding.isModifierKey {
                if hanjaBinding.isModifierOnly || Self.hasExactModifiers(flags: event.flags, required: CGEventFlags(rawValue: hanjaBinding.modifiers)) {
                    if isAutorepeat { return nil }
                    DebugLogger.log("RightCommandSuppressor: Regular key hanja (\(hanjaBinding.displayName)) - HANJA")
                    triggerHanjaLookup(state, event)
                    return nil
                }
            }
            
            // A modifier whose press PriType swallowed never went down as far as
            // the app knows, so keys typed while it is held must not carry it:
            // Right ⌘ + C types c, and a digit rolled over the Hanja key picks a
            // candidate instead of typing ⌥1 (¡). Before the candidate routing,
            // which leaves every modifier chord to the app.
            if priTypeToggleEnabled && toggleTrigger == .press && state.toggleModifierIsDown && toggleBinding.isModifierKey {
                event.flags = Self.removing(toggleBinding.keyCode, from: event.flags)
                DebugLogger.log("RightCommandSuppressor: Key with toggle modifier - stripped modifier (normal input)")
            }
            if priTypeHanjaEnabled && state.hanjaModifierIsDown && hanjaBinding.isModifierKey
                && hanjaBinding.isModifierOnly && hanjaBinding.keyCode != toggleBinding.keyCode {
                event.flags = Self.removing(hanjaBinding.keyCode, from: event.flags)
            }

            // Candidate keys while the Hanja window is up. Routed here rather than
            // through IMK because some clients (Terminal) never pass Escape, the
            // arrows or Return to the input method once nothing is marked.
            let pageCandidates = HanjaCandidateWindow.shownPageCandidates
            if pageCandidates > 0 {
                switch HanjaCandidateWindow.route(keyCode: keyCode, flags: event.flags, pageCandidates: pageCandidates) {
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
                    notePassedKey(state, event)
                    return Unmanaged.passUnretained(event)
                case .ignore:
                    break
                }
            }
            notePassedKey(state, event)
        }
        
        return Unmanaged.passUnretained(event)
    }

    /// Tell the owner a keystroke is on its way to the app (see `onKeyPassed`).
    private func notePassedKey(_ state: State, _ event: CGEvent) {
        guard !event.flags.contains(.maskCommand) else { return }
        state.onKeyPassed?(Self.eventTime(of: event))
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
    
    /// Whether an event reaching an excluded app must be swallowed after all:
    /// it is the toggle or Hanja key, and this tap swallowed that key's press.
    ///
    /// Focus can move while the key is held — Escape closing Spotlight over a
    /// remote-desktop window, with the toggle key still down from switching
    /// modes in it. The app never saw that key go down, so it must not see it
    /// come up, or see it go down again with no release in between: the press
    /// ends where it began. A press the app did see (tap mode passes both edges,
    /// or it went down in the excluded app) is not recorded, so it stays the
    /// app's to the end.
    ///
    /// Anything else passes and ends every recorded press whose key the flags
    /// show up, as `forgetReleased` does; the next press in a non-excluded app
    /// must toggle.
    private static func endsSwallowedPress(_ state: State, type: CGEventType, keyCode: Int64, // swiftlint:disable:this function_parameter_count
                                           flags: UInt64, toggle: KeyBinding, hanja: KeyBinding,
                                           trigger: ToggleTrigger) -> Bool {
        state.toggleTap.interrupt()
        if trigger != .press { state.toggleModifierIsDown = false }
        if type == .flagsChanged {
            let pressed = ModifierKeyState.isDown(keyCode, flags: flags)
            if state.toggleModifierIsDown && keyCode == toggle.keyCode {
                if !pressed { state.toggleModifierIsDown = false }
                return true
            }
            if state.hanjaModifierIsDown && keyCode == hanja.keyCode {
                if !pressed { state.hanjaModifierIsDown = false }
                return true
            }
        }
        forgetReleased(state, toggle: toggle, hanja: hanja, flags: flags, hanjaEnabled: true)
        return false
    }

    /// Clear a recorded press whose key `flags` shows up: its release was lost.
    /// Never sets one — see the keyDown path.
    private static func forgetReleased(_ state: State, toggle: KeyBinding, hanja: KeyBinding,
                                       flags: UInt64, hanjaEnabled: Bool) {
        if !ModifierKeyState.isDown(toggle.keyCode, flags: flags) {
            state.toggleModifierIsDown = false
        }
        if !hanjaEnabled || !ModifierKeyState.isDown(hanja.keyCode, flags: flags) {
            state.hanjaModifierIsDown = false
        }
    }

    /// `flags` without the modifier of `keyCode`: its side's device bit, and the
    /// shared bit too unless the other side's key is also down.
    private static func removing(_ keyCode: Int64, from flags: CGEventFlags) -> CGEventFlags {
        var newFlags = flags
        newFlags.remove(CGEventFlags(rawValue: ModifierKeyState.mask(for: keyCode)))
        if !ModifierKeyState.isDown(ModifierKeyState.opposite(keyCode), flags: flags.rawValue) {
            newFlags.remove(modifierMask(for: keyCode))
        }
        return newFlags
    }

    /// Whether a combo binding's modifiers are exactly the ones held. A superset
    /// is another shortcut: ⌃Space must not take ⌃⌥Space (next input source) or
    /// ⌃⌘Space (emoji). Caps Lock and Fn are state rather than part of a
    /// shortcut, and bindings are recorded without them.
    static func hasExactModifiers(flags: CGEventFlags, required: CGEventFlags) -> Bool {
        flags.intersection(shortcutModifiers) == required.intersection(shortcutModifiers)
    }

    static let shortcutModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    /// Where the most recent toggle came from.
    ///
    /// Exists for the on-device verification run, which has to tell a key a
    /// person pressed from one a script posted. Both reach this callback — that
    /// is what a session tap is — so a run driven by `osascript` would otherwise
    /// report the toggle key working when nothing about the hardware path had
    /// been exercised. The window server stamps a posted event with the posting
    /// process; a key the hardware produced carries 0.
    ///
    /// One field read per toggle, which a person performs a few times a minute.
    public struct ToggleProvenance: Sendable, Equatable {
        public let eventTime: TimeInterval
        /// The process that posted the event, or 0 for hardware.
        public let sourcePID: Int64
        public var isHardware: Bool { sourcePID == 0 }

        public init(eventTime: TimeInterval, sourcePID: Int64) {
            self.eventTime = eventTime
            self.sourcePID = sourcePID
        }
    }

    /// The most recent toggle's provenance, or nil if none has been seen.
    public var lastToggleProvenance: ToggleProvenance? {
        state.withLock { $0.lastToggleProvenance }
    }

    private func triggerToggle(_ state: State, _ event: CGEvent) {
        state.lastToggleProvenance = ToggleProvenance(
            eventTime: Self.eventTime(of: event),
            sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID))
        // Hand the toggle over right here, on the tap thread. The owner records it
        // with the key's time and applies it on main (`InputModeCoordinator
        // .requestToggle`), so the keystroke typed next cannot overtake it. IMK
        // commit and keyboard-override work still stay off this callback, which
        // protects against `kCGEventTapDisabledByTimeout`.
        state.onToggle?(Self.eventTime(of: event))
    }

    /// The event's time on `NSEvent.timestamp`'s clock. AppKit reads a CGEvent
    /// timestamp as nanoseconds of uptime; a synthetic event may carry 0, so fall
    /// back to now.
    static func eventTime(of event: CGEvent) -> TimeInterval {
        event.timestamp == 0
            ? ProcessInfo.processInfo.systemUptime
            : TimeInterval(event.timestamp) / 1_000_000_000
    }
    
    private func triggerHanjaLookup(_ state: State, _ event: CGEvent) {
        // A Hanja key while the toggle modifier is down is not a lone tap of it.
        state.toggleTap.interrupt()
        // Same hand-over as the toggle, so the two keep their relative order and a
        // key typed after the Hanja key reaches the candidate window.
        state.onHanjaLookup?(Self.eventTime(of: event))
    }
}

/// The thread whose run loop services the event tap.
///
/// The run loop exits when `stopRunLoop()` removes the source, which ends the
/// thread. One instance serves one `start()`; a restart creates a new thread.
///
/// It owns a `Thread` rather than being one. `Thread` is not `Sendable`, so a
/// subclass could only ever be `@unchecked`, while the body of a thread created
/// from a closure captures nothing but `Sendable` values — the guarded state and
/// a semaphore — and the compiler checks that for itself.
final class EventTapThread: Sendable {
    private final class State {
        let source: CFRunLoopSource
        var runLoop: CFRunLoop?
        /// Set by a `stopRunLoop()` that arrives before the body attaches, so the
        /// body knows not to attach at all.
        var cancelled = false
        var finished = false

        init(source: CFRunLoopSource) {
            self.source = source
        }
    }

    private let state: Guarded<State>
    private let started = DispatchSemaphore(value: 0)

    init(source: CFRunLoopSource) {
        state = Guarded(State(source: source))
    }

    /// Whether the thread's body has returned. Nothing in the app waits on this;
    /// a test does, to see that a stop really ends the thread.
    var isFinished: Bool {
        state.withLock { $0.finished }
    }

    /// The body the thread runs. Internal so a test can drive the cancelled
    /// branch without starting a thread that would never return.
    func runBody() {
        let loop = CFRunLoopGetCurrent()
        // Attaching the source and publishing the loop happen under the same lock
        // that `stopRunLoop()` takes, so a stop can never fall between them.
        let attached = state.withLock { state -> Bool in
            guard !state.cancelled else { return false }
            CFRunLoopAddSource(loop, state.source, .commonModes)
            state.runLoop = loop
            return true
        }
        started.signal()
        defer { state.withLock { $0.finished = true } }
        guard attached else { return }
        // Returns once `stopRunLoop()` has removed the only source.
        CFRunLoopRun()
    }

    /// Start the thread and wait until its run loop owns the tap source.
    func startAndWait(timeout: DispatchTimeInterval = .seconds(2)) -> Bool {
        let thread = Thread { [self] in runBody() }
        thread.name = "com.pritype.eventtap"
        // Every keystroke on the system waits on this thread.
        thread.qualityOfService = .userInteractive
        thread.start()
        guard started.wait(timeout: .now() + timeout) == .success else { return false }
        return !state.withLock { $0.cancelled }
    }

    /// Wake the run loop so a signalled version-0 source is serviced (for tests;
    /// a mach-port source such as the tap wakes the loop on its own).
    func wake() {
        state.withLock { $0.runLoop.map(CFRunLoopWakeUp) }
    }

    /// Detach the source and let the run loop exit. Safe from any thread,
    /// including this one, and before the thread has attached the source.
    func stopRunLoop() {
        state.withLock { state in
            guard let loop = state.runLoop else {
                // Not attached yet: the body sees this and never attaches.
                state.cancelled = true
                return
            }
            CFRunLoopRemoveSource(loop, state.source, .commonModes)
            CFRunLoopStop(loop)
            CFRunLoopWakeUp(loop)
            state.runLoop = nil
        }
    }
}
