import Foundation
import Testing
@testable import PriTypeCore

/// The instrumentation sits on the hottest path in the project, so what matters
/// about it is that it changes nothing except how long it takes — and that it
/// carries none of what the user typed.
@Suite("Signposts")
struct SignpostsTests {

    @Test("A traced stage returns exactly what an untraced one returns")
    func tracingDoesNotChangeTheResult() {
        let id = Signposts.keystroke.makeSignpostID()
        var ranWhenOff = 0
        var ranWhenOn = 0

        let off = Signposts.interval(Signposts.keystroke, Signposts.Stage.compose,
                                     id: id, recording: false) { () -> String in
            ranWhenOff += 1
            return "가"
        }
        let on = Signposts.interval(Signposts.keystroke, Signposts.Stage.compose,
                                    id: id, recording: true) { () -> String in
            ranWhenOn += 1
            return "가"
        }

        #expect(off == on)
        #expect(ranWhenOff == 1, "the body runs once when nothing is recording")
        #expect(ranWhenOn == 1, "and once when something is")
    }

    @Test("Stage names describe the pipeline, never its contents")
    func namesCarryNoInput() {
        // Interval names are the only strings this emits, and `StaticString` is
        // what keeps that true: a name interpolated from a keystroke would not
        // compile. This is the compile-time guarantee written down, so that
        // changing the type to `String` for convenience has to argue with it.
        let names: [StaticString] = [
            Signposts.Stage.handle, Signposts.Stage.session, Signposts.Stage.pendingActions,
            Signposts.Stage.secureInputProbe, Signposts.Stage.prepareForInput,
            Signposts.Stage.compose, Signposts.HanjaStage.lookup,
            Signposts.HanjaStage.dictionarySearch, Signposts.HanjaStage.resolveCaret,
            Signposts.HanjaStage.accessibilityChain
        ]
        #expect(names.count == 10)
        for name in names {
            #expect(!name.description.isEmpty)
        }
    }

    @Test("Tracing is off unless it was asked for")
    func tracingIsOptIn() {
        // Measured: instrumenting every stage unconditionally cost about a
        // microsecond per key, two to three times the input method's own share of
        // an English key. Nobody pays that for a trace they are not taking.
        #expect(!UserDefaults.standard.bool(forKey: "com.pritype.signposts"),
                "this machine has tracing switched on, so the default cannot be checked here")
        #expect(!Signposts.isRecording)
    }
}
