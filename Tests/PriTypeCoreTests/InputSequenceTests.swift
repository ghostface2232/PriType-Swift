import Cocoa
import Testing
@testable import PriTypeCore
import PriTypeIMKHarness

/// Replays short sequences of everything that can happen to an input session —
/// keys, re-delivered keys, toggles, focus changes, clicks, caret moves, a delivery
/// policy flipped mid-word, Hanja candidates — against hosts that lie in the ways
/// real hosts lie, and checks the promises that hold whatever the sequence was.
///
/// The 2026-09-20 review found five defects with six hand-written reproductions,
/// every one of them a state the individual tests never put the session in. This
/// is the same search done by machine: not "does 가 come out of rk", but "is there
/// an order of events that breaks something that must never break".
///
/// Seeded, so a failure names the sequence that produced it and repeats.
///
/// What this catches, measured by putting each fixed defect back and running the
/// sequences against it: the duplicate-key window that swallowed a fast second
/// press (141 of 4,000 sequences), and the double-space substitution that
/// consumed a space it could not perform (22 of 4,000). Both are the same class —
/// a key the input method took and never answered — and it is the class these
/// promises are about.
///
/// What it does not catch, and this is worth stating rather than discovering
/// later: a defect that edits the FOCUSED field wrongly. The double-space
/// substitution eating the character before a moved caret, and the adapter swap
/// re-inserting a syllable already in the document, both pass every promise here,
/// because telling a wrong edit from a right one needs an oracle for what the
/// document should hold, and a random sequence has none. Those two have targeted
/// tests in `ReviewFixRegressionTests`; that division is deliberate, not a gap
/// waiting to be closed by more sequences.
@Suite("Input sequences", .serialized)
@MainActor
struct InputSequenceTests {

    // MARK: The promises

    /// Everything a sequence must not do, checked after every single step.
    private struct Invariants {
        /// A field that does not have focus is not this input method's to edit.
        /// Every position-based edit the review looked at — the double-space
        /// substitution, the direct-insertion rewrite, a Hanja candidate — computes
        /// a range from something remembered, and remembered things go stale.
        static func otherFieldIsUntouched(_ recorded: String, _ actual: String, _ step: String) {
            #expect(recorded == actual,
                    "an unfocused field's document changed to '\(actual)' at: \(step)")
        }

        /// A key the input method consumed must have produced something. A consumed
        /// key the host never hears about is a keystroke the user has lost — which
        /// is exactly what the double-space substitution did in hosts that report
        /// no caret, and what the duplicate-key window did to a fast second press.
        ///
        /// Two keys are allowed to consume and write nothing, because what they
        /// produced was not a document edit. A key handed to an open candidate
        /// window belongs to that window — moving the highlight, paging, closing
        /// it, or asking for a candidate the input method then declines to insert
        /// because the caret has moved off the word. And a key re-delivered by the
        /// host is the same key answered a second time.
        static func consumedKeyWroteSomething(_ handled: Bool, _ callsBefore: Int,
                                              _ callsAfter: Int, _ step: String) {
            guard handled else { return }
            #expect(callsAfter > callsBefore,
                    "a consumed key wrote nothing into the host at: \(step)")
        }

        /// Finalizing is idempotent. Every session-ending event calls it blindly,
        /// so a second call must not commit a second copy of anything.
        static func finalizeIsIdempotent(_ afterFirst: String, _ afterSecond: String, _ step: String) {
            #expect(afterFirst == afterSecond,
                    "a repeated commit changed '\(afterFirst)' into '\(afterSecond)' at: \(step)")
        }
    }

    // MARK: The sequence

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

    private enum Step: CaseIterable {
        case typeLetter, typeSpace, typeBackspace, typeReturn, typeArrow
        case redeliverLastKey
        case toggle
        case focusOther, focusBack
        case click
        case moveCaret, selectText, reportNoCaret
        case flipDeliveryPolicy
        case hanjaLookup, chooseCandidate
        case hostStartsLagging, hostStopsLagging
        case hostIgnoresRanges
    }

    // MARK: The run

    @Test("Short sequences keep the input method's promises", arguments: 0..<4000)
    func sequencesKeepTheirPromises(seed: Int) {
        let config = ConfigurationManager.shared
        let savedPolicy = config.experimentalDirectInsertion
        defer { config.experimentalDirectInsertion = savedPolicy }

        PriTypeInputController.resetSystemModeTracking()
        let harness = IMKHarness()
        defer { harness.finish() }
        let fields = [harness.makeField(bundleID: "com.pritype.sequence.a"),
                      harness.makeField(bundleID: "com.pritype.sequence.b")]
        harness.focus(fields[0])
        var focusedIndex = 0

        var choices = Choices(seed: UInt64(seed) &+ 1)
        var lastEvent: NSEvent?
        var history: [String] = []
        // Set by any step that delivers a key; nil for steps that do not.
        var consumedKey: Bool?

        for _ in 0..<22 {
            let step = choices.pick(Step.allCases)
            history.append("\(step)")
            let trail = "seed \(seed), steps \(history.joined(separator: " → "))"

            let focused = fields[focusedIndex]
            let other = fields[1 - focusedIndex]
            let otherTextBefore = other.client.text
            let callsBefore = focused.client.calls.count
            let candidatesWereOpen = harness.candidates.isVisible
            consumedKey = nil

            switch step {
            case .typeLetter:
                let characters = String(choices.pick(Array("rkstudgh")))
                let event = harness.makeEvent(keyCode: Self.keyCode(for: characters),
                                              characters: characters)
                lastEvent = event
                consumedKey = deliver(event, to: focused)

            case .typeSpace, .typeBackspace, .typeReturn, .typeArrow:
                let key: IMKHarness.Key = {
                    switch step {
                    case .typeSpace: return .space
                    case .typeBackspace: return .backspace
                    case .typeReturn: return .return
                    default: return choices.chance(2) ? .left : .right
                    }
                }()
                let event = harness.makeEvent(keyCode: Self.keyCode(for: key),
                                              characters: Self.characters(for: key))
                lastEvent = event
                consumedKey = deliver(event, to: focused)

            case .redeliverLastKey:
                // The same physical event handed over twice, as KakaoTalk does it.
                guard let event = lastEvent else { continue }
                // A re-delivery is the one consumed key allowed to write nothing:
                // it is the same key, already answered.
                deliver(event, to: focused)

            case .toggle:
                if choices.chance(2) { harness.toggle() } else { harness.toggleFromKeyMonitor() }

            case .focusOther:
                focusedIndex = 1 - focusedIndex
                harness.focus(fields[focusedIndex])

            case .focusBack:
                if focusedIndex != 0 {
                    focusedIndex = 0
                    harness.focus(fields[0])
                }

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

            if let consumedKey, !candidatesWereOpen {
                Invariants.consumedKeyWroteSomething(consumedKey, callsBefore,
                                                     focused.client.calls.count, trail)
            }
            Invariants.otherFieldIsUntouched(otherTextBefore, other.client.text, trail)
        }

        // A session-ending event arrives twice, as they do: an app deactivation
        // followed by IMK's own deactivateServer, or two clicks in a row.
        let focused = fields[focusedIndex]
        focused.client.freezeReports = false
        harness.click()
        let afterFirstCommit = focused.client.text
        harness.click()
        Invariants.finalizeIsIdempotent(afterFirstCommit, focused.client.text,
                                        "seed \(seed), final double commit")
    }

    // MARK: Driving a key

    @discardableResult
    private func deliver(_ event: NSEvent, to field: IMKHarness.Field) -> Bool {
        let handled = field.controller.handle(event, client: field.client)
        if !handled { field.client.performHostAction(for: event) }
        return handled
    }

    private static func keyCode(for characters: String) -> UInt16 {
        let letters: [Character: UInt16] = ["r": 15, "k": 40, "s": 1, "t": 17,
                                            "u": 32, "d": 2, "g": 5, "h": 4]
        return letters[characters.first ?? "r"] ?? 15
    }

    private static func keyCode(for key: IMKHarness.Key) -> UInt16 {
        switch key {
        case .space: return 49
        case .backspace: return 51
        case .return: return 36
        case .left: return 123
        case .right: return 124
        default: return 49
        }
    }

    private static func characters(for key: IMKHarness.Key) -> String {
        switch key {
        case .space: return " "
        case .backspace: return "\u{7F}"
        case .return: return "\r"
        case .left: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case .right: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        default: return " "
        }
    }
}
