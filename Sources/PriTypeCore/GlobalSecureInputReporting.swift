import Foundation

/// A text client that answers the global secure-input question itself.
///
/// `IsSecureEventInputEnabled()` is a fact about the machine, not about the
/// code: the lock screen turns it on, and a Mac being driven remotely locks
/// itself with nobody there to notice. While it is on, every keystroke costs one
/// extra synchronous `selectedRange()` — which is exactly what several
/// integration tests count. Seven of them failed for that reason alone.
///
/// The seam is on the client rather than on a mutable global on purpose. A
/// global would be written by whichever test suite ran last: swift-testing runs
/// suites in parallel, three of them build a harness, and a `finish()` in one
/// would put the machine's real answer back underneath another that was still
/// running. That is not a hypothetical — a process-wide preferences seam broke
/// six tests in exactly that way while this branch was being written. A client
/// carries its own answer, so two harnesses cannot disturb each other and
/// nothing has to be restored.
///
/// The app's real clients never conform, so they get macOS's answer.
public protocol GlobalSecureInputReporting {
    /// Whether a global secure-input warning should be treated as up for this
    /// client's keystrokes.
    var reportsGlobalSecureInput: Bool { get }
}
