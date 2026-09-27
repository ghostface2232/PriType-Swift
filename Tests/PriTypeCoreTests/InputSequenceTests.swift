import Cocoa
import Testing
@testable import PriTypeCore
import PriTypeIMKHarness

/// Replays short sequences of everything that can happen to an input session —
/// keys, re-delivered keys, toggles, ⌘, focus changes, IMK's activation churn,
/// clicks, caret moves, a delivery policy flipped mid-word, Hanja candidates —
/// against hosts that lie in the ways real hosts lie, and checks the promises
/// that hold whatever the sequence was.
///
/// The 2026-09-20 review found five defects with six hand-written reproductions,
/// every one of them a state the individual tests never put the session in. This
/// is the same search done by machine: not "does 가 come out of rk", but "is there
/// an order of events that breaks something that must never break".
///
/// Seeded, so a failure names the sequence that produced it and repeats.
///
/// Two runs share the steps. The first plays all of them and checks promises
/// about keys and fields: a consumed key wrote something, a field without focus
/// was left alone, a second commit changed nothing. What that run catches,
/// measured by putting each fixed defect back: the duplicate-key window that
/// swallowed a fast second press (141 of 4,000 sequences), and the double-space
/// substitution that consumed a space it could not perform (22 of 4,000).
///
/// The second plays only the steps that leave every keystroke standing, and
/// checks the promise those two defects and most since were breaches of: every
/// keystroke lands once, in the field it was typed in. It has an oracle because
/// the engine loses no keystroke (`DubeolsikEngineTests`): a document read back
/// into keys (`Dubeolsik.keys(for:)`) is the keys typed into it, whatever
/// syllables they made. Where a syllable goes when IMK retires a controller, a
/// host drops edits mid-activation or the mode changes before the next key, the
/// keys still come out in that field and nowhere else. It cannot tell a wrong
/// edit at a moved caret from a right one, which needs what the document should
/// hold, so those defects keep targeted tests (`ReviewFixRegressionTests`).
@Suite("Input sequences", .serialized)
@MainActor
struct InputSequenceTests {

    @Test("Short sequences keep the input method's promises", arguments: 0..<4000)
    func sequencesKeepTheirPromises(seed: Int) {
        let run = SequenceRun(seed: seed)
        defer { run.finish() }
        for _ in 0..<22 {
            run.perform(run.choices.pick(Step.allCases))
        }
        run.expectFinalizeIsIdempotent()
    }

    @Test("Every keystroke lands once, in the field it was typed in", arguments: 0..<4000)
    func sequencesKeepEveryKeystroke(seed: Int) {
        let run = SequenceRun(seed: seed)
        defer { run.finish() }
        for _ in 0..<22 {
            run.perform(run.choices.pick(Step.keepingKeystrokes.filter { !run.typesSecondSpace($0) }))
            run.expectKeystrokesSoFar()
        }
        run.settle()
        run.expectEveryKeystroke()
    }
}

// MARK: - Steps

private enum Step: CaseIterable {
    case typeLetter, typeSpace, typeBackspace, typeReturn, typeArrow
    case redeliverLastKey
    case toggle, pressCommand
    case focusOther, focusBack
    case switchAppThroughRetiredController, churnInHostCall
    case timePasses
    case click
    case moveCaret, selectText, reportNoCaret
    case flipDeliveryPolicy
    case hanjaLookup, chooseCandidate
    case hostStartsLagging, hostStopsLagging
    case hostIgnoresRanges

    /// Steps after which every keystroke typed is still in the document, where
    /// it was typed, in the order it was typed. The rest edit what is there:
    /// they delete it, type over it, type into the middle of it, or replace it
    /// with Hanja — or, in a host that silently drops replacement ranges, put a
    /// rewrite at the caret, which only `ClientCompatibilityPolicy` can know of.
    var keepsKeystrokes: Bool {
        switch self {
        case .typeBackspace, .typeArrow, .moveCaret, .selectText,
             .hanjaLookup, .chooseCandidate, .hostIgnoresRanges:
            return false
        default:
            return true
        }
    }

    static let keepingKeystrokes = allCases.filter(\.keepsKeystrokes)
}

/// A keystroke as a document shows it: a letter typed in Korean mode is part of
/// a jamo, anything else is itself.
private enum Stroke: Equatable, CustomStringConvertible {
    case jamo(Character)
    case literal(Character)

    /// The keystrokes `text` reads back as.
    static func strokes(in text: String) -> [Stroke] {
        text.unicodeScalars.flatMap { scalar in
            Dubeolsik.keys(for: scalar).map { $0.map(Stroke.jamo) } ?? [.literal(Character(scalar))]
        }
    }

    var description: String {
        switch self {
        case .jamo(let key): return String(key)
        case .literal(" "): return "␣"
        case .literal("\n"): return "⏎"
        case .literal(let character): return "'\(character)'"
        }
    }
}

/// A reproducible source of choices. Not for statistical quality — for being
/// the same sequence again when a seed fails.
private struct Choices {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }

    mutating func next(_ upperBound: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(upperBound))
    }

    mutating func pick<T>(_ options: [T]) -> T { options[next(options.count)] }
    mutating func chance(_ oneIn: Int) -> Bool { next(oneIn) == 0 }
}

// MARK: - A run

/// Two fields in two apps, the steps played into them, and what was typed into
/// each: its ledger.
@MainActor
private final class SequenceRun {
    typealias Field = IMKHarness.Field

    var choices: Choices
    private let seed: Int
    private let harness = IMKHarness()
    private let fields: [Field]
    private var focusedIndex = 0
    private var focused: Field { fields[focusedIndex] }
    private var history: [String] = []
    private var trail: String { "seed \(seed), steps \(history.joined(separator: " → "))" }

    /// The keystrokes typed into each field, in order.
    private var ledgers: [[Stroke]]
    /// The mode the next key is typed in: toggles apply to the keys after them,
    /// even one still waiting for its hop from the key-monitor thread.
    private var mode = InputMode.korean
    /// The last key, while its moment lasts: a host re-delivers a key at once.
    private var lastKey: (event: NSEvent, field: Field)?
    /// Whether the focused field's host may still finish activating: it does
    /// that once, just after the click into it.
    private var hostIsActivating = true
    /// The field whose last key was a space, until another key or a focus
    /// change: a space into it now may be the second of a double space.
    private var spaceField: Int?

    private let config = ConfigurationManager.shared
    private let savedPolicy: Bool

    init(seed: Int) {
        self.seed = seed
        choices = Choices(seed: UInt64(seed) &+ 1)
        savedPolicy = config.experimentalDirectInsertion
        // The default delivery path, whatever this Mac has set: a seed must be
        // the same sequence on every machine.
        config.experimentalDirectInsertion = false
        PriTypeInputController.resetSystemModeTracking()
        fields = [harness.makeField(bundleID: "com.pritype.sequence.a"),
                  harness.makeField(bundleID: "com.pritype.sequence.b")]
        ledgers = fields.map { _ in [] }
        harness.focus(fields[0])
    }

    func finish() {
        harness.finish()
        config.experimentalDirectInsertion = savedPolicy
    }

    // MARK: Playing a step

    func perform(_ step: Step) {
        history.append("\(step)")
        let focusedBefore = focusedIndex
        let untouchedBefore = fields.map(\.client.text)
        let previousKey = lastKey
        lastKey = nil

        switch step {
        case .typeLetter:
            typeLetter()

        case .typeSpace:
            type(.space, noted: .literal(" "))

        case .typeReturn:
            type(.return, noted: .literal("\n"))

        case .typeBackspace:
            type(.backspace, noted: nil)

        case .typeArrow:
            type(choices.chance(2) ? .left : .right, noted: nil)

        case .redeliverLastKey:
            // The same physical event handed to the input method twice, as
            // KakaoTalk does it. The host acts on the key once, so a consumed
            // re-delivery is the one allowed to write nothing: it is the same
            // key, already answered.
            guard let previousKey else { return }
            lastKey = previousKey
            _ = previousKey.field.controller.handle(previousKey.event, client: previousKey.field.client)

        case .toggle:
            if choices.chance(2) { harness.toggle() } else { harness.toggleFromKeyMonitor() }
            mode = mode.toggled

        case .pressCommand:
            harness.pressCommand()

        case .focusOther:
            focus(1 - focusedIndex)

        case .focusBack:
            if focusedIndex != 0 { focus(0) }

        case .switchAppThroughRetiredController:
            switchAppThroughRetiredController()

        case .churnInHostCall:
            // A host whose reports lag is Chromium, whose churn is its own: an
            // anchor read from a stale report cannot tell the host catching up
            // from focus moving to another field (`InputSession.HostAnchor`).
            if hostIsActivating, !focused.client.freezeReports { churnInHostCall() }

        case .timePasses:
            // Long enough for everything waiting on a reactivation to give up.
            harness.wait(0.3)
            harness.runDeferredDeactivations()

        case .click:
            harness.click()

        case .moveCaret:
            // A click inside the text. With nothing marked, IMK says nothing.
            focused.client.placeCaret(at: choices.next(max(1, focused.client.text.utf16.count + 1)))

        case .selectText:
            // A real host's selection lies inside its own document; a host that
            // lies about the caret entirely is the `reportNoCaret` step.
            let count = focused.client.text.utf16.count
            let location = choices.next(max(1, count + 1))
            let length = choices.next(max(1, count - location + 1))
            focused.client.select(NSRange(location: location, length: length))

        case .reportNoCaret:
            // Google Docs, terminals, a secure field: no usable answer, ever.
            focused.client.select(NSRange(location: NSNotFound, length: 0))

        case .flipDeliveryPolicy:
            config.experimentalDirectInsertion.toggle()

        case .hanjaLookup:
            harness.pressHanjaKey()

        case .chooseCandidate:
            if harness.candidates.isVisible, !harness.candidates.entries.isEmpty {
                harness.candidates.choose(1)
            }

        case .hostStartsLagging:
            focused.client.freezeReports = true

        case .hostStopsLagging:
            focused.client.freezeReports = false

        case .hostIgnoresRanges:
            focused.client.ignoresReplacementRange.toggle()
        }

        // A field that had focus neither before the step nor after it is not
        // the input method's to edit. Every position-based edit the review
        // looked at — the double-space substitution, the direct-insertion
        // rewrite, a Hanja candidate — computes a range from something
        // remembered, and remembered things go stale.
        for index in fields.indices where index != focusedBefore && index != focusedIndex {
            #expect(fields[index].client.text == untouchedBefore[index],
                    "an unfocused field's document changed to '\(fields[index].client.text)' at: \(trail)")
        }
    }

    /// After an app switch IMK can hand the first key to a controller of the
    /// new app that it retires a few milliseconds later, whose client takes no
    /// edits: KakaoTalk hands it the key with no activation, TextEdit activates
    /// it briefly, and on the way IMK may pass back through the app just left.
    /// Whenever IMK tells the app left behind, the syllable begun in the new app
    /// continues in its field.
    private func switchAppThroughRetiredController() {
        // A person takes longer to switch apps than IMK's churn lasts.
        harness.wait(IMKHarness.clickTime)
        let left = focused
        focusedIndex = 1 - focusedIndex
        spaceField = nil
        let retired = harness.makeField(bundleID: focused.client.bundleID)
        retired.client.ignoresEdits = true

        let activatesBriefly = choices.chance(2)
        let bouncesBack = activatesBriefly && choices.chance(2)
        var leftDeactivated = false
        if activatesBriefly { harness.activateAhead(retired) }
        if bouncesBack || choices.chance(2) {
            left.controller.deactivateServer(left.client)
            leftDeactivated = true
        }
        typeLetter(via: retired)
        if bouncesBack {
            left.controller.activateServer(left.client)
            left.controller.deactivateServer(left.client)
        }
        if activatesBriefly { retired.controller.deactivateServer(retired.client) }
        harness.activateAhead(focused)
        if !leftDeactivated { left.controller.deactivateServer(left.client) }
        hostIsActivating = true
        // The wait for a session to take the syllable over ends after one did.
        if choices.chance(2) { harness.runDeferredDeactivations() }
        lastKey = nil
    }

    /// A host finishing its activation just after the click into it: IMK
    /// deactivates the field and activates it again inside a call the next key
    /// makes into it — TextEdit on macOS 27 inside the commit, Chromium and
    /// Electron inside the context analysis — and meanwhile the host drops every
    /// edit. The activation comes nested in that call, from IMK after it, or not
    /// at all: the host simply takes edits again, and its next key says so.
    private func churnInHostCall() {
        hostIsActivating = false
        let nested = choices.chance(2)
        harness.churnFocus(of: focused, during: choices.pick([.insertText, .setMarkedText, .validAttributes]),
                           nestedActivation: nested)
        typeLetter()
        // A key that made no such call: the churn passed without one.
        focused.client.cancelReentries()
        if focused.client.ignoresEdits {
            if choices.chance(2) { harness.completeActivation(focused) } else { focused.client.ignoresEdits = false }
        }
    }

    /// A person moves focus to `index`, clicking into it.
    private func focus(_ index: Int) {
        focusedIndex = index
        harness.focus(focused)
        hostIsActivating = true
        spaceField = nil
    }

    // MARK: Keys

    private func typeLetter(via retired: Field? = nil) {
        let letter = choices.pick(Array("rkstudgh"))
        deliver(harness.makeEvent(typing: letter),
                noted: mode == .korean ? .jamo(letter) : .literal(letter), via: retired)
    }

    private func type(_ key: IMKHarness.Key, noted stroke: Stroke?) {
        deliver(harness.makeEvent(for: key), noted: stroke)
    }

    /// One key into the focused field's controller, or into a controller IMK
    /// is about to retire. A key the input method passes on is the app's to
    /// handle, in the field that has focus in it.
    private func deliver(_ event: NSEvent, noted stroke: Stroke?, via retired: Field? = nil) {
        stroke.map { ledgers[focusedIndex].append($0) }
        spaceField = stroke == .literal(" ") ? focusedIndex : nil
        let target = retired ?? focused
        let candidatesWereOpen = harness.candidates.isVisible
        let callsBefore = target.client.calls.count
        let handled = target.controller.handle(event, client: target.client)
        if !handled { focused.client.performHostAction(for: event) }
        lastKey = (event, target)

        // A key the input method consumed must have produced something. A
        // consumed key the host never hears about is a keystroke the user has
        // lost — which is exactly what the double-space substitution did in
        // hosts that report no caret, and what the duplicate-key window did to
        // a fast second press. A key handed to an open candidate window belongs
        // to that window instead: moving the highlight, paging, closing it, or
        // asking for a candidate the input method then declines to insert
        // because the caret has moved off the word.
        if handled, !candidatesWereOpen {
            #expect(target.client.calls.count > callsBefore,
                    "a consumed key wrote nothing into the host at: \(trail)")
        }
    }

    /// Whether `step` types the second of two spaces into the focused field:
    /// with the double-space period on, that is an edit, not a keystroke. Only
    /// that: a space after a space typed into another field, or before a focus
    /// change, is a keystroke like any other.
    func typesSecondSpace(_ step: Step) -> Bool {
        step == .typeSpace && spaceField == focusedIndex
    }

    // MARK: Ending

    /// End what is still under way: commit the composition, let every wait for
    /// a reactivation run out, and commit a syllable still carried.
    func settle() {
        focused.client.freezeReports = false
        harness.click()
        harness.wait(0.3)
        harness.runDeferredDeactivations()
        PriTypeInputController.commitCarriedComposition()
    }

    // MARK: The promises

    /// What has reached each field's document is the start of what was typed
    /// into it: nothing doubled, nothing from the other field, no gap. What is
    /// missing is still on its way — the syllable being typed, marked text a
    /// host dropped mid-activation, a syllable carried across IMK's churn.
    func expectKeystrokesSoFar() {
        for (field, ledger) in zip(fields, ledgers) {
            let landed = Stroke.strokes(in: field.client.text)
            #expect(ledger.starts(with: landed),
                    "\(field.client.bundleID) holds \(landed), typed \(ledger), at: \(trail)")
        }
    }

    /// Once nothing is under way, each field holds exactly what was typed into it.
    func expectEveryKeystroke() {
        for (field, ledger) in zip(fields, ledgers) {
            let landed = Stroke.strokes(in: field.client.text)
            #expect(landed == ledger,
                    "\(field.client.bundleID) holds \(landed), typed \(ledger), after: \(trail)")
        }
    }

    /// Finalizing is idempotent. Every session-ending event calls it blindly,
    /// so a second call must not commit a second copy of anything — as when an
    /// app deactivation is followed by IMK's own deactivateServer, or two clicks
    /// come in a row.
    func expectFinalizeIsIdempotent() {
        focused.client.freezeReports = false
        harness.click()
        let afterFirst = focused.client.text
        harness.click()
        #expect(afterFirst == focused.client.text,
                "a repeated commit changed '\(afterFirst)' into '\(focused.client.text)' at: seed \(seed), final double commit")
    }
}
