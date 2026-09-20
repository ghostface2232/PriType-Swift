import Foundation

/// Which application's preferences this process reads.
///
/// ## Why this is not just `UserDefaults.standard`
///
/// `UserDefaults.standard` means "whoever I am", and that is the right answer
/// inside the input method: the keys PriType owns live in the domain named by its
/// bundle identifier, which is the domain `.standard` resolves to there.
///
/// It is the wrong answer for a tool that verifies that install from outside it.
/// `pritype-device-check` is a command-line binary with no bundle identifier, so
/// its `.standard` is a different domain, empty of every key PriType has ever
/// written. A check reading it would have prompted for the *default* toggle key
/// while claiming to test the user's, and passed when they pressed the key it had
/// named rather than the key they actually use — a green run that verified
/// nothing, which is the one outcome that tool must never produce.
///
/// So the domain is a property of the process, set once at startup by a process
/// that is not the app, and left alone by the app itself.
public enum PreferencesDomain {
    /// The domain the installed input method writes to.
    public static let priTypeSuiteName = "com.pritype.inputmethod.v2"

    private final class Resolved {
        var suiteName: String?
        var cached: UserDefaults?
    }

    private static let resolved = Guarded(Resolved())

    /// Read another application's preferences for the rest of this process.
    ///
    /// - Important: Call before anything reads configuration. The app never calls
    ///   it, so inside PriType this whole type is `UserDefaults.standard` and
    ///   nothing about its behavior changes.
    /// - Returns: whether the domain could be opened. `false` leaves the previous
    ///   domain in place rather than silently reading the wrong one.
    @discardableResult
    public static func use(suiteName: String) -> Bool {
        guard let defaults = resolve(suiteName: suiteName) else { return false }
        resolved.withLock { resolved in
            resolved.suiteName = suiteName
            resolved.cached = defaults
        }
        return true
    }

    /// Open a domain without making it this process's.
    ///
    /// Separated from `use` so it can be tested: `use` writes state the whole
    /// process reads, and a test that redirected it would change what every
    /// other test running beside it sees `ConfigurationManager` say.
    ///
    /// - Returns: the domain, or nil for a name that does not address one.
    ///   `UserDefaults(suiteName:)` also refuses the global domain and this
    ///   process's own identifier, which are not separable stores.
    static func resolve(suiteName: String) -> UserDefaults? {
        let trimmed = suiteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed != Bundle.main.bundleIdentifier else { return nil }
        return UserDefaults(suiteName: trimmed)
    }

    /// The preferences this process reads and writes.
    public static var defaults: UserDefaults {
        resolved.withLock { $0.cached } ?? .standard
    }

    /// The domain's name, for a report that has to say which one it read.
    public static var currentSuiteName: String? {
        resolved.withLock { $0.suiteName }
    }

    /// Back to this process's own domain. For tests, which must not leave a
    /// redirection behind for whatever runs next.
    static func reset() {
        resolved.withLock { resolved in
            resolved.suiteName = nil
            resolved.cached = nil
        }
    }
}
