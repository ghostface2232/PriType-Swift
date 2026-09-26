import Cocoa
import InputMethodKit

// Protocol and InputMode are in HangulComposerTypes.swift

// MARK: - HangulComposer

/// Core Hangul composition, from keystrokes to what the host is shown
///
/// `HangulComposer` handles the complete lifecycle of Hangul text input:
/// - Converting keystrokes to Hangul syllables
/// - Managing preedit (composition in progress) state
/// - Committing finalized text
/// - Applying Korean or English mode selected by the IMK controller
///
/// ## Overview
/// The syllable itself is composed by `DubeolsikEngine`, the standard 두벌식
/// automaton. The composer decides what each key is — a letter, a special key,
/// a shortcut — and delivers the result through its delegate.
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
        engine.isComposing
    }

    /// The live syllable as the host is shown it ("" when nothing is composing).
    public var preeditForDisplay: String {
        engine.composing.map(String.init) ?? ""
    }
    
    // MARK: - Dependencies

    /// Configuration provider (injected for testability)
    private let configuration: ConfigurationProviding
    
    // MARK: - Private Properties
    
    /// The adapter of the last key handled. Held strongly: IMK deallocates
    /// controllers often (Electron apps), and a mode switch or Hanja lookup that
    /// arrives between two keys still needs somewhere to deliver text.
    private var lastDelegate: (any HangulComposerDelegate)?

    /// Whether this composer opened the Hanja candidate window
    private var hanjaMode = false
    
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
    
    // MARK: - Engine

    /// The 두벌식 automaton holding the syllable being typed. 두벌식 표준 is the
    /// only supported layout.
    private var engine = DubeolsikEngine()

    /// Whether the key handled before the current one was a Backspace. The
    /// decomposed-syllable rewrite needs it to tell a host that ignored the last
    /// rewrite from a caret that simply came back to the same offset. Anything
    /// that takes a key away from the composer (a toggle, the Hanja window, a
    /// secure field) clears it: the next Backspace is not the consecutive one.
    private var previousKeyWasBackspace = false
    
    /// Text convenience handler (double-space period)
    /// Owns all state for text convenience features
    private let textConvenience: TextConvenienceHandler

    /// Whether the user's Latin layout moved punctuation onto the letter keys.
    private var latinLayout = LatinLayoutObserver()

    /// Shows Hanja candidates. The IMK harness replaces it with a recorder.
    public var candidatePresenter: any HanjaCandidatePresenting = HanjaCandidateWindow.shared

    /// The app in front, which a Hanja lookup checks the input buffer against.
    /// The IMK harness replaces it with its focused field's app.
    public var frontmostBundleID: () -> String? = HangulComposer.systemFrontmostBundleID

    public static func systemFrontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

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
    /// Forget what the last key was. The composer is shared by every client, so a
    /// Backspace in one app must not make the first Backspace in another look like
    /// the second of a pair, nor a space the first of a double-space period.
    public func forgetKeyHistory() {
        previousKeyWasBackspace = false
        textConvenience.resetSpaceState()
    }

    /// Start judging the Latin layout from what it puts on the letter keys
    /// (`LatinLayoutProbe`), for a layout just selected. Main thread only.
    func assumeLatinLayout(lettersTypingOtherwise keys: Set<UInt16>) {
        latinLayout = LatinLayoutObserver(lettersTypingOtherwise: keys)
    }

    public func setInputMode(_ mode: InputMode) {
        previousKeyWasBackspace = false
        modeSelectionRevision &+= 1
        guard inputMode != mode else {
            return
        }

        DebugLogger.log("setInputMode called externally: \(mode)")

        if let delegate = lastDelegate, engine.isComposing {
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
    private func handleSpecialKey(keyCode: UInt16, followsBackspace: Bool, delegate: HangulComposerDelegate) -> Bool? {
        // Return / Enter
        if keyCode == KeyCode.return || keyCode == KeyCode.numpadEnter {
            let hadComposition = engine.isComposing
            commitComposition(delegate: delegate)
            localTextBuffer = ""

            if hadComposition && ClientCompatibilityPolicy.needsReturnConsumedAfterCompositionCommit(bundleId: lastInputBundleId) {
                DebugLogger.log("Return -> committed composition and consumed original Return for host compatibility")
                return true
            }

            DebugLogger.log("Return -> committed composition and passed original Return to app (hadComposition=\(hadComposition))")
            delegate.forgetLastPrecomposedSyllable()
            return false
        }
        
        // Escape - only consume if there's an active composition to cancel
        if keyCode == KeyCode.escape {
            if engine.isComposing {
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
            guard engine.isComposing || !localTextBuffer.isEmpty else {
                textConvenience.resetSpaceState()
                return false
            }
            commitComposition(delegate: delegate)
            let result = textConvenience.handleDoubleSpacePeriod(buffer: &localTextBuffer, delegate: delegate)
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
            delegate.forgetLastPrecomposedSyllable()
            return false
        }
        
        // Tab
        if keyCode == KeyCode.tab {
            commitComposition(delegate: delegate)
            localTextBuffer = ""
            // Tab moves to the next field, which is a fresh start for the rewrite
            // even when the client object stays the same (every web field in a
            // Chromium window shares one).
            delegate.resumePrecomposing()
            return false
        }
        
        // Backspace
        if keyCode == KeyCode.backspace {
            if let before = engine.composing {
                engine.backspace()
                if !engine.isComposing {
                    // The last jamo is going. Commit it and let the host delete it
                    // with its own deleteBackward, instead of cancelling the marked
                    // text with setMarkedText(""). That is what Apple's Korean IME
                    // does (recorded on macOS 27: insertText("ㅇ") then
                    // deleteBackward:), and it matters: Figma's canvas editor treats
                    // a cancelled composition as committed, so the cancel left the
                    // jamo behind ("요" + ⌫⌫ → "ㅇ"). The end result is the same
                    // everywhere else. Not added to localTextBuffer: the host
                    // removes it right away.
                    delegate.insertText(String(before))
                    // The host deletes that jamo, so what ends up before the caret
                    // is whatever preceded the composition — not our own output.
                    delegate.forgetLastPrecomposedSyllable()
                    return false
                }
                delegate.setMarkedText(engine.composing.map(String.init) ?? "")
                return true
            }
            if !localTextBuffer.isEmpty { localTextBuffer.removeLast() }
            delegate.precomposeSyllableBeforeCursor(followsBackspace: followsBackspace)
            return false
        }
        
        return nil  // Not a special key
    }
    
    /// Type the character of a key that carries no jamo: commit the syllable
    /// being typed, then insert the character if it is printable ASCII.
    /// - Returns: `true` if the character was inserted, `false` if skipped
    private func processCharacter(_ char: Unicode.Scalar, delegate: HangulComposerDelegate) -> Bool {
        let charCode = UInt32(char.value)

        // Skip non-printable characters
        if KeyCode.shouldPassThrough(charCode) {
            return false
        }

        if engine.isComposing {
            commitComposition(delegate: delegate)
        }

        if KeyCode.isPrintableASCII(charCode) {
            delegate.insertText(String(char))
            appendToBuffer(String(char))
            return true
        }

        DebugLogger.log("Skipping a character that is not printable ASCII")
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
        lastDelegate = delegate

        // Only handle key down events for actual typing
        if event.type != .keyDown {
            return false
        }
        
        // Global context invalidation:
        // Any navigation or confirmation key (Arrow, Tab, Return) invalidates our local text context
        // because the cursor has likely moved, changing the text before it.
        let keyCode = event.keyCode
        let followsBackspace = previousKeyWasBackspace
        // Only a plain Backspace counts: ⌘⌫ and ⌥⌫ delete a line or a word, so the
        // key after them is not continuing anything the rewrite guard cares about.
        let isPlainBackspace = keyCode == KeyCode.backspace
            && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        previousKeyWasBackspace = isPlainBackspace
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
        // settings — except the double-space period. macOS applies that in the
        // input source, so behind a third-party input method no host does
        // (measured: TextEdit, KakaoTalk, Chrome and Electron all type two spaces).
        if inputMode == .english {
            // Text this keystroke commits is precomposed already, and a host that
            // answers from before the commit would describe a document that no
            // longer exists — so the rewrite only runs when nothing was composing.
            let wasComposing = engine.isComposing
            if wasComposing {
                commitComposition(delegate: delegate)
            }
            localTextBuffer = ""
            if isPlainBackspace {
                if !wasComposing {
                    delegate.precomposeSyllableBeforeCursor(followsBackspace: followsBackspace)
                }
            } else {
                // Every other key types, moves the caret or runs a shortcut, and
                // the paths below that would say so are past this early return.
                delegate.forgetLastPrecomposedSyllable()
            }
            guard keyCode == KeyCode.space, !wasComposing,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                textConvenience.resetSpaceState()
                return false
            }
            // The host typed this text, so what precedes the caret is asked of it —
            // and only for a quick second space, the one that can become a period.
            var typed = textConvenience.followsQuickSpace ? delegate.textBeforeCursor(length: 2) ?? "" : ""
            return textConvenience.handleDoubleSpacePeriod(buffer: &typed, delegate: delegate) == .convertedToPeriod
        }
        
        // If Hanja candidate window is visible, forward keys to it
        if hanjaMode {
            let consumed = candidatePresenter.handleKey(event)
            if !candidatePresenter.isVisible {
                hanjaMode = false
            }
            if consumed {
                previousKeyWasBackspace = false
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
             if engine.isComposing {
                 commitComposition(delegate: delegate)
             }
             localTextBuffer = "" // Any system shortcut (Cmd+V, Cmd+Z, etc.) invalidates local context
             // A shortcut can paste, undo or move the caret anywhere.
             delegate.forgetLastPrecomposedSyllable()
             return false
        }
        
        // Letter keys compose from their position, not the active Latin layout: the
        // Hangul layout is defined on QWERTY positions, and only Shift (never Caps
        // Lock) picks the upper row. Every other key keeps what the layout typed,
        // unless the layout put punctuation on the letter keys: then digits and
        // punctuation come from their US positions (`LatinLayoutObserver`).
        let shifted = event.modifierFlags.contains(.shift)
        latinLayout.observe(keyCode: keyCode, characters: event.characters)
        let letter = QwertyKeyMap.character(for: keyCode, shifted: shifted)
        let positional = letter ?? (latinLayout.displacesPunctuation
            ? QwertyKeyMap.punctuation(for: keyCode, shifted: shifted)
            : nil)
        guard let inputCharacters = positional ?? event.characters, !inputCharacters.isEmpty else {
            return false
        }
        
        // Handle special keys (Return, Escape, Space, Arrow, Tab, Backspace)
        if let result = handleSpecialKey(keyCode: keyCode, followsBackspace: followsBackspace, delegate: delegate) {
            return result
        }
        
        // Filter: If input contains non-printable characters (e.g., function keys, arrows)
        // This catches Fn+Arrow (Home/End/PageUp/PageDown) and other navigation keys
        // that don't match the KeyCode enum in handleSpecialKey.
        if let firstScalar = inputCharacters.unicodeScalars.first {
            let firstCharCode = UInt32(firstScalar.value)
            if KeyCode.shouldPassThrough(firstCharCode) {
                DebugLogger.log("Non-printable key detected, passing to system")
                if engine.isComposing {
                    commitComposition(delegate: delegate)
                }
                localTextBuffer = ""
                // Home, End, Page Up/Down and friends all move the caret.
                delegate.forgetLastPrecomposedSyllable()
                return false
            }
        }
        
        // A letter key types its jamo; a key that carries none types its character.
        if let key = letter?.first, let step = engine.type(key) {
            updateComposition(step, delegate: delegate)
            return true
        }

        var handledAtLeastOnce = false
        for char in inputCharacters.unicodeScalars {
            if processCharacter(char, delegate: delegate) {
                handledAtLeastOnce = true
            }
        }

        // If we processed anything, we return true to stop system from handling duplicates.
        return handledAtLeastOnce
    }

    /// Delivers what a key did to the syllable: the syllable it completed, then
    /// the one being typed.
    ///
    /// ORDERING INVARIANT (load-bearing — do not reorder):
    /// commit (insertText) MUST happen BEFORE the preedit update (setMarkedText).
    /// This is the macOS equivalent of the Windows Korean IME model — only the
    /// single in-progress syllable is ever "marked", and the previous syllable is
    /// committed the instant it is complete, on a syllable boundary. Reordering
    /// (mark-before-commit) reintroduces stale-cursor preedit (cf. kitty #4219) and
    /// breaks the experimental DirectInsertionAdapter, which relies on insertText
    /// arriving first to finalize the live preedit before the new one is rendered.
    /// See Docs/KoreanWindowsInputFeasibility.md (Phase 0/1).
    private func updateComposition(_ step: DubeolsikEngine.Step, delegate: HangulComposerDelegate) {
        if let committed = step.committed {
            let text = String(committed)
            delegate.insertText(text)
            appendToBuffer(text)
        }
        delegate.setMarkedText(step.composing.map(String.init) ?? "")
    }

    /// Commits the syllable being typed, if any: `insertText` replaces the marked
    /// text with it, and that ends the composition in the host. Nothing needs
    /// clearing after it — a `setMarkedText("")` there is one more round trip to
    /// the host, and in direct insertion a caret query and an empty insert.
    private func commitComposition(delegate: HangulComposerDelegate) {
        guard let syllable = engine.flush() else { return }
        let text = String(syllable)
        delegate.insertText(text)
        appendToBuffer(text)
        DebugLogger.logSensitive("commitComposition inserted", sensitiveContent: "'\(text)'")
    }

    /// Cancels the current composition without committing
    ///
    /// Resets the engine and clears the marked text display.
    /// Use this when the user explicitly cancels input (e.g., pressing Escape).
    ///
    /// - Parameter delegate: The delegate to receive the cleared state
    private func cancelComposition(delegate: HangulComposerDelegate) {
        engine.reset()
        delegate.setMarkedText("")
        // Do NOT clear localTextBuffer on cancel, as previously committed text is still valid context
    }
    
    /// Flush any in-progress composition and return its committed string ("" if none).
    ///
    /// Nothing is sent to a client: the caller (`InputSession.finalize`) delivers
    /// the text itself, or — in direct insertion — knows it is already there.
    public func flushCommitString() -> String {
        guard let syllable = engine.flush() else { return "" }
        let committed = String(syllable)
        // What the engine holds is always Hangul: a syllable or a lone jamo.
        localTextBuffer = committed
        return committed
    }
    
    /// Take the syllable being composed out of the engine, leaving it idle, to be
    /// resumed in another client (`resumeComposition(_:)`).
    func setAsideComposition() -> DubeolsikEngine {
        defer { engine.reset() }
        return engine
    }

    /// Put back a syllable taken out with `setAsideComposition()`.
    func resumeComposition(_ syllable: DubeolsikEngine) {
        engine = syllable
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
        previousKeyWasBackspace = false
        engine.reset()
        localTextBuffer = ""
        textConvenience.resetSpaceState()
    }
    
    /// Bundle ID of the app where the last keystroke was processed.
    /// Used to prevent cross-app hanja leaking: if the current app differs from
    /// the app that populated localTextBuffer, the buffer is considered stale.
    private var lastInputBundleId: String = ""

    /// The client (text field) the last keystroke went to. Weak, and compared by
    /// identity: a field that has gone away must not be mistaken for a new one
    /// that happens to reuse its address.
    private weak var lastInputClient: AnyObject?

    /// Record which field the current keystroke is from (called from handle via controller)
    ///
    /// A keystroke in another field empties the buffer: what it holds was typed
    /// there. Leaving a field commits its syllable and keeps it as the buffer's
    /// last character, and once this records the new field `isBuffer(from:client:)`
    /// would vouch for that stranger, so a lookup would join it to the word
    /// typed here (…한 in one field, 국 in the next → 韓國). The app alone does
    /// not tell fields apart: two fields of one window are one app.
    public func markKeystroke(bundleId: String, client: AnyObject? = nil) {
        if bundleId != lastInputBundleId || client !== lastInputClient {
            localTextBuffer = ""
            forgetKeyHistory()
        }
        lastInputBundleId = bundleId
        lastInputClient = client
    }

    /// Whether the buffer was typed in `client` of the app `bundleId`.
    public func isBuffer(from bundleId: String, client: AnyObject?) -> Bool {
        !lastInputBundleId.isEmpty && lastInputBundleId == bundleId && client === lastInputClient
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
        candidatePresenter.dismiss()
        hanjaMode = false
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
        if candidatePresenter.isVisible {
            candidatePresenter.dismiss()
            hanjaMode = false
            DebugLogger.log("Hanja: Toggled off")
            return
        }
        
        // Use the active controller's current adapter, fallback to the last key's
        let activeDelegate = PriTypeInputController.sharedController?.currentAdapter
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

        // The lookup is the one user action that can wait on another app: the
        // caret-resolution chain below is synchronous Accessibility IPC. Timed as
        // one interval with the search and the caret nested, and carrying no part
        // of the word or the candidates — see `Signposts`.
        let recording = Signposts.isRecording
        let lookupID = recording ? Signposts.hanja.makeSignpostID() : .invalid
        let lookup = recording
            ? Signposts.hanja.beginInterval(Signposts.HanjaStage.lookup, id: lookupID) : nil
        defer { if let lookup { Signposts.hanja.endInterval(Signposts.HanjaStage.lookup, lookup) } }
        
        // Look up the word ending at the caret. Text comes from OWNED state first
        // (preedit, then localTextBuffer). Reading the host's text is the last
        // resort: in Chromium/Electron it picks up text that wasn't just typed.
        let preeditStr = engine.composing.map(String.init) ?? ""
        let hadPreedit = !preeditStr.isEmpty

        // The buffer counts only if it was filled in the field that has focus now.
        // Use NSWorkspace as the primary source of truth for frontmost app, because
        // cachedContext might be stale if the user clicked a non-text area in a new app.
        // A click into another field of the same app, with no key typed there yet,
        // changes the client but not the app.
        let currentBundleId = frontmostBundleID()
            ?? PriTypeInputController.sharedController?.cachedContext?.bundleId ?? ""
        let currentClient = PriTypeInputController.sharedController?.currentClient as AnyObject?
        let buffer = isBuffer(from: currentBundleId, client: currentClient) ? localTextBuffer : ""

        let searchStage = recording
            ? Signposts.hanja.beginInterval(Signposts.HanjaStage.dictionarySearch, id: lookupID) : nil
        let lookupText: String
        let entries: [HanjaEntry]
        // Whether the looked-up text is the end of localTextBuffer (after the
        // preedit is committed below), so a selection can replace it there too.
        var lookupIsBufferTail = true
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
                lookupIsBufferTail = false
            }
            entries = HanjaManager.shared.searchWord(endingWith: lookupText)
        }
        if let searchStage {
            Signposts.hanja.endInterval(Signposts.HanjaStage.dictionarySearch, searchStage)
        }
        let searchKey = entries.first?.hangul ?? ""
        DebugLogger.logSensitive("Hanja: lookup", sensitiveContent: "'\(lookupText)' (preedit='\(preeditStr)')")

        guard !entries.isEmpty else {
            DebugLogger.log("Hanja: No candidates")
            return true // Consume the key but don't open the window
        }
        
        DebugLogger.logSensitive("Hanja: found \(entries.count) entries",
                                 sensitiveContent: "'\(searchKey)'")
        
        hanjaMode = true
        
        // IMPORTANT: Capture cursor position BEFORE commit.
        // Chromium/Electron apps update cursor position asynchronously after commit,
        // so firstRect() returns garbage values if called after commitComposition().
        // While preedit is active, the cursor is at the marked text position → valid
        // coordinates. The strategy chain lives in CursorRectResolver.
        let cursorRect = Signposts.interval(Signposts.hanja, Signposts.HanjaStage.resolveCaret,
                                            id: lookupID, recording: recording) {
            CursorRectResolver.resolve(client: PriTypeInputController.sharedController?.currentClient)
        }

        // Commit preedit AFTER capturing cursor position
        if hadPreedit {
            commitComposition(delegate: delegate)
        }
        
        // Snapshot: Capture client identity at show time for validation at select time.
        // Use ObjectIdentifier instead of weak reference: if the weak ref is deallocated,
        // validation would be skipped and hanja could be inserted into a wrong client.
        let snapshotClientID: ObjectIdentifier? = {
            if let client = PriTypeInputController.sharedController?.currentClient {
                return ObjectIdentifier(client as AnyObject)
            }
            return nil
        }()
        
        candidatePresenter.show(
            entries: entries,
            cursorRect: cursorRect,
            onSelect: { [weak self, lookupIsBufferTail] entry in
                guard let self = self else { return }
                
                // Validate: Ensure the client hasn't changed since the candidate window was shown
                if let client = PriTypeInputController.sharedController?.currentClient {
                    
                    // Safety check: if the client object changed (focus switched), dismiss silently
                    guard let originalID = snapshotClientID,
                          ObjectIdentifier(client as AnyObject) == originalID else {
                        DebugLogger.log("Hanja: Client changed since show — aborting selection")
                        self.hanjaMode = false
                        return
                    }
                    
                    // The candidate replaces the text it was looked up from, which
                    // may be a whole word ending at the caret.
                    let replacementLength = entry.hangul.utf16.count
                    let selRange = client.selectedRange()
                    if selRange.location != NSNotFound && selRange.location < 10000000 {
                        // A caret closer to the start than the word is long
                        // has left the word behind: inserting there instead
                        // would put the Hanja in the middle of other text.
                        guard selRange.location >= replacementLength else {
                            DebugLogger.log("Hanja: the caret is before where the word could end — aborting selection")
                            self.hanjaMode = false
                            return
                        }
                        let replaceRange = NSRange(location: selRange.location - replacementLength, length: replacementLength)
                        let current = client.attributedSubstring(from: replaceRange)?.string
                        guard Self.canReplace(current, with: entry) else {
                            DebugLogger.log("Hanja: text before the caret changed since show, or the host would not show it — aborting selection")
                            self.hanjaMode = false
                            return
                        }
                        client.insertText(entry.hanja, replacementRange: replaceRange)
                    } else {
                        // The host reports no usable caret (NSNotFound, or
                        // Chromium's garbage), so nothing can be checked or
                        // replaced: insert at the caret, as always.
                        client.insertText(entry.hanja, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
                    }
                }
                
                // Read from the host, the word was never in the buffer: start over
                // from what the caret now follows.
                self.localTextBuffer = lookupIsBufferTail
                    ? String(self.localTextBuffer.dropLast(entry.hangul.count)) + entry.hanja
                    : entry.hanja
                self.hanjaMode = false
                DebugLogger.logSensitive("Hanja: selected a candidate",
                                         sensitiveContent: "'\(entry.hanja)' (\(entry.meaning))")
            },
            onDismiss: { [weak self] in
                self?.hanjaMode = false
                DebugLogger.log("Hanja: Dismissed")
            },
            onClickOutside: { [weak self] in
                // The click may have moved the caret, and with nothing marked
                // IMK does not say so: the buffer no longer ends at the caret,
                // and the next lookup must not convert the word typed before it.
                self?.localTextBuffer = ""
            }
        )
        
        return true
    }
    
    /// Whether a candidate may replace the text before the caret. The caret can
    /// move without the IME hearing of it (a click, when nothing is marked), and
    /// then the text before it is not what was looked up — for one syllable as
    /// much as for a word. So the host's text there must match.
    /// Checking one syllable also refuses decomposed (NFD) text, where the
    /// replaced UTF-16 unit would be a lone jamo of the syllable.
    ///
    /// A host that reports a caret but not the text before it (nil, or an empty
    /// string from hosts that answer with nothing) is refused too, as
    /// `BaseClientAdapter.replaceTextBeforeCursor` refuses it: unreadable is not
    /// the same as unchanged, and a replacement range computed from a caret that
    /// moved, or from a stale one, would overwrite whatever now sits there.
    static func canReplace(_ current: String?, with entry: HanjaEntry) -> Bool {
        guard let current, !current.isEmpty else { return false }
        return current.precomposedStringWithCanonicalMapping == entry.hangul.precomposedStringWithCanonicalMapping
    }

    // MARK: - Cursor Position Validation

    /// Forwarder kept for API stability (tests/benchmark). The implementation and
    /// the full coordinate strategy chain live in `CursorRectResolver`.
    public static func isValidCursorRect(_ rect: NSRect) -> Bool {
        CursorRectResolver.isValidCursorRect(rect)
    }
}
