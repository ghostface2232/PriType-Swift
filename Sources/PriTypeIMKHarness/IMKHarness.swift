import Cocoa
import InputMethodKit
import PriTypeCore

/// Drives PriType's real IMK controllers against `FakeTextClient` fields.
///
/// Everything below `handle()` is the shipping code path: session management,
/// the delivery adapter, the composer, mode transitions and focus handling. Only
/// the two ends are simulated: key events are built here instead of coming from
/// the window server, and the "app" is a `FakeTextClient`. Reporting a toggle to
/// macOS is recorded instead of performed, so a run never changes the machine's
/// input source.
///
/// Main thread only, like IMK itself.
public final class IMKHarness {
    /// A text field in some app, with the controller IMK would give it.
    public struct Field {
        public let client: FakeTextClient
        public let controller: PriTypeInputController
    }

    /// Keys that do not type a character of their own.
    public enum Key: Sendable {
        case space, backspace, `return`, escape, tab, left, right, up, down

        var keyCode: UInt16 {
            switch self {
            case .space: return 49
            case .backspace: return 51
            case .return: return 36
            case .escape: return 53
            case .tab: return 48
            case .left: return 123
            case .right: return 124
            case .down: return 125
            case .up: return 126
            }
        }

        var characters: String {
            switch self {
            case .space: return " "
            case .backspace: return "\u{7F}"
            case .return: return "\r"
            case .escape: return "\u{1B}"
            case .tab: return "\t"
            case .left: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            case .right: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
            case .down: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
            case .up: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
            }
        }
    }

    /// Modes the controllers reported to macOS after a toggle, in order.
    public private(set) var reportedModes: [InputMode] = []
    public private(set) var focused: Field?

    /// Event time of the next key, on `NSEvent.timestamp`'s clock. Advances by
    /// `keyInterval` per key so toggles can be placed between keystrokes.
    public private(set) var clock: TimeInterval
    /// Stay clear of the 50 ms duplicate-keyDown window (`KeyEventDedup`): at
    /// exactly 0.05 the float clock sometimes landed a hair under it, and a
    /// repeated key (backspace, Escape, "ss") was dropped as a re-delivery.
    public var keyInterval: TimeInterval = 0.08

    /// Stands in for the Hanja candidate window while the harness runs.
    public let candidates = FakeCandidatePresenter()

    public init() {
        clock = ProcessInfo.processInfo.systemUptime
        PriTypeInputController.systemModeReporter = { [weak self] mode in
            self?.reportedModes.append(mode)
        }
        InputModeCoordinator.shared.applyPendingKeyActions()
        let composer = PriTypeInputController.sharedComposer
        composer.setInputMode(.korean)
        // The composer is shared: start from no remembered text, and let a
        // Hanja lookup see the focused field's app as the one in front.
        composer.clearLocalBuffer()
        composer.candidatePresenter = candidates
        composer.frontmostBundleID = { [weak self] in self?.focused?.client.bundleID }
    }

    /// A new field, not yet focused.
    public func makeField(bundleID: String = "com.pritype.imk-harness") -> Field {
        let client = FakeTextClient(bundleID: bundleID)
        // IMK only accepts its own client proxy here. PriType works from the
        // `sender` IMK passes to each call, which the harness supplies instead.
        let controller = PriTypeInputController(server: nil, delegate: nil, client: nil)!
        return Field(client: client, controller: controller)
    }

    /// Move focus to `field`: the current field's controller is deactivated,
    /// then the new one activated, the order IMK uses.
    public func focus(_ field: Field) {
        if let focused, focused.client !== field.client {
            focused.controller.deactivateServer(focused.client)
        }
        field.controller.activateServer(field.client)
        focused = field
    }

    /// Move focus to `field` in the order some hosts use: the new controller is
    /// activated while the current one is still active. The field left behind
    /// is not deactivated; the test does that when it wants the late call.
    public func activateAhead(_ field: Field) {
        field.controller.activateServer(field.client)
        focused = field
    }

    /// Focus leaves every field (e.g. another app without text input).
    public func blur() {
        guard let focused else { return }
        focused.controller.deactivateServer(focused.client)
        self.focused = nil
    }

    // MARK: Keys

    /// Type `text` key by key. Letters are typed by their US QWERTY position, so
    /// "gksrmf" gives 한글 in Korean mode; an upper-case letter adds Shift.
    @discardableResult
    public func type(_ text: String) -> [Bool] {
        text.map { character in
            if character == " " { return press(.space) }
            guard let (keyCode, shifted) = Self.usKey(for: character) else {
                preconditionFailure("No US key types \(character)")
            }
            return keyDown(keyCode: keyCode, characters: String(character),
                           modifiers: shifted ? .shift : [])
        }
    }

    /// Press a non-character key.
    @discardableResult
    public func press(_ key: Key, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        keyDown(keyCode: key.keyCode, characters: key.characters, modifiers: modifiers)
    }

    /// One keyDown through `handle()`. If the input method passes it on, the field
    /// gets the host's default action. Returns whether the input method handled it.
    @discardableResult
    public func keyDown(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard let field = focused else { preconditionFailure("No focused field") }
        let event = makeEvent(keyCode: keyCode, characters: characters, modifiers: modifiers)
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let handled = field.controller.handle(event, client: field.client)
        if !handled {
            field.client.performHostAction(for: event)
        }
        keyLatencies.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start)
        return handled
    }

    /// For each key since the last `resetLatencies()`: nanoseconds from the
    /// keyDown entering `handle()` until the field holds its result — the
    /// composition marked or committed, or the host's own action done. This is
    /// the input method's share of key-to-text latency; the window server's
    /// delivery and the host's drawing come on top.
    public private(set) var keyLatencies: [UInt64] = []

    public func resetLatencies() { keyLatencies.removeAll() }

    /// A keyDown event stamped with the harness clock, which then advances.
    public func makeEvent(keyCode: UInt16, characters: String,
                          modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: clock,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: keyCode)!
        clock += keyInterval
        return event
    }

    // MARK: Mode and focus events

    /// The toggle key, pressed now, handled on main as the key monitor hands it over.
    public func toggle() {
        InputModeCoordinator.shared.requestToggle(source: .customKey, eventTime: clock)
        clock += keyInterval
    }

    /// The toggle key as the event tap sees it: recorded off main with its key
    /// time, not yet run. The next keystroke typed after it applies it, before
    /// the main-queue hop does — the race the ordering queue exists for.
    public func toggleFromKeyMonitor() {
        let time = clock
        clock += keyInterval
        let done = DispatchSemaphore(value: 0)
        Thread {
            InputModeCoordinator.shared.requestToggle(source: .customKey, eventTime: time)
            done.signal()
        }.start()
        done.wait()
    }

    /// macOS selected a PriType mode (Caps Lock, the input menu, or the echo of
    /// a toggle report).
    public func systemSelects(_ mode: InputMode) {
        guard let field = focused else { preconditionFailure("No focused field") }
        let id = mode == .english ? "com.pritype.inputmethod.v2.english" : "com.pritype.inputmethod.v2"
        field.controller.setValue(id, forTag: Int(kTextServiceInputModePropertyTag), client: field.client)
    }

    /// A click outside the composition: IMK asks the controller to commit.
    public func click() {
        guard let field = focused else { preconditionFailure("No focused field") }
        field.controller.commitComposition(field.client)
    }

    /// The Hanja key, pressed now, handled on main as the key monitor hands it
    /// over. The app maps the dictionary at launch; the harness does it here.
    public func pressHanjaKey() {
        HanjaManager.shared.loadIfNeeded()
        InputModeCoordinator.shared.requestHanjaLookup(eventTime: clock)
        clock += keyInterval
    }

    /// Run everything the key monitor queued, and leave the shared engine idle.
    public func finish() {
        InputModeCoordinator.shared.applyPendingKeyActions()
        blur()
        let composer = PriTypeInputController.sharedComposer
        composer.dismissHanjaCandidates(reason: "harness finished")
        composer.setInputMode(.korean)
        composer.candidatePresenter = HanjaCandidateWindow.shared
        composer.frontmostBundleID = HangulComposer.systemFrontmostBundleID
    }

    // MARK: US layout

    private static let letterKeys: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46
    ]
    private static let otherKeys: [Character: (UInt16, Bool)] = [
        "1": (18, false), "2": (19, false), "3": (20, false), "4": (21, false), "5": (23, false),
        "6": (22, false), "7": (26, false), "8": (28, false), "9": (25, false), "0": (29, false),
        "-": (27, false), "=": (24, false), "[": (33, false), "]": (30, false), ";": (41, false),
        "'": (39, false), ",": (43, false), ".": (47, false), "/": (44, false), "`": (50, false),
        "!": (18, true), "?": (44, true), ":": (41, true), "\"": (39, true)
    ]

    static func usKey(for character: Character) -> (UInt16, Bool)? {
        if let lower = character.lowercased().first, let code = letterKeys[lower] {
            return (code, character.isUppercase)
        }
        return otherKeys[character]
    }
}
