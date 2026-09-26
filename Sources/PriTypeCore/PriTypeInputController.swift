import Cocoa
import InputMethodKit
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
    private static let priTypeInputSourceID = PreferencesDomain.priTypeSuiteName    // Korean mode (== bundle id)
    private static let priTypeEnglishInputModeID = PreferencesDomain.priTypeSuiteName + ".english"
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

    /// Reports sent to macOS whose `setValue` echo has not come back yet.
    /// - Warning: Access from main thread only.
    nonisolated(unsafe) private static var echoFilter = SystemModeEchoFilter()

    /// Forget what macOS last selected (tests: each starts from a fresh system state).
    static func resetSystemModeTracking() {
        lastSystemMode = nil
        echoFilter.reset()
    }

    /// Tells macOS which PriType mode a custom toggle selected, so the menu-bar
    /// input source follows. Called on main right after the toggle; the default
    /// defers the TIS selection off the hot path. A harness replaces it: driving
    /// real controllers must not change the machine's input source.
    /// - Warning: Access from main thread only.
    nonisolated(unsafe) public static var systemModeReporter: (InputMode) -> Void = { mode in
        DispatchQueue.main.async {
            var expected = false
            let selected = InputSourceManager.shared.selectPriTypeMode(english: mode == .english) {
                echoFilter.expect(mode, at: ProcessInfo.processInfo.systemUptime)
                expected = true
            }
            // A failed selection sends no echo; do not wait for one.
            if expected && !selected {
                echoFilter.withdrawLatest()
            }
        }
    }

    /// Session-derived views for collaborators (Hanja lookup in `HangulComposer`).
    public var currentAdapter: (any HangulComposerDelegate)? { session?.adapter }
    public var cachedContext: ClientContext? { session?.context }
    /// The client this controller is typing into: the `sender` IMK passed with
    /// the session's keys. The Hanja lookup reads and replaces text through it,
    /// the same client every other edit goes to.
    public var currentClient: IMKTextInput? { session?.client }

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
            previous.leaveComposition()
            previous.session?.disarmFocusLossFinalizer()
            previous.session?.markContextStale()
            // Open candidates belong to the previous client. Its deactivation
            // would close them, but IMK may deliver that only after this
            // activation — and then it no longer owns the engine and leaves
            // them up, with the event tap routing this client's keys to them.
            composer.dismissHanjaCandidates(reason: "another client took over")
        }
        if Self.sharedController !== self {
            servingSince = Self.now()
            // The key history belongs to the field that typed it, and web fields
            // share one client: a reactivation may be another field.
            composer.forgetKeyHistory()
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
                    Self.commitCarriedComposition()
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
    /// - Lightweight context from activation ⇒ full analysis on the first key. For
    ///   Finder that is where desktop and rename field are told apart, by the
    ///   coordinates the field reports once it is actually typed into.
    private func ensureSession(for client: IMKTextInput) -> InputSession {
        let secureInput = Self.globalSecureInput(for: client)
        if let session, session.matches(client) {
            // Also when a Secure Input warning has come up since the context was
            // analyzed without asking for the attributes the policy then reads:
            // the optimistic default must not stand in for the client's answer.
            if session.contextNeedsRefresh || session.context.isLightweight
                || (secureInput && !session.context.capabilityProbed) {
                session.refreshContext(ClientContextDetector.analyze(
                    client: client,
                    knownBundleId: session.context.bundleId,
                    secureInputActive: secureInput))
                session.armFocusLossFinalizer()
            }
            return session
        }

        DebugLogger.log("PriTypeInputController: client changed or no session, analyzing (Slow Path)")
        let newSession = replaceSession(client: client, context: ClientContextDetector.analyze(
            client: client, secureInputActive: secureInput))
        syncRomanKeyboardLayout(for: client)
        return newSession
    }

    /// End the current session's composition and make a new one for `client` the
    /// live session. The old session stops watching focus: the composer is shared,
    /// so its observer firing later would flush the new session's text into the
    /// old client. `context` is evaluated after the old composition is committed,
    /// so the old client's commit never waits on the new client's analysis IPC.
    private func replaceSession(client: IMKTextInput, context: @autoclosure () -> ClientContext) -> InputSession {
        if Self.carriedComposition == nil {
            session?.finalize(reason: .deactivateServer)
        }
        session?.disarmFocusLossFinalizer()
        let newSession = InputSession(client: client, context: context(), composer: composer)
        session = newSession
        servingSince = Self.now()
        newSession.armFocusLossFinalizer()
        return newSession
    }

    // MARK: - Activation churn

    /// How long a session must have been live for leaving it to commit its
    /// syllable.
    ///
    /// Right after an app switch IMK can hand the first key to a controller it
    /// retires a few milliseconds later, in favour of another controller of the
    /// same app (measured: 4 ms in KakaoTalk, 16 ms in TextEdit). A syllable
    /// committed into the retired client reaches no field; the jamo was simply
    /// gone (카톡 came out as ㅏ톡). A person cannot focus a field, type and move
    /// on inside this window, so a composition left that fast is handed to the
    /// next session instead.
    static let churnWindow: TimeInterval = 0.05

    /// The clock `churnWindow` is measured on. The IMK harness puts its own in.
    /// - Warning: Access from main thread only.
    nonisolated(unsafe) public static var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// When this controller last took the engine over, or started a new session.
    private var servingSince: TimeInterval = -.infinity

    /// A composition whose session IMK retired within `churnWindow`, and when,
    /// waiting for the session that takes over (`continueCarriedComposition(in:)`).
    /// - Warning: Access from main thread only.
    nonisolated(unsafe) private static var carriedComposition: (session: InputSession, since: TimeInterval)?

    /// This controller is losing the engine: commit its syllable, or carry it
    /// over if IMK is retiring the session too soon for a person to have left it.
    private func leaveComposition() {
        guard let session else { return }
        if leavesTooSoon {
            Self.carry(session)
        } else {
            session.finalize(reason: .deactivateServer)
        }
    }

    /// Whether a marked syllable is live in a session served for less than
    /// `churnWindow`. Direct insertion already wrote it into the document.
    private var leavesTooSoon: Bool {
        composer.hasActiveComposition && session?.adapter.deliveryMode == .markedText
            && Self.now() - servingSince < Self.churnWindow
    }

    /// Hold `session`'s syllable for the session that takes over. If none does,
    /// it is committed where it was typed once the wait for a reactivation is up.
    private static func carry(_ session: InputSession) {
        // Already carried: the syllable is still that session's, never shown here.
        guard carriedComposition == nil else { return }
        let since = now()
        carriedComposition = (session, since)
        scheduleDeferredDeactivation {
            guard carriedComposition?.since == since else { return }
            commitCarriedComposition()
        }
    }

    /// Commit a carried syllable into the client it was typed in, as always.
    private static func commitCarriedComposition() {
        guard let carried = carriedComposition else { return }
        carriedComposition = nil
        carried.session.finalize(reason: .deactivateServer)
    }

    /// `session` has taken over. A carried syllable continues here if it is the
    /// same app's and the handover is part of the same churn, marked again since
    /// the host showing it may not have been this field. Anything else commits it
    /// where it was typed, as always.
    private func continueCarriedComposition(in session: InputSession) {
        guard let carried = Self.carriedComposition else { return }
        guard carried.session.context.bundleId == session.context.bundleId,
              Self.now() - carried.since < Self.churnWindow else {
            Self.commitCarriedComposition()
            return
        }
        Self.carriedComposition = nil
        session.adapter.setMarkedText(composer.preeditForDisplay)
    }

    /// Route a composition-ending event to the single finalize path. Prefers the
    /// session (it knows the delivery mode — direct insertion must NOT re-insert);
    /// falls back to a detached marked-text finalize when IMK hands us a sender the
    /// session has never seen.
    private func finalizeActiveComposition(sender: Any?, reason: CompositionFinalizeReason) {
        guard Self.sharedController === self else { return }
        let senderClient = sender as? IMKTextInput
        if let session, session.adapter is DirectInsertionAdapter || senderClient.map(session.matches) ?? true {
            session.finalize(reason: reason)
            return
        }
        if let senderClient, composer.hasActiveComposition {
            InputSession.finalizeMarkedComposition(composer: composer, client: senderClient, reason: reason)
        } else {
            session?.finalize(reason: reason)
        }
    }

    // MARK: - Keyboard Layout (English pass-through support)

    /// Runs synchronously on purpose: the first English key after a toggle or
    /// activation must already see the Roman layout.
    private func syncRomanKeyboardLayout(for client: IMKTextInput, force: Bool = false) {
        guard composer.inputMode == .english else { return }
        // Throttle before asking TIS, so a skipped call costs nothing.
        let clientID = ObjectIdentifier(client as AnyObject)
        let now = CFAbsoluteTimeGetCurrent()
        guard force || lastKeyboardOverrideClientID != clientID || now - lastKeyboardOverrideTime > 0.5 else {
            return
        }
        // Kept only until the enabled list changes: the user can disable ABC at any
        // time, and a stale answer would override a client with a layout they removed.
        guard let layoutID = InputSourceManager.shared.enabledRomanKeyboardLayoutID() else { return }

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

    /// ⌘ went down (`InputModeCoordinator.requestShortcutCommit`). With the
    /// Hanja candidates up, keys go to the window first and it decides.
    func commitForShortcut() {
        guard composer.hasActiveComposition, !HanjaCandidateWindow.shared.isVisible else { return }
        session?.finalize(reason: .shortcut)
    }

    public func performPriTypeModeTransition(source: InputModeCoordinator.ToggleSource) {
        guard let session else {
            Self.performModeTransitionWithoutField(source: source)
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
        Self.systemModeReporter(nextMode)
    }

    /// Whether macOS has a PriType mode selected. A harness replaces it: its
    /// fields stand for a PriType session whatever this machine has selected.
    /// - Warning: Access from main thread only.
    nonisolated(unsafe) public static var priTypeIsSelected: () -> Bool = {
        InputSourceManager.shared.isPriTypeModeSelected()
    }

    /// A toggle with no field to type into: Finder, a web page with no input
    /// focused, or the gap between one field's deactivation and the next one's
    /// activation. The key monitor has already swallowed the key, so dropping the
    /// toggle would leave the user with neither the key nor the switch.
    ///
    /// Only while PriType is the selected input source. Switching to another
    /// one (ABC, Japanese) also deactivates the last field and leaves no
    /// controller, and the report below selects a PriType mode: the toggle key
    /// would take the user out of the input source they just chose.
    ///
    /// There is nothing to commit — the deactivation that left no field behind
    /// finalized the composition — and no client to give the Roman layout to:
    /// the next activation does that, as it does after any toggle.
    static func performModeTransitionWithoutField(source: InputModeCoordinator.ToggleSource) {
        guard priTypeIsSelected() else {
            DebugLogger.log("PriTypeInputController: ignored toggle with no field; another input source is selected")
            return
        }
        let composer = sharedComposer
        let nextMode = composer.inputMode.toggled
        DebugLogger.log("PriTypeInputController: mode transition with no focused field \(composer.inputMode) -> \(nextMode) source=\(source)")
        composer.clearLocalBuffer()
        composer.setInputMode(nextMode)
        systemModeReporter(nextMode)
    }

    /// Where activation reports which app's field has keyboard focus (see
    /// `ToggleExclusionPolicy`). A harness gives its fields a policy of their
    /// own, so they do not move the process-wide one under other tests.
    /// - Warning: Access from main thread only.
    nonisolated(unsafe) public static var focusOwnerPolicy: ToggleExclusionPolicy = .shared

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
        Self.deliver(.activate(self, sender))
    }

    /// The session work of `activateServer`, once it may run (see `deliver`).
    private func beginActivation(_ sender: Any?) {
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
                // Lightweight context: no client IPC on a focus change. The first
                // key upgrades it (`ensureSession`), paying for validAttributes and
                // coordinates only in fields that are actually typed into.
                let newSession = replaceSession(
                    client: client,
                    context: ClientContextDetector.analyzeForActivation(client: client)
                )
                DebugLogger.log("Activated for client: \(newSession.context.bundleId) (Lightweight Context)")
            }
            session.map(continueCarriedComposition)
        } else {
            // Fallback if sender is not IMKTextInput (rare). Keep the old session's
            // adapter alive for async Hanja callbacks, but stop trusting its context
            // and stop watching focus on its behalf.
            session?.disarmFocusLossFinalizer()
            session?.markContextStale()
        }
        // The bundle ID the session already holds: no call into the host. With
        // no client there is no owner to name, and the frontmost app decides.
        Self.focusOwnerPolicy.focusDidMove(
            to: sender is IMKTextInput ? session?.context.bundleId : nil,
            owner: ObjectIdentifier(self))
    }

    override public func deactivateServer(_ sender: Any!) {
        #if DEBUG
        assert(Thread.isMainThread, "IMK deactivateServer must run on main thread")
        #endif
        // Committed before IMK hears of the deactivation, as always; a queued
        // deactivation cannot wait for that, so its commit comes after.
        if Self.handleDepth > 0 {
            // Where the composition sits in the host, recorded now: once the call
            // this arrived in returns, the host may front another field.
            let anchor = Self.sharedController === self && composer.hasActiveComposition
                ? session?.hostAnchor() : nil
            super.deactivateServer(sender)
            Self.deliver(.deactivate(self, sender, anchor))
        } else {
            Self.deliver(.deactivate(self, sender, nil))
            super.deactivateServer(sender)
        }
    }

    /// The session work of `deactivateServer`, once it may run (see `deliver`).
    private func endActivation(_ sender: Any?) {
        // Fallback finalize. The primary path is the session's focus-loss observer (it
        // fires earlier, while the host still accepts input); by the time
        // deactivateServer runs, native hosts like KakaoTalk have already resigned and
        // ignore insertText. If the observer already committed, this is a no-op.
        if Self.sharedController === self, leavesTooSoon, let session {
            Self.carry(session)
        } else {
            finalizeActiveComposition(sender: sender, reason: .deactivateServer)
        }
        // Focus is leaving this client (another window or app). Its Hanja
        // candidates can no longer receive keys, so close them. Only the owner
        // does this: a late deactivation of an older controller must not close
        // the window a newer client just opened.
        if Self.sharedController === self {
            composer.dismissHanjaCandidates(reason: "focus change")
        }
        // NOTE: Do NOT clear localTextBuffer here: a Hanja lookup back in the same
        // field needs it after a reactivation. Leaking into another field is
        // prevented by the composer: `markKeystroke` empties the buffer on the
        // first keystroke in another field, and `handleHanjaLookup` ignores a
        // buffer typed in another field.
        // Keep the session alive — async Hanja callbacks need the adapter, and a
        // handle() arriving before the next activateServer needs the context. But:
        // - disarm the focus-loss observer: the composer is shared, so a stale
        //   observer firing later would flush a NEWER session's composition into
        //   THIS client (the cross-app commit-leak class);
        // - mark the context stale so the next handle() re-analyzes it.
        session?.disarmFocusLossFinalizer()
        session?.markContextStale()
        Self.focusOwnerPolicy.focusDidLeave(owner: ObjectIdentifier(self))
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

            // The echo of our own report after a custom toggle. The composer is
            // already where the user put it — possibly past this value, if they
            // toggled again before the echo arrived — so only note the system state.
            if Self.echoFilter.consumeEcho(of: targetMode, at: ProcessInfo.processInfo.systemUptime) {
                DebugLogger.log("PriTypeInputController: consumed echo of reported mode \(targetMode)")
                Self.lastSystemMode = targetMode
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
            // A real selection: echoes of earlier reports no longer describe anything.
            Self.echoFilter.reset()

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

    // MARK: - Re-entrant Lifecycle Calls
    //
    // `handle()` makes synchronous calls into the host (insertText, setMarkedText,
    // validAttributesForMarkedText), and IMK can deliver activateServer and
    // deactivateServer NESTED inside them. Observed on macOS 27: a key typed right
    // after clicking into TextEdit, whose activation finishes ~250 ms after the
    // click, got deactivateServer + activateServer while `updateComposition` was
    // inside `insertText("한")`. The nested deactivation flushed the shared engine
    // (the pending ㄱ) into a host that was not taking edits, and the composer then
    // marked the ㄱ it had read before the insert on an engine that no longer held
    // it: the next vowel started a new syllable (한ㅡㄹ for 한글). Chromium and
    // Electron do the same inside `ensureSession`'s validAttributesForMarkedText.
    //
    // So while a `handle()` runs, the session work of both calls is queued (the
    // `super` calls still happen at once) and runs when the outermost `handle()`
    // returns. A queued deactivation of the controller that owns the engine is
    // then held rather than run, with a record of where the composition sat in the
    // host when it arrived (`InputSession.HostAnchor`). An activation of the same
    // controller and client — or a key arriving for them — resolves it as churn
    // IF the host still fronts the same field: the composition carries on
    // (`InputSession.resumeAfterHeldDeactivation`). The client object alone does
    // not prove that; every web field in a Chromium window shares one. Anything
    // else settles it as a real focus change: another controller or client
    // activating, another key target, another deactivation, or time passing
    // (`scheduleDeferredDeactivation`). It cannot simply be skipped: the same call
    // from `claimActiveController` or `replaceSession` would commit the
    // composition into a stale session's client.
    //
    // Settling late costs nothing a prompt commit would have saved: the host
    // stopped taking edits when the deactivation arrived — that is what lost the
    // ㄱ — so what matters is what it kept. `settleHeldDeactivation` checks that
    // before the usual finalize, so a syllable the host committed on resigning is
    // not typed twice.

    private enum LifecycleCall {
        case activate(PriTypeInputController, Any?)
        case deactivate(PriTypeInputController, Any?, InputSession.HostAnchor?)
    }

    private struct PendingDeactivation {
        let controller: PriTypeInputController
        let sender: Any?
        let anchor: InputSession.HostAnchor?
        let token: UInt64
    }

    /// How many `handle()` calls are running (nested ones included). While it is
    /// above zero, lifecycle calls queue in `deferredLifecycleCalls`.
    /// - Warning: Access from main thread only (guaranteed by IMK).
    nonisolated(unsafe) private static var handleDepth = 0
    nonisolated(unsafe) private static var deferredLifecycleCalls: [LifecycleCall] = []
    nonisolated(unsafe) private static var pendingDeactivation: PendingDeactivation?
    nonisolated(unsafe) private static var pendingDeactivationToken: UInt64 = 0

    /// Runs `work` once a held deactivation has waited long enough for its
    /// activation. `work` settles it if nothing else has. A harness replaces this
    /// to decide itself when that time has come.
    /// - Warning: Access from main thread only.
    nonisolated(unsafe) public static var scheduleDeferredDeactivation: (@escaping @Sendable () -> Void) -> Void = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Route a lifecycle call: queue it while a `handle()` runs, else run it.
    private static func deliver(_ call: LifecycleCall) {
        if handleDepth > 0 {
            deferredLifecycleCalls.append(call)
        } else {
            perform(call, nested: false)
        }
    }

    /// Run what was queued during the `handle()` that just returned. Calls IMK
    /// nests inside this replay queue behind it, as they would inside `handle()`.
    private static func drainDeferredLifecycleCalls() {
        handleDepth += 1
        defer { handleDepth -= 1 }
        while !deferredLifecycleCalls.isEmpty {
            perform(deferredLifecycleCalls.removeFirst(), nested: true)
        }
    }

    private static func perform(_ call: LifecycleCall, nested: Bool) {
        switch call {
        case let .deactivate(controller, sender, anchor):
            if let pending = pendingDeactivation, pending.controller !== controller {
                settlePendingDeactivation()
            }
            guard nested, sharedController === controller else {
                settlePendingDeactivation()
                controller.endActivation(sender)
                return
            }
            DebugLogger.log("PriTypeInputController: deactivation arrived inside handle(); holding it for a reactivation")
            pendingDeactivationToken &+= 1
            let token = pendingDeactivationToken
            pendingDeactivation = PendingDeactivation(controller: controller, sender: sender, anchor: anchor, token: token)
            scheduleDeferredDeactivation { settlePendingDeactivation(token: token) }

        case let .activate(controller, sender):
            if let pending = pendingDeactivation, pending.controller === controller,
               let client = sender as? IMKTextInput, controller.session?.matches(client) == true {
                // Deactivated and activated again: churn, if the field is the same.
                pendingDeactivation = nil
                DebugLogger.log("PriTypeInputController: same client re-activated after a held deactivation")
                if controller.session?.resumeAfterHeldDeactivation(since: pending.anchor) == false {
                    controller.endActivation(pending.sender)
                }
                controller.beginActivation(sender)
                return
            }
            settlePendingDeactivation()
            controller.beginActivation(sender)
        }
    }

    /// A key for `client` arrived while a deactivation of this controller was
    /// held: the field is live, and the composition carries on if it is still the
    /// same field. A key for anything else means the deactivation was real.
    private func resolvePendingDeactivation(keyFrom client: IMKTextInput) {
        guard let pending = Self.pendingDeactivation else { return }
        guard pending.controller === self, let session, session.matches(client) else {
            Self.settlePendingDeactivation()
            return
        }
        Self.pendingDeactivation = nil
        DebugLogger.log("PriTypeInputController: key arrived for the held client")
        if !session.resumeAfterHeldDeactivation(since: pending.anchor) {
            endActivation(pending.sender)
        }
    }

    /// Run the held deactivation now (with `token`: only if it is still that one).
    private static func settlePendingDeactivation(token: UInt64? = nil) {
        guard let pending = pendingDeactivation, token == nil || pending.token == token else { return }
        guard handleDepth == 0 || token == nil else {
            // A timer that fired while a handle() runs: that handle() resolves it.
            return
        }
        pendingDeactivation = nil
        DebugLogger.log("PriTypeInputController: no reactivation followed; running the held deactivation")
        if sharedController === pending.controller {
            pending.controller.session?.settleHeldDeactivation(since: pending.anchor)
        }
        pending.controller.endActivation(pending.sender)
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

        // IMK may deliver activateServer/deactivateServer while this is inside a
        // synchronous call into the host; those wait until it returns.
        Self.handleDepth += 1
        defer {
            Self.handleDepth -= 1
            if Self.handleDepth == 0 { Self.drainDeferredLifecycleCalls() }
        }
        resolvePendingDeactivation(keyFrom: client)

        // One interval per keystroke, with the stages below nested inside it, so a
        // slow key can be read as which stage was slow rather than as a total. No
        // part of what was typed is recorded — see `Signposts`.
        let recording = Signposts.isRecording
        let signpostID = recording ? Signposts.keystroke.makeSignpostID() : .invalid
        let keystroke = recording
            ? Signposts.keystroke.beginInterval(Signposts.Stage.handle, id: signpostID) : nil
        defer {
            if let keystroke { Signposts.keystroke.endInterval(Signposts.Stage.handle, keystroke) }
        }

        claimActiveController()

        // 1. Resolve the session FIRST — all subsequent logic uses its fresh context.
        let session = Signposts.interval(Signposts.keystroke, Signposts.Stage.session, id: signpostID, recording: recording) {
            ensureSession(for: client)
        }
        continueCarriedComposition(in: session)
        // A key for this client says it has focus, even before (or without) the
        // activation that would have said so: some hosts deliver keys first.
        Self.focusOwnerPolicy.focusDidMove(to: session.context.bundleId, owner: ObjectIdentifier(self))

        // A toggle or Hanja key pressed just before this key may still be waiting
        // for its hop from the key-monitor thread. Run it now so this key lands in
        // the new mode or in the candidate window — but only actions pressed before
        // this key: running a later one would reinterpret a key typed earlier.
        Signposts.interval(Signposts.keystroke, Signposts.Stage.pendingActions, id: signpostID, recording: recording) {
            let coordinator = InputModeCoordinator.shared
            coordinator.applyPendingKeyActions(
                before: coordinator.pressTime(ofKeyCode: event.keyCode, deliveredAt: event.timestamp))
        }

        // 2. Duplicate-keyDown suppression. Some hosts (observed: KakaoTalk) deliver
        // the same physical keyDown to the IME twice. That double-processes input —
        // notably one backspace decomposing TWO jamo, i.e. a composing syllable
        // "deleted all at once". Drop the exact re-delivery and replay the original
        // result. Host-event-level, so it applies in every delivery mode.
        let keyDownSnapshot = KeyDownSnapshot(timestamp: event.timestamp, keyCode: event.keyCode, isARepeat: event.isARepeat, characters: event.characters, modifiers: event.modifierFlags.rawValue)
        if session.registerKeyDown(keyDownSnapshot) {
            DebugLogger.logSensitive("PriTypeInputController: dropped duplicate keyDown",
                                     sensitiveContent: "keyCode=\(event.keyCode)")
            return session.lastHandleResult
        }

        #if DEBUG
        if debugHandleLogCount < 200 {
            debugHandleLogCount += 1
            // A key code IS what the user typed — it is the letter, by another
            // name, and `modifiers` says whether it was shifted. The first two
            // hundred keystrokes of every Debug session were being written out in
            // full, which is the leak the Hanja logging was fixed for, at a larger
            // scale. The state around the key is what this line is read for, so the
            // key itself goes the way `logSensitive` sends everything else.
            DebugLogger.logSensitive(
                "PriTypeInputController: handle repeat=\(event.isARepeat) mode=\(composer.inputMode) bundle=\(session.context.bundleId) lightweight=\(session.context.isLightweight) immediate=\(session.context.shouldUseImmediateMode)",
                sensitiveContent: "keyCode=\(event.keyCode) modifiers=\(event.modifierFlags.rawValue)")
        }
        #endif

        // 3. Mark keystroke with current app's bundleId for cross-app hanja validation
        composer.markKeystroke(bundleId: session.context.bundleId, client: session.client)

        // 4. DYNAMIC CHECK: Secure Input (password fields) — raw pass-through.
        // A client IPC when a global secure-input warning is up, so it is timed
        // separately from the composition it precedes.
        let passThrough = Signposts.interval(Signposts.keystroke, Signposts.Stage.secureInputProbe,
                                            id: signpostID, recording: recording) {
            shouldPassThroughSecureInput(client: client, context: session.context)
        }
        if passThrough {
            session.discardForSecureInput()
            session.recordHandleResult(false)
            return false
        }

        // 5. The delivery policy can flip mid-session (experimental flag toggled in
        // settings); make sure the adapter still matches before composing into it.
        session.ensureAdapterMatchesPolicy()

        // A direct-live preedit has no IMK marked range, so caret/document changes
        // must be detected explicitly before this key mutates the Hangul engine.
        // One or two synchronous client reads when direct insertion is live.
        Signposts.interval(Signposts.keystroke, Signposts.Stage.prepareForInput, id: signpostID, recording: recording) {
            session.prepareForInput()
        }

        // 6. Compose. The writes to the host happen inside here, so this interval
        // carries the text APIs' own IPC with it.
        let handled = Signposts.interval(Signposts.keystroke, Signposts.Stage.compose, id: signpostID, recording: recording) {
            composer.handle(event, delegate: session.adapter)
        }
        session.recordHandleResult(handled)
        return handled
    }

    /// Whether a global Secure Input warning is up. A client that answers this
    /// itself does; everyone else gets macOS's answer. See
    /// `GlobalSecureInputReporting` for why the seam is on the client rather
    /// than on a global.
    private static func globalSecureInput(for client: IMKTextInput) -> Bool {
        (client as? GlobalSecureInputReporting)?.reportsGlobalSecureInput ?? IsSecureEventInputEnabled()
    }

    private func shouldPassThroughSecureInput(client: IMKTextInput, context: ClientContext) -> Bool {
        let bundleId = context.bundleId
        let isSystemSecureClient = SecureInputPolicy.isSystemSecureClient(bundleId)
        let hasGlobalSecureInput = Self.globalSecureInput(for: client)

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
        // No super call: `commitComposition:` is IMKStateSetting's informal
        // protocol for input methods to implement. IMKInputController has only the
        // argument-less `commitComposition`, so `super.commitComposition(sender)`
        // raised an unrecognized-selector exception on every click-to-commit,
        // after the work above was already done.
    }

    // MARK: - Input Method Menu

    /// Returns custom menu for the input method (shown in system input source menu)
    override public func menu() -> NSMenu! {
        let menu = NSMenu()

        // Settings
        let settingsItem = NSMenuItem(title: L10n.menu.settings, action: #selector(openSettings(_:)), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // About
        let aboutItem = NSMenuItem(title: L10n.menu.about, action: #selector(showAbout(_:)), keyEquivalent: "")
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
