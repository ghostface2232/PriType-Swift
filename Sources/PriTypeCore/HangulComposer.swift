import Cocoa
import LibHangul
import InputMethodKit

// Protocol and InputMode are now in HangulComposerTypes.swift
// Helper functions are now in CompositionHelpers.swift

// MARK: - HangulComposer

/// Core Hangul composition engine that wraps libhangul
///
/// `HangulComposer` handles the complete lifecycle of Hangul text input:
/// - Converting keystrokes to Hangul syllables
/// - Managing preedit (composition in progress) state
/// - Committing finalized text
/// - Applying Korean or English mode selected by the IMK controller
///
/// ## Overview
/// The composer uses `libhangul`'s `HangulInputContext` internally to perform
/// the actual character composition according to Korean keyboard layouts.
///
/// ## Usage
/// ```swift
/// let composer = HangulComposer()
/// let handled = composer.handle(keyEvent, delegate: myDelegate)
/// ```
///
/// ## Thread Safety
/// This class is not thread-safe. All calls should be made from the main thread.
public class HangulComposer: @unchecked Sendable {
    
    // MARK: - Public Properties
    
    /// The current input mode (Korean or English)
    ///
    /// When in `.english` mode, all keystrokes are passed through unchanged.
    public private(set) var inputMode: InputMode = .korean
    private(set) var modeSelectionRevision: UInt64 = 0

    /// Whether the underlying Hangul engine currently has active composition.
    public var hasActiveComposition: Bool {
        !context.isEmpty()
    }
    
    // MARK: - Dependencies
    
    
    /// Configuration provider (injected for testability)
    private let configuration: ConfigurationProviding
    
    // MARK: - Private Properties
    
    /// Track last delegate for external toggle calls
    private weak var lastDelegate: (any HangulComposerDelegate)?
    
    /// Strong reference to the most recent adapter for Hanja lookup.
    /// Unlike lastDelegate (weak) and PriTypeInputController.currentAdapter,
    /// this survives IMK controller deallocation which happens frequently
    /// in Electron apps (Chrome, VS Code).
    /// Released with a 2-second delay when replaced, to allow async Hanja callbacks to finish.
    private var lastStrongDelegate: (any HangulComposerDelegate)?
    
    /// Pending release of previous strong delegate (delayed to allow async callbacks)
    private var pendingDelegateRelease: DispatchWorkItem?
    
    /// Whether Hanja candidate mode is currently active
    private var hanjaMode = false
    
    /// The Hangul key currently being looked up for Hanja conversion
    private var hanjaKey: String = ""
    
    /// Local cache of recently typed text to support double-space detection and Hanja lookup
    public var localTextBuffer: String = ""
    
    /// Maximum buffer size for local text tracking
    private let bufferMaxLength = 15
    
    /// Append text to the local buffer, trimming to max length
    private func appendToBuffer(_ text: String) {
        localTextBuffer.append(text)
        if localTextBuffer.count > bufferMaxLength {
            localTextBuffer = String(localTextBuffer.suffix(bufferMaxLength))
        }
    }
    
    // MARK: - libhangul Context
    // 두벌식 표준 is the only supported layout, so the context is created once.
    private let context = ThreadSafeHangulInputContext(keyboard: PriTypeConfig.defaultKeyboardId)
    
    /// Text convenience handler (double-space period)
    /// Owns all state for text convenience features
    private let textConvenience: TextConvenienceHandler
    
    // MARK: - Initialization
    
    /// Creates a new HangulComposer with default settings
    /// - Parameter configuration: Configuration provider (defaults to shared manager)
    public init(configuration: ConfigurationProviding = ConfigurationManager.shared) {
        self.configuration = configuration
        self.textConvenience = TextConvenienceHandler(
            isDoubleSpacePeriodEnabled: {
                configuration.doubleSpacePeriodEnabled
            }
        )
        DebugLogger.log("HangulComposer init")
    }

    // MARK: - Public Methods
    
    /// Set Korean or English mode from the PriType controller.
    ///
    /// Custom toggle keys are coordinated by `InputModeCoordinator` and
    /// `PriTypeInputController` before reaching this method. Caps Lock language
    /// switching also arrives through the controller as an IMK input-mode value
    /// change.
    /// - Important: `inputMode` is the single source of truth for the Korean/
    ///   English state. The only sanctioned writers are
    ///   `PriTypeInputController.performPriTypeModeTransition` (custom toggle) and
    ///   `PriTypeInputController.setValue(_:forTag:)` (macOS re-selecting the
    ///   PriType source, which always lands back in `.korean`). No other path —
    ///   including `activateServer` focus changes — may mutate the mode.
    public func setInputMode(_ mode: InputMode) {
        modeSelectionRevision &+= 1
        guard inputMode != mode else {
            return
        }

        DebugLogger.log("setInputMode called externally: \(mode)")

        if let delegate = lastDelegate, !context.isEmpty() {
            commitComposition(delegate: delegate)
            DebugLogger.log("Composition committed before explicit mode switch")
        }

        // An open Hanja candidate window belongs to the mode it was opened in.
        // English mode never forwards keys to it, so left open it would linger
        // unreachable by the keyboard — digits typed as text, Escape ignored —
        // until a stray click inserted a candidate.
        dismissHanjaCandidates(reason: "mode switch")

        inputMode = mode
        localTextBuffer = ""
        textConvenience.resetSpaceState()
        DebugLogger.log("Mode set to: \(inputMode)")
    }

    // MARK: - Private Helpers
    
    /// Handle special keys (Return, Escape, Space, Arrow, Tab, Backspace)
    /// - Returns: `nil` if not a special key, otherwise the result to return from handle()
    private func handleSpecialKey(keyCode: UInt16, delegate: HangulComposerDelegate) -> Bool? {
        // Return / Enter
        if keyCode == KeyCode.return || keyCode == KeyCode.numpadEnter {
            let hadComposition = !context.isEmpty()
            commitComposition(delegate: delegate)
            if hadComposition {
                delegate.setMarkedText("")
            }
            localTextBuffer = ""

            if hadComposition && ClientCompatibilityPolicy.needsDirectNewlineAfterReturnCommit(bundleId: lastInputBundleId) {
                delegate.insertText("\n")
                DebugLogger.log("Return -> GoodNotes compatibility: inserted newline and consumed original Return")
                return true
            }

            if hadComposition && ClientCompatibilityPolicy.needsReturnConsumedAfterCompositionCommit(bundleId: lastInputBundleId) {
                DebugLogger.log("Return -> committed composition and consumed original Return for host compatibility")
                return true
            }

            DebugLogger.log("Return -> committed composition and passed original Return to app (hadComposition=\(hadComposition))")
            return false
        }
        
        // Escape - only consume if there's an active composition to cancel
        if keyCode == KeyCode.escape {
            if !context.isEmpty() {
                DebugLogger.log("Escape -> cancel composition")
                cancelComposition(delegate: delegate)
                localTextBuffer = ""
                return true
            }
            localTextBuffer = ""
            return false  // No composition, pass to system (e.g. Finder close dialog)
        }
        
        // Space - handle double-space period
        if keyCode == KeyCode.space {
            guard !context.isEmpty() || !localTextBuffer.isEmpty else {
                textConvenience.resetSpaceState()
                return false
            }
            commitComposition(delegate: delegate)
            let result = textConvenience.handleDoubleSpacePeriod(buffer: &localTextBuffer, delegate: delegate, checkHangul: true)
            if result == .convertedToPeriod {
                DebugLogger.log("Double-space -> period (Korean mode)")
                return true
            }
            delegate.insertText(" ")
            appendToBuffer(" ")
            return true
        }
        
        // Non-space: reset space state
        textConvenience.resetSpaceState()
        
        // Arrow keys
        if keyCode == KeyCode.leftArrow || keyCode == KeyCode.rightArrow ||
           keyCode == KeyCode.upArrow || keyCode == KeyCode.downArrow {
            commitComposition(delegate: delegate)
            localTextBuffer = ""
            return false
        }
        
        // Tab
        if keyCode == KeyCode.tab {
            commitComposition(delegate: delegate)
            localTextBuffer = ""
            return false
        }
        
        // Backspace
        if keyCode == KeyCode.backspace {
            if !context.isEmpty() {
                let before = context.getPreeditString()
                _ = context.backspace()
                if context.isEmpty() {
                    // The last jamo is going. Commit it and let the host delete it
                    // with its own deleteBackward, instead of cancelling the marked
                    // text with setMarkedText(""). That is what Apple's Korean IME
                    // does (recorded on macOS 27: insertText("ㅇ") then
                    // deleteBackward:), and it matters: Figma's canvas editor treats
                    // a cancelled composition as committed, so the cancel left the
                    // jamo behind ("요" + ⌫⌫ → "ㅇ"). The end result is the same
                    // everywhere else. Not added to localTextBuffer: the host
                    // removes it right away.
                    let jamo = CompositionHelpers.normalizeJamoForDisplay(before)
                    if !jamo.isEmpty {
                        delegate.insertText(jamo)
                    }
                    return false
                }
                updateComposition(delegate: delegate)
                return true
            }
            if !localTextBuffer.isEmpty { localTextBuffer.removeLast() }
            return false
        }
        
        return nil  // Not a special key
    }
    
    /// Process a single character through the Hangul engine
    /// - Parameter composes: whether the character came from a letter-key
    ///   position. A character from any other key is never handed to the engine,
    ///   so a layout that puts a letter there (AZERTY "m") cannot produce a jamo.
    /// - Returns: `true` if the character was processed, `false` if skipped
    private func processCharacter(_ char: Unicode.Scalar, composes: Bool, delegate: HangulComposerDelegate) -> Bool {
        let charCode = UInt32(char.value)
        
        // Skip non-printable characters
        if KeyCode.shouldPassThrough(charCode) {
            return false
        }
        
        // Primary attempt
        if composes && context.process(Character(char)) {
            updateComposition(delegate: delegate)
            return true
        }
        
        // Failure case - try committing first then retry
        DebugLogger.log("Process failed")
        
        if !context.isEmpty() {
            commitComposition(delegate: delegate)
        }
        
        // Retry with clean context
        if composes && context.process(Character(char)) {
            DebugLogger.log("Retry success")
            updateComposition(delegate: delegate)
            return true
        }
        
        // Still failed - insert printable ASCII directly
        if KeyCode.isPrintableASCII(charCode) {
            DebugLogger.log("Retry failed, inserting printable char")
            delegate.insertText(String(char))
            appendToBuffer(String(char))
            return true
        }
        
        DebugLogger.log("Retry failed, skipping non-printable char")
        return false
    }
    
    /// Handle a keyboard event
    ///
    /// This is the main entry point for processing keyboard input. The method
    /// determines whether to process the event as Hangul input, pass it through
    /// to the system, or handle it as a special key (Return, Space, etc.).
    ///
    /// - Parameters:
    ///   - event: The `NSEvent` to process (must be `.keyDown`)
    ///   - delegate: The delegate to receive composition callbacks
    /// - Returns: `true` if the event was consumed, `false` if it should be passed to the system
    public func handle(_ event: NSEvent, delegate: HangulComposerDelegate) -> Bool {
        // Track delegate for external toggle calls
        self.lastDelegate = delegate
        
        // Delayed release of previous strong delegate to prevent indefinite retention
        // while keeping it alive long enough for async Hanja callbacks (2s window).
        // HOW IT WORKS: `oldDelegate` is captured strongly by the DispatchWorkItem closure.
        // This keeps the old adapter alive for 2 seconds even after `lastStrongDelegate`
        // is replaced. When the work item executes (or is cancelled), the captured
        // reference is released, allowing the old adapter to be deallocated.
        if lastStrongDelegate !== (delegate as AnyObject) {
            pendingDelegateRelease?.cancel()
            let oldDelegate = lastStrongDelegate  // Strong capture keeps it alive for 2s
            let releaseWork = DispatchWorkItem {
                _ = oldDelegate  // prevent compiler from optimizing away the capture
            }
            pendingDelegateRelease = releaseWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: releaseWork)
            self.lastStrongDelegate = delegate
        }
        
        // Only handle key down events for actual typing
        if event.type != .keyDown {
            return false
        }
        
        // Global context invalidation:
        // Any navigation or confirmation key (Arrow, Tab, Return) invalidates our local text context
        // because the cursor has likely moved, changing the text before it.
        let keyCode = event.keyCode
        if keyCode == KeyCode.leftArrow || keyCode == KeyCode.rightArrow ||
           keyCode == KeyCode.upArrow || keyCode == KeyCode.downArrow ||
           keyCode == KeyCode.tab || keyCode == KeyCode.return || keyCode == KeyCode.numpadEnter {
            localTextBuffer = ""
        }
        
        // English mode stays inside the PriType input source but performs no
        // composition. Most keys pass through to the host app unchanged.
        // - Roman characters come from the keyboard layout that the controller
        //   installs via `overrideKeyboardWithKeyboardNamed(ABC/US)`.
        // Text conveniences belong to the host, which knows the field's opt-in
        // settings. English printable keys always pass through unchanged.
        if inputMode == .english {
            if !context.isEmpty() {
                commitComposition(delegate: delegate)
                delegate.setMarkedText("")
            }
            localTextBuffer = ""
            return false
        }
        
        // If Hanja candidate window is visible, forward keys to it
        if hanjaMode {
            let consumed = HanjaCandidateWindow.shared.handleKey(event)
            if !HanjaCandidateWindow.shared.isVisible {
                hanjaMode = false
                hanjaKey = ""
            }
            if consumed {
                return true
            }
            // If not consumed (regular key dismissed the window),
            // fall through to normal key processing below so the
            // keystroke is handled by the Hangul composer instead
            // of being passed raw to the app (which would produce English).
        }
        
        // Option key: no longer intercepted here.
        // Right Option key is handled via CGEventTap in RightCommandSuppressor.
        // Pass through if modifiers (Command, Control, Option) are present
        // This ensures system shortcuts work correctly without interference
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
             // Commit any in-progress composition first. Otherwise marked text stays
             // live and the host app ignores or misapplies the shortcut (e.g. Cmd+←).
             if !context.isEmpty() {
                 commitComposition(delegate: delegate)
                 delegate.setMarkedText("")
             }
             localTextBuffer = "" // Any system shortcut (Cmd+V, Cmd+Z, etc.) invalidates local context
             return false
        }
        
        // Letter keys compose from their position, not the active Latin layout: the
        // Hangul layout is defined on QWERTY positions, and only Shift (never Caps
        // Lock) picks the upper row. Every other key keeps what the layout typed.
        let positional = QwertyKeyMap.character(for: keyCode, shifted: event.modifierFlags.contains(.shift))
        let composes = positional != nil
        guard let inputCharacters = positional ?? event.characters, !inputCharacters.isEmpty else {
            return false
        }
        
        // Handle special keys (Return, Escape, Space, Arrow, Tab, Backspace)
        if let result = handleSpecialKey(keyCode: keyCode, delegate: delegate) {
            return result
        }
        
        // Filter: If input contains non-printable characters (e.g., function keys, arrows)
        // This catches Fn+Arrow (Home/End/PageUp/PageDown) and other navigation keys
        // that don't match the KeyCode enum in handleSpecialKey.
        if let firstScalar = inputCharacters.unicodeScalars.first {
            let firstCharCode = UInt32(firstScalar.value)
            if KeyCode.shouldPassThrough(firstCharCode) {
                DebugLogger.log("Non-printable key detected, passing to system")
                if !context.isEmpty() {
                    commitComposition(delegate: delegate)
                    delegate.setMarkedText("")
                }
                localTextBuffer = ""
                return false
            }
        }
        
        var handledAtLeastOnce = false
        
        for char in inputCharacters.unicodeScalars {
            if processCharacter(char, composes: composes, delegate: delegate) {
                handledAtLeastOnce = true
            }
        }
        
        // If we processed anything, we return true to stop system from handling duplicates.
        return handledAtLeastOnce
    }
    
    /// Updates the marked text and commits any finalized text
    ///
    /// This method retrieves the current preedit (composition in progress) and commit
    /// strings from libhangul, then updates the delegate accordingly:
    /// - Committed text is inserted immediately
    /// - Preedit text replaces the current marked text
    ///
    /// - Parameter delegate: The delegate to receive composition updates
    private func updateComposition(delegate: HangulComposerDelegate) {
        let preedit = context.getPreeditString()
        let commit = context.getCommitString()

        // ORDERING INVARIANT (load-bearing — do not reorder):
        // commit (insertText) MUST happen BEFORE the preedit update (setMarkedText).
        // This is the macOS equivalent of the Windows Korean IME model — only the
        // single in-progress syllable is ever "marked", and the previous syllable is
        // committed the instant libhangul emits it on a syllable boundary. Reordering
        // (mark-before-commit) reintroduces stale-cursor preedit (cf. kitty #4219) and
        // breaks the experimental DirectInsertionAdapter, which relies on insertText
        // arriving first to finalize the live preedit before the new one is rendered.
        // See Docs/KoreanWindowsInputFeasibility.md (Phase 0/1).
        if !commit.isEmpty {
            let finalStr = CompositionHelpers.convertAndNormalize(commit)
            delegate.insertText(finalStr)
            appendToBuffer(finalStr)
        }

        // Update preedit text (the single live syllable).
        if !preedit.isEmpty {
            let preeditStr = CompositionHelpers.normalizeJamoForDisplay(preedit)
            delegate.setMarkedText(preeditStr)
        } else {
             delegate.setMarkedText("")
        }
    }
    
    /// Commits the current composition by flushing the libhangul context
    ///
    /// Flushes all pending text from the context and inserts it as finalized text.
    /// The committed string is normalized using precomposed canonical mapping to
    /// ensure proper Unicode representation.
    ///
    /// - Parameter delegate: The delegate to receive the committed text
    private func commitComposition(delegate: HangulComposerDelegate) {
        // Flush context
        let flushed = context.flush()
        let commitStr = CompositionHelpers.convertToString(flushed)

        if !commitStr.isEmpty {
            // insertText replaces the marked text automatically
            let finalStr = CompositionHelpers.convertAndNormalize(flushed)
            delegate.insertText(finalStr)
            appendToBuffer(finalStr)
            DebugLogger.logSensitive("commitComposition inserted", sensitiveContent: "'\(commitStr)'")
        }
    }

    /// Cancels the current composition without committing
    ///
    /// Resets the libhangul context and clears the marked text display.
    /// Use this when the user explicitly cancels input (e.g., pressing Escape).
    ///
    /// - Parameter delegate: The delegate to receive the cleared state
    private func cancelComposition(delegate: HangulComposerDelegate) {
        context.reset()
        delegate.setMarkedText("")
        // Do NOT clear localTextBuffer on cancel, as previously committed text is still valid context
    }
    
    /// Force commit any in-progress composition
    ///
    /// Called when the input method is about to be deactivated or when
    /// text needs to be finalized immediately (e.g., before window switch).
    ///
    /// - Parameter delegate: The delegate to receive the committed text
    public func forceCommit(delegate: HangulComposerDelegate) {
        commitComposition(delegate: delegate)
        // Preserve the last Hangul character for Hanja lookup.
        // Electron apps (Chrome, VS Code) trigger frequent deactivateServer calls
        // which call forceCommit. Clearing the entire buffer makes Hanja lookup impossible.
        if let lastChar = localTextBuffer.last, lastChar.isHangulChar {
            localTextBuffer = String(lastChar)
        } else {
            localTextBuffer = ""
        }
    }

    /// Flush any in-progress composition and return its committed NFC string ("" if none).
    ///
    /// Unlike `forceCommit`, this does NOT insert via a delegate — the caller inserts the
    /// returned text itself. `deactivateServer` uses this to commit straight to the
    /// deactivating client with an explicit `replacementRange` over the marked text, which
    /// reliably clears a stranded preedit during a focus transition (some hosts, e.g.
    /// KakaoTalk, do not honor insertText's automatic marked-text replacement at that moment).
    public func flushCommitString() -> String {
        guard !context.isEmpty() else { return "" }
        let flushed = context.flush()
        let committed = CompositionHelpers.convertAndNormalize(flushed)
        if let lastChar = committed.last, lastChar.isHangulChar {
            localTextBuffer = String(lastChar)
        } else {
            localTextBuffer = ""
        }
        return committed
    }
    
    /// Reset the composition state
    ///
    /// Clears any in-progress composition without committing it.
    /// Use this when composition should be discarded (e.g., after Escape key).
    ///
    /// - Parameter delegate: The delegate to receive the cleared marked text
    public func reset(delegate: HangulComposerDelegate) {
        context.reset()
        delegate.setMarkedText("")
        delegate.insertText("") 
        localTextBuffer = ""
    }
    
    /// Clear the local text buffer without affecting composition state.
    public func clearLocalBuffer() {
        localTextBuffer = ""
    }

    /// Drops in-progress composition without touching the current client.
    ///
    /// Secure text fields must receive raw key events from the system. Calling
    /// `setMarkedText` or `insertText` while focus is inside a password field can
    /// trigger host-app warning beeps, so this reset intentionally has no delegate.
    public func discardCompositionForPassThrough() {
        context.reset()
        localTextBuffer = ""
        textConvenience.resetSpaceState()
    }
    
    /// Bundle ID of the app where the last keystroke was processed.
    /// Used to prevent cross-app hanja leaking: if the current app differs from
    /// the app that populated localTextBuffer, the buffer is considered stale.
    private var lastInputBundleId: String = ""
    
    /// Record which app the current keystroke is from (called from handle via controller)
    public func markKeystroke(bundleId: String) {
        lastInputBundleId = bundleId
    }
    
    /// Check if the buffer belongs to the given app
    public func isBufferFromApp(_ bundleId: String) -> Bool {
        return !lastInputBundleId.isEmpty && lastInputBundleId == bundleId
    }
    
    // MARK: - Hanja Lookup

    /// Close an open Hanja candidate window without choosing a candidate.
    ///
    /// For events that take the keyboard away from the window's client — a mode
    /// switch, or focus leaving for another window or app. The panel does not
    /// activate and shows on every Space, so nothing else would hide it, and only
    /// keys routed to this client can reach it.
    public func dismissHanjaCandidates(reason: String) {
        guard hanjaMode else { return }
        HanjaCandidateWindow.shared.dismiss()
        hanjaMode = false
        hanjaKey = ""
        DebugLogger.log("Hanja: dismissed by \(reason)")
    }
    
    /// Trigger Hanja lookup externally (run by `InputModeCoordinator`, in key order)
    ///
    /// This is the public entry point for Hanja conversion.
    /// Acts as a toggle: dismisses if already visible, opens if not.
    public func triggerHanjaLookup() {
        // A lookup queued just before the setting was turned off.
        guard ConfigurationManager.shared.hanjaEnabled else { return }
        // Toggle behavior: if already showing, dismiss
        if HanjaCandidateWindow.shared.isVisible {
            HanjaCandidateWindow.shared.dismiss()
            hanjaMode = false
            hanjaKey = ""
            DebugLogger.log("Hanja: Toggled off")
            return
        }
        
        // Use the active controller's current adapter, fallback to strong delegate on composer
        let activeDelegate = PriTypeInputController.sharedController?.currentAdapter
            ?? lastStrongDelegate
            ?? lastDelegate
        guard let delegate = activeDelegate else {
            DebugLogger.log("Hanja: No delegate available")
            return
        }
        _ = handleHanjaLookup(delegate: delegate)
    }
    
    /// Handle Option key to trigger Hanja candidate lookup
    /// Searches based on the current preedit (composing) text, or the last committed Hangul character
    private func handleHanjaLookup(delegate: HangulComposerDelegate) -> Bool {
        guard inputMode == .korean else {
            DebugLogger.log("Hanja: Not in Korean mode, skipping")
            return false
        }
        
        // Look up the word ending at the caret. Text comes from OWNED state first
        // (preedit, then localTextBuffer). Reading the host's text is the last
        // resort: in Chromium/Electron it picks up text that wasn't just typed.
        let preedit = context.getPreeditString()
        let preeditStr = CompositionHelpers.convertAndNormalize(preedit)
        let hadPreedit = !preeditStr.isEmpty

        // The buffer counts only if it was filled in the app that has focus now.
        // Use NSWorkspace as the primary source of truth for frontmost app, because
        // cachedContext might be stale if the user clicked a non-text area in a new app.
        let currentBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            ?? PriTypeInputController.sharedController?.cachedContext?.bundleId ?? ""
        let buffer = isBufferFromApp(currentBundleId) ? localTextBuffer : ""

        let lookupText: String
        let entries: [HanjaEntry]
        if hadPreedit && !preeditStr.allSatisfy(\.isHangulSyllable) {
            // A lone jamo is not part of a word: ㅁ → ★, ♥, … from the symbol table.
            lookupText = preeditStr
            entries = HanjaManager.shared.search(key: preeditStr)
        } else {
            if hadPreedit || !HanjaManager.trailingHangulWord(in: buffer).isEmpty {
                lookupText = buffer + preeditStr
            } else {
                // Nothing typed here: the caret was moved, e.g. with the arrow keys.
                lookupText = delegate.textBeforeCursor(length: HanjaManager.maxWordLength) ?? ""
            }
            entries = HanjaManager.shared.searchWord(endingWith: lookupText)
        }
        let searchKey = entries.first?.hangul ?? ""
        DebugLogger.logSensitive("Hanja: lookup", sensitiveContent: "'\(lookupText)' (preedit='\(preeditStr)')")

        guard !entries.isEmpty else {
            DebugLogger.log("Hanja: No candidates")
            return true // Consume the key but don't open the window
        }
        
        DebugLogger.log("Hanja: Found \(entries.count) entries for '\(searchKey)'")
        
        hanjaMode = true
        hanjaKey = searchKey
        
        // IMPORTANT: Capture cursor position BEFORE commit.
        // Chromium/Electron apps update cursor position asynchronously after commit,
        // so firstRect() returns garbage values if called after commitComposition().
        // While preedit is active, the cursor is at the marked text position → valid
        // coordinates. The strategy chain lives in CursorRectResolver.
        let cursorRect = CursorRectResolver.resolve(client: PriTypeInputController.sharedController?.client())

        // Commit preedit AFTER capturing cursor position
        if hadPreedit {
            commitComposition(delegate: delegate)
        }
        
        // Snapshot: Capture client identity at show time for validation at select time.
        // Use ObjectIdentifier instead of weak reference: if the weak ref is deallocated,
        // validation would be skipped and hanja could be inserted into a wrong client.
        let snapshotClientID: ObjectIdentifier? = {
            if let client = PriTypeInputController.sharedController?.client() as? IMKTextInput {
                return ObjectIdentifier(client as AnyObject)
            }
            return nil
        }()
        
        HanjaCandidateWindow.shared.show(
            entries: entries,
            cursorRect: cursorRect,
            onSelect: { [weak self] entry in
                guard let self = self else { return }
                
                // Validate: Ensure the client hasn't changed since the candidate window was shown
                if let controller = PriTypeInputController.sharedController,
                   let client = controller.client() {
                    
                    // Safety check: if the client object changed (focus switched), dismiss silently
                    guard let originalID = snapshotClientID,
                          ObjectIdentifier(client as AnyObject) == originalID else {
                        DebugLogger.log("Hanja: Client changed since show — aborting selection")
                        self.hanjaMode = false
                        self.hanjaKey = ""
                        return
                    }
                    
                    // The candidate replaces the text it was looked up from, which
                    // may be a whole word ending at the caret.
                    let replacementLength = entry.hangul.utf16.count
                    let selRange = client.selectedRange()
                    if selRange.location != NSNotFound && selRange.location < 10000000 && selRange.location >= replacementLength {
                        let replaceRange = NSRange(location: selRange.location - replacementLength, length: replacementLength)
                        let current = client.attributedSubstring(from: replaceRange)?.string
                        guard Self.canReplace(current, with: entry) else {
                            DebugLogger.log("Hanja: text before the caret changed since show — aborting selection")
                            self.hanjaMode = false
                            self.hanjaKey = ""
                            return
                        }
                        client.insertText(entry.hanja, replacementRange: replaceRange)
                    } else {
                        // Fallback: just insert
                        client.insertText(entry.hanja, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
                    }
                }
                
                self.localTextBuffer = String(self.localTextBuffer.dropLast(entry.hangul.count)) + entry.hanja
                self.hanjaMode = false
                self.hanjaKey = ""
                DebugLogger.log("Hanja: Selected '\(entry.hanja)' (\(entry.meaning))")
            },
            onDismiss: { [weak self] in
                self?.hanjaMode = false
                self?.hanjaKey = ""
                DebugLogger.log("Hanja: Dismissed")
            }
        )
        
        return true
    }
    
    /// Whether a candidate may replace the text before the caret. A word spans
    /// several syllables, so a stale buffer (the caret moved by a click the IME
    /// never saw) would replace the wrong text. When the host reports that text
    /// it must match. A single syllable, or a host that cannot report its text,
    /// keeps the old behavior of replacing blindly: Chromium hosts can report
    /// garbage, and one syllable was never checked.
    static func canReplace(_ current: String?, with entry: HanjaEntry) -> Bool {
        guard let current, entry.hangul.count > 1 else { return true }
        return current.precomposedStringWithCanonicalMapping == entry.hangul.precomposedStringWithCanonicalMapping
    }

    // MARK: - Cursor Position Validation

    /// Forwarder kept for API stability (tests/benchmark). The implementation and
    /// the full coordinate strategy chain live in `CursorRectResolver`.
    public static func isValidCursorRect(_ rect: NSRect) -> Bool {
        CursorRectResolver.isValidCursorRect(rect)
    }
}

// MARK: - Character Extension for Hangul detection
extension Character {
    var isHangulChar: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        // Hangul Syllables: U+AC00 - U+D7A3
        // Hangul Jamo: U+1100 - U+11FF
        // Hangul Compatibility Jamo: U+3130 - U+318F
        let v = scalar.value
        return (v >= 0xAC00 && v <= 0xD7A3) ||
               (v >= 0x1100 && v <= 0x11FF) ||
               (v >= 0x3130 && v <= 0x318F)
    }
}
