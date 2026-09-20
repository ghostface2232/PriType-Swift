import Foundation

// MARK: - DuplicateKeyProbe

/// Records what a host's key delivery looks like, so the duplicate rule can be
/// argued from a sample instead of from a belief.
///
/// `KeyEventDedup` drops a keyDown that carries the same `NSEvent.timestamp` as
/// the one before it, on the grounds that a host re-delivering a physical event
/// re-delivers the event — the same object, the same stamp — while two presses of
/// one key always carry two stamps. That is the right shape for the rule, and it
/// is still an assumption about one host's behaviour: KakaoTalk is the host the
/// double delivery was observed in, and nobody has yet looked at what its second
/// delivery preserves. If it restamps, nothing is deduped there and every
/// character doubles again.
///
/// This answers that, and only that. Switch it on, type in the host, read the log:
///
///     defaults write com.pritype.inputmethod.v2 com.pritype.dedupProbe -bool YES
///
/// ## What it records, and what it must never record
///
/// Per keyDown: whether the key identity matched the previous one, whether either
/// was an auto-repeat, the gap between the two stamps to the nanosecond, and what
/// the rule decided. Not the key code, not the characters, not the modifiers —
/// a key code is the letter under another name, and a conversation in a messaging
/// app is the last thing to leave behind in a log file. `sameKey` is a comparison,
/// not the thing compared, and the gap is what the question is about.
///
/// Reading it: `sameKey=yes` with `dt=0.000000000` is one event delivered twice,
/// which the rule catches. `sameKey=yes` with a small non-zero `dt` from a single
/// press is a host that restamps, and the rule does not catch it — that is the
/// finding worth having. Ordinary fast typing of the same letter also shows
/// `sameKey=yes` with a small `dt`, so the sample has to come from typing a key
/// ONCE and seeing two lines.
enum DuplicateKeyProbe {
    #if DEBUG
    /// Read once, like the signpost switch, so an ordinary run pays one `Bool`.
    static let isRecording = PreferencesDomain.defaults.bool(forKey: "com.pritype.dedupProbe")

    static func record(_ event: KeyDownSnapshot, previous: KeyDownSnapshot?,
                       duplicate: Bool, bundleId: String) {
        guard isRecording else { return }
        guard let previous else {
            DebugLogger.log("DuplicateKeyProbe: host=\(bundleId) first key of this session")
            return
        }
        let sameKey = event.keyCode == previous.keyCode
            && event.characters == previous.characters
            && event.modifiers == previous.modifiers
        DebugLogger.log(String(
            format: "DuplicateKeyProbe: host=%@ sameKey=%@ repeat=%@/%@ dt=%.9f dropped=%@",
            bundleId,
            sameKey ? "yes" : "no",
            previous.isARepeat ? "yes" : "no",
            event.isARepeat ? "yes" : "no",
            event.timestamp - previous.timestamp,
            duplicate ? "yes" : "no"))
    }
    #else
    @inlinable
    static func record(_ event: KeyDownSnapshot, previous: KeyDownSnapshot?,
                       duplicate: Bool, bundleId: String) {}
    #endif
}
