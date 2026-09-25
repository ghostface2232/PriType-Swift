import Cocoa
import InputMethodKit
import PriTypeCore

/// A text field for driving PriType's IMK controller without a host app.
///
/// It keeps a document, a selection and a marked range the way AppKit's text
/// system does, answers the `IMKTextInput` queries PriType makes, and logs every
/// call the input method makes into it, in order. Keys the input method does not
/// handle get the host's default action (`performHostAction`), as AppKit would
/// run them through `interpretKeyEvents`.
public final class FakeTextClient: NSObject, IMKTextInput, GlobalSecureInputReporting, @unchecked Sendable {
    /// One call into the client, in the order it happened.
    public enum Call: Equatable, CustomStringConvertible, Sendable {
        /// `setMarkedText` with the new marked string ("" ends the marked text).
        case mark(String)
        /// `insertText` from the input method.
        case insert(String)
        /// The host's own handling of a key the input method passed on.
        case host(String)
        /// `overrideKeyboardWithKeyboardNamed:`.
        case overrideKeyboard(String)
        /// An edit the host ignored because it was not accepting input (`ignoresEdits`).
        case dropped(String)

        public var description: String {
            switch self {
            case .mark(let text): return "mark(\(text))"
            case .insert(let text): return "insert(\(text))"
            case .host(let action): return "host(\(action))"
            case .overrideKeyboard(let name): return "override(\(name))"
            case .dropped(let text): return "dropped(\(text))"
            }
        }
    }

    public let bundleID: String
    public private(set) var calls: [Call] = []
    /// Called after every logged call; the latency probe listens here.
    public var onCall: ((Call) -> Void)?

    private var storage = NSMutableString()
    public private(set) var selection = NSRange(location: 0, length: 0)
    public private(set) var marked: NSRange?

    public init(bundleID: String = "com.pritype.imk-harness") {
        self.bundleID = bundleID
    }

    /// The whole document, marked text included.
    public var text: String { storage as String }
    /// The marked (still composing) part of the document, if any.
    public var markedText: String? { marked.map { storage.substring(with: $0) } }
    /// The document without its marked text: what a commit has made final.
    public var committedText: String {
        guard let marked else { return text }
        return storage.replacingCharacters(in: marked, with: "")
    }

    public func clearLog() { calls.removeAll() }

    // MARK: Re-entrant calls

    /// The synchronous calls the input method makes into the host during which IMK
    /// can deliver another controller call — its own `activateServer` or
    /// `deactivateServer` — before the first one returns.
    public enum Reentry: Sendable {
        case insertText, setMarkedText, validAttributes
    }

    private var reentries: [(Reentry, () -> Void)] = []

    /// Run `body` nested inside the next `call` the input method makes, after the
    /// host has taken it. Once only; queue several for several calls.
    public func onNext(_ call: Reentry, run body: @escaping () -> Void) {
        reentries.append((call, body))
    }

    private func reenter(_ call: Reentry) {
        guard let index = reentries.firstIndex(where: { $0.0 == call }) else { return }
        let body = reentries.remove(at: index).1
        body()
    }

    /// While set, the host is between losing and regaining activation and takes no
    /// edits from the input method: they are logged as `.dropped` and change
    /// nothing. TextEdit, finishing its activation just after a click, does this.
    public var ignoresEdits = false

    /// The host ends the composition itself and keeps the marked text as ordinary
    /// text, as `NSTextView.unmarkText()` does.
    public func unmarkText() {
        marked = nil
        log(.host("unmark"))
    }

    /// The client now fronts another field holding `text`, caret at its end. One
    /// client object stands for every web field in a Chromium window, so focus
    /// can move between fields with the input method still talking to it.
    public func showOtherField(_ text: String) {
        storage = NSMutableString(string: text)
        selection = NSRange(location: storage.length, length: 0)
        marked = nil
        log(.host("other field"))
    }

    /// The host throws its marked text away.
    public func discardMarkedText() {
        if let marked {
            storage.deleteCharacters(in: marked)
            selection = NSRange(location: marked.location, length: 0)
            self.marked = nil
        }
        log(.host("discard marked"))
    }

    /// Move the caret to `location` without telling the input method, as a
    /// click in the text does when nothing is marked.
    public func placeCaret(at location: Int) {
        selection = NSRange(location: max(0, min(storage.length, location)), length: 0)
    }

    private func log(_ call: Call) {
        calls.append(call)
        onCall?(call)
    }

    private static func plain(_ string: Any?) -> String {
        if let attributed = string as? NSAttributedString { return attributed.string }
        return string as? String ?? ""
    }

    /// Some hosts (Qt, custom text views) drop the replacement range and edit at
    /// the caret instead. Set this to model one.
    public var ignoresReplacementRange = false

    /// What this client answers when the input method asks whether macOS has a
    /// global secure-input warning up. False by default: whether a real one is up
    /// depends on whether the screen happens to be locked, and no test may depend
    /// on that. Set it to drive the pass-through path.
    public var reportsGlobalSecureInput = false

    /// Chromium and Electron answer queries from a snapshot that trails the real
    /// document. While this is set, every query answers from the state the field
    /// had when it was set, however many edits have landed since.
    public var freezeReports = false {
        didSet { frozen = freezeReports ? (NSString(string: storage as String), selection) : nil }
    }
    private var frozen: (text: NSString, selection: NSRange)?

    /// How many times the input method asked for the caret and for text. Query
    /// count is the IPC cost a host pays for a keystroke.
    public private(set) var selectionQueries = 0
    public private(set) var substringQueries = 0
    /// Context questions: `validAttributesForMarkedText` and `bundleIdentifier`.
    public private(set) var attributeQueries = 0
    public private(set) var bundleQueries = 0

    /// What a query sees: the live state, or the frozen snapshot when lagging.
    private var reported: (text: NSString, selection: NSRange) {
        frozen ?? (storage, selection)
    }

    public func resetQueryCounts() {
        selectionQueries = 0
        substringQueries = 0
        attributeQueries = 0
        bundleQueries = 0
    }

    /// Select `range`, as dragging over the text does.
    public func select(_ range: NSRange) {
        selection = range
    }

    /// Where an edit lands: the explicit range, else the marked text, else the
    /// selection — clamped to the document.
    ///
    /// A host always knows where its own caret is, even when it will not say:
    /// Google Docs answers every query with NSNotFound and still types where the
    /// user is looking. So an edit against an unusable reported selection lands at
    /// the end of the document rather than failing. Without this, a test that makes
    /// a host lie about its caret — which is the whole point of having one — dies
    /// with an out-of-bounds exception instead of reporting what the input method
    /// did about it.
    private func target(for replacementRange: NSRange) -> NSRange {
        if !ignoresReplacementRange,
           replacementRange.location != NSNotFound,
           NSMaxRange(replacementRange) <= storage.length {
            return replacementRange
        }
        return clampedToDocument(marked ?? selection)
    }

    private func clampedToDocument(_ range: NSRange) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: storage.length, length: 0)
        }
        let location = max(0, min(storage.length, range.location))
        return NSRange(location: location, length: max(0, min(storage.length - location, range.length)))
    }

    private func replace(_ range: NSRange, with string: String) -> NSRange {
        storage.replaceCharacters(in: range, with: string)
        return NSRange(location: range.location, length: (string as NSString).length)
    }

    // MARK: IMKTextInput — edits

    public func insertText(_ string: Any!, replacementRange: NSRange) {
        let text = Self.plain(string)
        guard !ignoresEdits else { return log(.dropped(text)) }
        let inserted = replace(target(for: replacementRange), with: text)
        marked = nil
        selection = NSRange(location: NSMaxRange(inserted), length: 0)
        log(.insert(text))
        reenter(.insertText)
    }

    public func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        let text = Self.plain(string)
        guard !ignoresEdits else { return log(.dropped(text)) }
        let inserted = replace(target(for: replacementRange), with: text)
        marked = inserted.length > 0 ? inserted : nil
        selection = NSRange(location: inserted.location + min(selectionRange.location, inserted.length),
                            length: 0)
        log(.mark(text))
        reenter(.setMarkedText)
    }

    // MARK: IMKTextInput — queries

    public func selectedRange() -> NSRange {
        selectionQueries += 1
        return reported.selection
    }

    public func markedRange() -> NSRange {
        marked ?? NSRange(location: NSNotFound, length: 0)
    }

    public func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        substringQueries += 1
        let text = reported.text
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return nil }
        return NSAttributedString(string: text.substring(with: range))
    }

    public func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
        guard range.location != NSNotFound, NSMaxRange(range) <= storage.length else { return nil }
        actualRange?.pointee = range
        return storage.substring(with: range)
    }

    public func length() -> Int { storage.length }

    public func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode,
                               inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int {
        selection.location
    }

    public func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! {
        lineRect?.pointee = lineRectForIndex?(index) ?? caretRect
        return [:]
    }

    /// What `attributes(forCharacterIndex:lineHeightRectangle:)` reports per
    /// index, for a test imitating a host that answers by index; `nil` reports
    /// `caretRect` for every index.
    public var lineRectForIndex: ((Int) -> NSRect)?

    public func firstRect(forCharacterRange aRange: NSRange, actualRange: NSRangePointer!) -> NSRect {
        actualRange?.pointee = aRange
        return caretRect
    }

    /// Where the field says its caret is, for the Hanja window's placement: a
    /// plausible caret on the main screen, unless a test makes it misreport.
    public var caretRect = NSRect(x: 400, y: 400, width: 1, height: 18)

    public func validAttributesForMarkedText() -> [Any]! {
        attributeQueries += 1
        reenter(.validAttributes)
        return [NSAttributedString.Key.underlineStyle.rawValue,
         NSAttributedString.Key.underlineColor.rawValue,
         NSAttributedString.Key.markedClauseSegment.rawValue]
    }

    public func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {
        log(.overrideKeyboard(keyboardUniqueName ?? ""))
    }

    public func selectMode(_ modeIdentifier: String!) {}
    public func supportsUnicode() -> Bool { true }
    public func bundleIdentifier() -> String! {
        bundleQueries += 1
        return bundleID
    }
    public func windowLevel() -> CGWindowLevel { CGWindowLevelForKey(.normalWindow) }
    public func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    public func uniqueClientIdentifierString() -> String! { "\(bundleID).\(ObjectIdentifier(self).hashValue)" }

    // MARK: Host behavior

    /// What the host does with a key the input method did not handle, as
    /// `NSTextView` would: type its characters, delete, break the line, move.
    public func performHostAction(for event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if !flags.isEmpty {
            log(.host("shortcut"))
            return
        }
        switch Int(event.keyCode) {
        case 51: // Backspace
            deleteBackward()
        case 36, 76: // Return, keypad Enter
            insertByHost("\n")
        case 48: // Tab
            insertByHost("\t")
        case 53: // Escape
            log(.host("escape"))
        case 123:
            moveCaret(by: -1)
        case 124:
            moveCaret(by: 1)
        case 125, 126:
            log(.host("vertical"))
        default:
            guard let characters = event.characters, !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0xF700 }) else {
                log(.host("ignored"))
                return
            }
            insertByHost(characters)
        }
    }

    private func insertByHost(_ string: String) {
        let inserted = replace(clampedToDocument(marked ?? selection), with: string)
        marked = nil
        selection = NSRange(location: NSMaxRange(inserted), length: 0)
        log(.host("insert(\(string.replacingOccurrences(of: "\n", with: "\\n")))"))
    }

    private func deleteBackward() {
        var range = clampedToDocument(selection)
        if range.length == 0 {
            guard range.location > 0 else {
                log(.host("delete(nothing)"))
                return
            }
            range = storage.rangeOfComposedCharacterSequence(at: range.location - 1)
            // AppKit and Blink take a decomposed syllable apart one jamo at a time.
            let last = storage.character(at: range.location + range.length - 1)
            if range.length > 1, (0x1100...0x11FF).contains(last) {
                range = NSRange(location: NSMaxRange(range) - 1, length: 1)
            }
        }
        let removed = storage.substring(with: range)
        storage.deleteCharacters(in: range)
        marked = nil
        selection = NSRange(location: range.location, length: 0)
        log(.host("delete(\(removed))"))
    }

    private func moveCaret(by offset: Int) {
        let from = clampedToDocument(selection).location
        let location = max(0, min(storage.length, from + offset))
        selection = NSRange(location: location, length: 0)
        log(.host(offset < 0 ? "left" : "right"))
    }
}
