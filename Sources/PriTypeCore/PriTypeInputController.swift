import Cocoa
import InputMethodKit
import LibHangul
import Carbon.HIToolbox

/// Thin IMK edge of the input pipeline.
///
/// The controller owns nothing but the IMK lifecycle. Everything session-scoped —
/// client, analyzed context, delivery adapter, duplicate-keyDown state, focus-loss
/// safety net — lives in a single `InputSession`, and EVERY composition-ending event
/// (app deactivate, deactivateServer, mouse commit, custom toggle, Caps Lock mode
/// switch) funnels into `InputSession.finalize(reason:)`, the one host-agnostic
/// commit path.
///
/// ```
/// keyDown ──► handle() ──► ensureSession ──► dedup ──► secure gate ──► HangulComposer
///                                                                          │
///                  TextDeliveryAdapter (marked / direct / immediate) ◄─────┘
///
/// toggle key ──► InputModeCoordinator ──► performPriTypeModeTransition ─┐
/// Caps Lock  ──► setValue(inputMode)  ─────────────────────────────────┤
/// app deactivate / deactivateServer / mouse commit ────────────────────┴─► session.finalize
/// ```
@objc(PriTypeInputController)
public class PriTypeInputController: IMKInputController, @unchecked Sendable {
    // Two PriType input modes registered in Info.plist ComponentInputModeDict.
    // Korean composes; English is a pure pass-through (ABC layout override).
    // macOS Caps Lock / input-source switching moves between these two modes.
    private static let priTypeInputSourceID = "com.pritype.inputmethod.v2"          // Korean mode (== bundle id)
    private static let priTypeEnglishInputModeID = "com.pritype.inputmethod.v2.english"
    // MARK: - Shared State
    //
    // THREAD SAFETY INVARIANTS:
    // These static properties use `nonisolated(unsafe)` for Swift 6 strict concurrency compliance.
    //
    // WHY NOT @MainActor?
    // IMKInputController callbacks (handle, activateServer, etc.) are NOT @MainActor-isolated.
    // Swift 6 compiler would reject @MainActor property access from these callbacks.
    //
    // IMK guarantees main thread execution by design:
    // 1. `sharedComposer`: Created once at startup, accessed only via IMK callbacks
    // 2. `sharedController`: Read/written only in activateServer/deactivateServer
    //
    // This is a documented limitation of integrating Swift 6 strict concurrency with
    // legacy Objective-C frameworks like InputMethodKit.

    /// Shared composer instance for toggle key handler access
    /// - Warning: Access from main thread only (guaranteed by IMK, not compiler-enforced)
    public static let sharedComposer = HangulComposer()
    private var composer: HangulComposer { Self.sharedComposer }

    /// Last active controller reference for external toggle access
    /// - Warning: Access from main thread only (guaranteed by IMK, not compiler-enforced)
    nonisolated(unsafe) public static weak var sharedController: PriTypeInputController?

    /// The live input session (client + context + adapter + dedup + focus-loss net).
    /// Kept across deactivateServer — async Hanja callbacks and a `handle()` arriving
    /// before the next activateServer still need the adapter/context — and replaced
    /// when a different client appears.
    private var session: InputSession?
    private var pendingSystemMode: DeferredInputMode?

    /// The last input mode macOS told us it had selected.
    ///
    /// IMK re-asserts the selected input source on every activation, so a plain
    /// focus change delivers `setValue` again with the mode the system already
    /// had. A custom toggle deliberately does not touch that system selection
    /// (see `performPriTypeModeTransition`), so after one the composer and the
    /// system disagree, and applying the re-assertion would snap the user back to
    /// whichever mode the input source happens to name — Korean or English —
    /// every time they leave a window and come back.
    ///
    /// The system value only ever changes when the user really does switch input
    /// source, so a repeat of the value we already saw identifies a re-assertion.
    /// Static because the selection is systemwide while controllers are per
    /// client: a freshly created controller must not mistake a re-assertion for a
    /// first observation.
    /// - Warning: Access from main thread only (guaranteed by IMK).
    nonisolated(unsafe) private static var lastSystemMode: InputMode?

    /// Session-derived views for collaborators (Hanja lookup in `HangulComposer`).
    public var currentAdapter: (any HangulComposerDelegate)? { session?.adapter }
    public var cachedContext: ClientContext? { session?.context }

    #if DEBUG
    private var debugHandleLogCount = 0
    #endif
    private var lastKeyboardOverrideClientID: ObjectIdentifier?
    private var lastKeyboardOverrideTime: CFAbsoluteTime = 0

    deinit {
        // The session's block-based NSWorkspace observer is NOT auto-removed; the
        // session disarms it in deinit, but do it eagerly here too.
        session?.disarmFocusLossFinalizer()
    }

    // MARK: - Session Management

    /// The shared engine may only be finalized by its current controller.
    /// Some hosts deliver a key before activation, or deactivate the previous
    /// controller after the new one is already composing.
    private func claimActiveController() {
        if let previous = Self.sharedController, previous !== self {
            previous.session?.finalize(reason: .deactivateServer)
            previous.session?.disarmFocusLossFinalizer()
            previous.session?.markContextStale()
        }
        Self.sharedController = self
        if let pending = pendingSystemMode {
            pendingSystemMode = nil
            if let mode = pending.resolve(currentRevision: composer.modeSelectionRevision) {
                // Finalize only on a real mode change, but ALWAYS re-select: the
                // selection bumps `modeSelectionRevision`, which is what retires the
                // other controllers' pending values. Skipping the call for a no-op
                // mode would leave an older pending (e.g. English) still resolvable,
                // so a late-activating stale controller could re-apply it.
                if composer.inputMode != mode {
                    session?.finalize(reason: .systemModeSwitch)
                }
                composer.setInputMode(mode)
            }
        }
    }

    /// Return the session for `client`, creating or refreshing it as needed.
    /// - A different client object ⇒ new session (full context analysis).
    /// - Same client after deactivateServer ⇒ re-analyze (focus may have moved to a
    ///   different field of the same app, e.g. a password field).
    /// - Finder lightweight context ⇒ re-analyze per keystroke (desktop vs. rename
    ///   field can only be told apart by coordinates at keystroke time).
    private func ensureSession(for client: IMKTextInput) -> InputSession {
        if let session, session.matches(client) {
            if session.contextNeedsRefresh || session.context.isLightweight {
                session.refreshContext(ClientContextDetector.analyze(client: client))
                session.armFocusLossFinalizer()
            } else if session.context.isLightweight && session.context.isFinder {
                session.refreshContext(ClientContextDetector.analyze(client: client))
            }
            return session
        }

        DebugLogger.log("PriTypeInputController: client changed or no session, analyzing (Slow Path)")
        session?.finalize(reason: .deactivateServer)
        let newSession = InputSession(
            client: client,
            context: ClientContextDetector.analyze(client: client),
            composer: composer
        )
        session?.disarmFocusLossFinalizer()
        session = newSession
        newSession.armFocusLossFinalizer()
        syncRomanKeyboardLayout(for: client)
        return newSession
    }

    /// Route a composition-ending event to the single finalize path. Prefers the
    /// session (it knows the delivery mode — direct insertion must NOT re-insert);
    /// falls back to a detached marked-text finalize when IMK hands us a sender the
    /// session has never seen.
    private func finalizeActiveComposition(sender: Any?, reason: CompositionFinalizeReason) {
        guard Self.sharedController === self else { return }
        let senderClient = sender as? IMKTextInput
        if let session {
            if session.adapter is DirectInsertionAdapter
                || senderClient == nil
                || session.matches(senderClient!) {
                session.finalize(reason: reason)
                return
            }
        }
        if let senderClient, composer.hasActiveComposition {
            InputSession.finalizeMarkedComposition(composer: composer, client: senderClient, reason: reason)
        } else {
            session?.finalize(reason: reason)
        }
    }

    // MARK: - Keyboard Layout (English pass-through support)

    private func syncRomanKeyboardLayout(for client: IMKTextInput, force: Bool = false) {
        guard composer.inputMode == .english else { return }
        guard let layoutID = InputSourceManager.enabledRomanKeyboardLayoutID(
            in: InputSourceManager.shared.getEnabledKeyboardInputSources().map(\.id)
        ) else { return }
        let clientID = ObjectIdentifier(client as AnyObject)
        let now = CFAbsoluteTimeGetCurrent()
        guard force || lastKeyboardOverrideClientID != clientID || now - lastKeyboardOverrideTime > 0.5 else {
            return
        }

        let selector = NSSelectorFromString("overrideKeyboardWithKeyboardNamed:")
        let object = client as AnyObject
        guard object.responds(to: selector) else {
            DebugLogger.log("PriTypeInputController: client does not support keyboard override")
            return
        }

        _ = object.perform(selector, with: layoutID)
        lastKeyboardOverrideClientID = clientID
        lastKeyboardOverrideTime = now
        DebugLogger.log("PriTypeInputController: override keyboard layout -> \(layoutID)")
    }

    // MARK: - Mode Transitions (한/영)

    public func performPriTypeModeTransition(source: InputModeCoordinator.ToggleSource) {
        guard let session else {
            DebugLogger.log("PriTypeInputController: no current session for mode transition (\(source))")
            return
        }

        let nextMode = composer.inputMode.toggled
        DebugLogger.log("PriTypeInputController: mode transition \(composer.inputMode) -> \(nextMode) source=\(source)")

        session.finalize(reason: .modeTransition)
        composer.clearLocalBuffer()
        composer.setInputMode(nextMode)
        syncRomanKeyboardLayout(for: session.client, force: true)

        // Report the switch to macOS so the menu-bar input source stops
        // contradicting the composer. Deferred off the hot path, and only after
        // the composer has already switched, so a slow or failing selection
        // cannot delay the next keystroke. See InputSourceManager.
        let selectEnglish = nextMode == .english
        DispatchQueue.main.async {
            InputSourceManager.shared.selectPriTypeMode(english: selectEnglish)
        }
    }

    // A custom toggle switches the composer synchronously and then reports the
    // result to macOS. `selectInputMode:` is not used for that: routing through
    // the client can transfer a Latin-only host to real ABC (upstream #11).

    // MARK: - IMK Lifecycle

    // 입력기가 활성화될 때 호출 - 새 세션 시작
    override public func activateServer(_ sender: Any!) {
        #if DEBUG
        assert(Thread.isMainThread, "IMK activateServer must run on main thread")
        #endif
        super.activateServer(sender)
        claimActiveController()
        // NOTE: Focus changes never reset `composer.inputMode`. The Korean/English
        // state is owned solely by the toggle path and the `setValue` ingress, so
        // switching apps preserves whatever mode the user last chose.
        if let client = sender as? IMKTextInput {
            syncRomanKeyboardLayout(for: client, force: true)

            if let existing = session, existing.matches(client), !existing.contextNeedsRefresh {
                // Repeated activation in Chromium must preserve direct-preedit tracking.
                existing.armFocusLossFinalizer()
            } else {
                session?.finalize(reason: .deactivateServer)
                // PERFORMANCE: Analyze context ONCE per activation (lightweight — no
                // client IPC) and let `ensureSession` upgrade it lazily. This avoids
                // heavy IPC calls (validAttributes, coordinates) on every focus change.
                let newSession = InputSession(
                    client: client,
                    context: ClientContextDetector.analyzeForActivation(client: client),
                    composer: composer
                )
                session?.disarmFocusLossFinalizer()
                session = newSession
                newSession.armFocusLossFinalizer()
                DebugLogger.log("Activated for client: \(newSession.context.bundleId) (Lightweight Context)")
            }
        } else {
            // Fallback if sender is not IMKTextInput (rare). Keep the old session's
            // adapter alive for async Hanja callbacks, but stop trusting its context
            // and stop watching focus on its behalf.
            session?.disarmFocusLossFinalizer()
            session?.markContextStale()
        }

        // Set as active controller for toggle access
        Self.sharedController = self
    }

    override public func deactivateServer(_ sender: Any!) {
        #if DEBUG
        assert(Thread.isMainThread, "IMK deactivateServer must run on main thread")
        #endif
        // Fallback finalize. The primary path is the session's focus-loss observer (it
        // fires earlier, while the host still accepts input); by the time
        // deactivateServer runs, native hosts like KakaoTalk have already resigned and
        // ignore insertText. If the observer already committed, this is a no-op.
        finalizeActiveComposition(sender: sender, reason: .deactivateServer)
        // NOTE: Do NOT clear localTextBuffer here.
        // Cross-app hanja leaking is prevented by bundleId matching in handleHanjaLookup(),
        // not by clearing the buffer. Clearing would make same-app hanja lookup impossible.
        super.deactivateServer(sender)
        // Keep the session alive — async Hanja callbacks need the adapter, and a
        // handle() arriving before the next activateServer needs the context. But:
        // - disarm the focus-loss observer: the composer is shared, so a stale
        //   observer firing later would flush a NEWER session's composition into
        //   THIS client (the cross-app commit-leak class);
        // - mark the context stale so the next handle() re-analyzes it.
        session?.disarmFocusLossFinalizer()
        session?.markContextStale()
        if Self.sharedController === self { Self.sharedController = nil }
    }

    // Match the native IMK path used by DINKIssTyle: ask IMK for flagsChanged
    // so TIS can drive Caps Lock language switching, then pass modifier events
    // through without doing any work in handle().
    override public func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    override public func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        if tag == Int(kTextServiceInputModePropertyTag) {
            guard let inputModeID = value as? String, !inputModeID.isEmpty else {
                DebugLogger.log("PriTypeInputController: ignored empty input mode property")
                return
            }

            // Route the two PriType modes to the single composer source of truth.
            // This is how macOS Caps Lock / input-source switching between the
            // Korean and English modes reaches the composer — synchronously, so the
            // next keyDown already sees the new mode (no first-key race).
            let targetMode: InputMode?
            switch inputModeID {
            case Self.priTypeEnglishInputModeID: targetMode = .english
            case Self.priTypeInputSourceID:      targetMode = .korean
            default:                             targetMode = nil
            }
            DebugLogger.log("PriTypeInputController: setValue inputMode='\(inputModeID)' target=\(String(describing: targetMode)) current=\(composer.inputMode)")
            guard let targetMode else {
                super.setValue(value, forTag: tag, client: sender)
                return
            }

            // A repeat of the mode the system already had is IMK re-asserting the
            // input source across a focus change, not the user switching it. The
            // composer may legitimately differ from it because of a custom toggle,
            // so honouring it here would undo that toggle on every refocus.
            guard Self.lastSystemMode != targetMode else {
                DebugLogger.log("PriTypeInputController: ignored re-asserted system mode \(targetMode)")
                return
            }
            Self.lastSystemMode = targetMode

            // IMK may send a new controller's mode before activating it, or
            // finish notifying an old one after focus has moved. Only the owner
            // mutates the shared engine; pending modes apply on activation/keyDown.
            guard Self.sharedController === self else {
                pendingSystemMode = DeferredInputMode(mode: targetMode, revision: composer.modeSelectionRevision)
                return
            }

            if composer.inputMode != targetMode {
                DebugLogger.log("PriTypeInputController: macOS selected PriType \(targetMode) mode")
                // System-driven mode switches end composition through the same
                // single path as everything else (not via a stale delegate).
                finalizeActiveComposition(sender: sender, reason: .systemModeSwitch)
            }
            composer.setInputMode(targetMode)
            if let client = sender as? IMKTextInput {
                syncRomanKeyboardLayout(for: client, force: true)
            }
            return
        }

        super.setValue(value, forTag: tag, client: sender)
    }

    // MARK: - Keystroke Pipeline

    override public func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        #if DEBUG
        assert(Thread.isMainThread, "IMK handle must run on main thread")
        #endif
        guard let event = event, let client = sender as? IMKTextInput else { return false }

        guard event.type == .keyDown else {
            return false
        }

        claimActiveController()

        // 1. Resolve the session FIRST — all subsequent logic uses its fresh context.
        let session = ensureSession(for: client)

        // A toggle pressed just before this key may still be waiting for its hop
        // from the key-monitor thread. Apply it now so this key lands in the new mode.
        InputModeCoordinator.shared.applyPendingToggles()

        // 2. Duplicate-keyDown suppression. Some hosts (observed: KakaoTalk) deliver
        // the same physical keyDown to the IME twice. That double-processes input —
        // notably one backspace decomposing TWO jamo, i.e. a composing syllable
        // "deleted all at once". Drop the exact re-delivery and replay the original
        // result. Host-event-level, so it applies in every delivery mode.
        let keyDownSnapshot = KeyDownSnapshot(timestamp: event.timestamp, keyCode: event.keyCode, isARepeat: event.isARepeat, characters: event.characters, modifiers: event.modifierFlags.rawValue)
        if session.registerKeyDown(keyDownSnapshot) {
            DebugLogger.log("PriTypeInputController: dropped duplicate keyDown keyCode=\(event.keyCode)")
            return session.lastHandleResult
        }

        #if DEBUG
        if debugHandleLogCount < 200 {
            debugHandleLogCount += 1
            DebugLogger.log("PriTypeInputController: handle keyCode=\(event.keyCode) repeat=\(event.isARepeat) mode=\(composer.inputMode) modifiers=\(event.modifierFlags.rawValue) bundle=\(session.context.bundleId) lightweight=\(session.context.isLightweight) immediate=\(session.context.shouldUseImmediateMode)")
        }
        #endif

        // 3. Mark keystroke with current app's bundleId for cross-app hanja validation
        composer.markKeystroke(bundleId: session.context.bundleId)

        // 4. DYNAMIC CHECK: Secure Input (password fields) — raw pass-through.
        if shouldPassThroughSecureInput(client: client, context: session.context) {
            session.discardForSecureInput()
            session.recordHandleResult(false)
            return false
        }

        // 5. The delivery policy can flip mid-session (experimental flag toggled in
        // settings); make sure the adapter still matches before composing into it.
        session.ensureAdapterMatchesPolicy()

        // A direct-live preedit has no IMK marked range, so caret/document changes
        // must be detected explicitly before this key mutates the Hangul engine.
        session.prepareForInput()

        // 6. Compose.
        let handled = composer.handle(event, delegate: session.adapter)
        session.recordHandleResult(handled)
        return handled
    }

    private func shouldPassThroughSecureInput(client: IMKTextInput, context: ClientContext) -> Bool {
        let bundleId = context.bundleId
        let isSystemSecureClient = SecureInputPolicy.isSystemSecureClient(bundleId)
        let hasGlobalSecureInput = IsSecureEventInputEnabled()

        // selectedRange is synchronous client IPC. Probe only when it can change the
        // decision: a global secure-input warning. System
        // secure clients are known up front and must not be queried.
        var hasInvalidSelection = false
        if !isSystemSecureClient && hasGlobalSecureInput {
            hasInvalidSelection = client.selectedRange().location == NSNotFound
        }

        let signals = SecureInputSignals(
            bundleId: bundleId,
            hasTextInputCapability: context.hasTextInputCapability,
            hasInvalidSelection: hasInvalidSelection,
            hasGlobalSecureInput: hasGlobalSecureInput
        )
        let shouldPassThrough = SecureInputPolicy.shouldPassThrough(signals)

        if shouldPassThrough {
            if isSystemSecureClient {
                DebugLogger.log("Secure Input: system secure client (\(bundleId)), passing through")
            } else if hasInvalidSelection {
                DebugLogger.log("Secure Input: invalid selection in '\(bundleId)', passing through")
            } else {
                DebugLogger.log("Secure Input: global flag + no text capability in '\(bundleId)', passing through")
            }
        } else if hasGlobalSecureInput {
            DebugLogger.log("Secure Input: ignoring stale global flag for capable field in '\(bundleId)'")
        }

        return shouldPassThrough
    }

    // 마우스 클릭 등으로 조합 영역 외부 클릭 시 조합 커밋
    override public func commitComposition(_ sender: Any!) {
        #if DEBUG
        assert(Thread.isMainThread, "IMK commitComposition must run on main thread")
        #endif
        finalizeActiveComposition(sender: sender, reason: .mouseCommit)
        if Self.sharedController === self {
            composer.clearLocalBuffer()
            session?.markContextStale()
        }
        super.commitComposition(sender)
    }

    // MARK: - Input Method Menu

    /// Returns custom menu for the input method (shown in system input source menu)
    override public func menu() -> NSMenu! {
        let menu = NSMenu()

        // Settings
        let settingsItem = NSMenuItem(title: "PriType 설정...", action: #selector(openSettings(_:)), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // About
        let aboutItem = NSMenuItem(title: "PriType 정보", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        return menu
    }

    @objc private func openSettings(_ sender: Any?) {
        DebugLogger.log("Opening settings")
        DispatchQueue.main.async {
            SettingsWindowController.shared.showSettings()
        }
    }

    @MainActor
    @objc private func showAbout(_ sender: Any?) {
        DebugLogger.log("Showing about")
        AboutInfo.showAlert()
    }
}
