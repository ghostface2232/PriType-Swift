import Foundation
import os

// MARK: - Signposts

/// Instruments intervals for the keystroke pipeline and the Hanja lookup.
///
/// ## Why intervals rather than more logging
///
/// The question these exist to answer is where a keystroke's time goes, and a
/// log line cannot answer it: the timings this project has are measured from
/// `handle()` entry to the fake client's reply, which leaves out every part that
/// is not this process — the event tap's wait, the host→IMK delivery, and the
/// synchronous IPC of the text APIs, which is the part most likely to be slow in
/// a real host. Signpost intervals are laid out on Instruments' own timeline and
/// can be read per host, which is what "typing feels slow in Chrome" needs.
/// https://developer.apple.com/documentation/os/ossignposter
/// https://developer.apple.com/documentation/xcode/improving-app-responsiveness
///
/// ## What is deliberately not here
///
/// No text, ever: not a character, not a preedit, not a candidate, not a length
/// that could identify one. What the user typed is exactly what the input method
/// must not leave lying around, and a channel that reports it in the name of
/// diagnostics is the same leak as a log line that does — with none of the
/// redaction `DebugLogger.logSensitive` applies. Counts, flags and durations only.
///
/// ## Cost, measured
///
/// Instrumenting the five stages of `handle()` unconditionally cost about a
/// microsecond per key — nothing beside a host's IPC, but it took an English key
/// from 0.6µs to 1.6µs and a Backspace from 0.3µs to 1.5µs, two to three times
/// the input method's whole share of that key. Asking `OSSignposter.isEnabled`
/// per stage did not get it back: that check is most of the cost.
///
/// So tracing is switched on deliberately, and read once:
///
///     defaults write com.pritype.inputmethod.v2 com.pritype.signposts -bool YES
///
/// A run without it pays one `Bool`. The Release binary is the same either way,
/// which is the part worth keeping: latency is measured on the build people use,
/// not on a debug build that behaves differently.
enum Signposts {
    private static let subsystem = "com.pritype.inputmethod"

    /// One interval per keystroke, with the stages of the pipeline nested inside.
    static let keystroke = OSSignposter(subsystem: subsystem, category: "Keystroke")

    /// The Hanja lookup: dictionary search and the caret-resolution chain, which
    /// is where the seconds-long waits live if they live anywhere.
    static let hanja = OSSignposter(subsystem: subsystem, category: "Hanja")

    /// Names of the stages a keystroke passes through. The strings are static
    /// because `OSSignposter` requires it, and the list is the pipeline in order:
    /// resolving the session (which may analyze the client), running key actions
    /// that arrived from a key monitor, the secure-input probe (a client IPC),
    /// verifying a direct-insertion preedit (one or two more), and composing,
    /// which is where the writes to the host happen.
    enum Stage {
        static let handle: StaticString = "handle"
        static let session: StaticString = "session"
        static let pendingActions: StaticString = "pendingActions"
        static let secureInputProbe: StaticString = "secureInputProbe"
        static let prepareForInput: StaticString = "prepareForInput"
        static let compose: StaticString = "compose"
    }

    /// Whether this run emits intervals at all. Read once — see **Cost, measured**.
    static let isRecording = PreferencesDomain.defaults.bool(forKey: "com.pritype.signposts")

    /// Time `body` as an interval when this run is recording.
    ///
    /// `recording` is passed in rather than read here so one keystroke asks once
    /// and its five stages share the answer.
    @inline(__always)
    static func interval<T>(_ signposter: OSSignposter, _ name: StaticString,
                            id: OSSignpostID, recording: Bool, _ body: () -> T) -> T {
        guard recording else { return body() }
        let state = signposter.beginInterval(name, id: id)
        defer { signposter.endInterval(name, state) }
        return body()
    }

    enum HanjaStage {
        static let lookup: StaticString = "lookup"
        static let dictionarySearch: StaticString = "dictionarySearch"
        static let resolveCaret: StaticString = "resolveCaret"
        static let accessibilityChain: StaticString = "accessibilityChain"
    }
}
