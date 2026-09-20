import Foundation

/// Mutable state that a lock protects, and that the compiler can see is protected.
///
/// ## What this is for
///
/// The keystroke path in this package spans threads that no actor owns. The
/// CGEventTap callback runs on `EventTapThread`, the IOHID value callback runs on
/// whichever run loop opened the manager, the settings window runs on main, and
/// all three reach the same objects. Swift 6 has one answer for that shape —
/// `@unchecked Sendable`, which is not an answer but a promise — and this package
/// made that promise twenty-two times, each one covering every field its type
/// had, including fields no lock was ever taken for.
///
/// This is the same promise made once, in one place small enough to read, and
/// made testable. A type that keeps its mutable state in a `Guarded` has no other
/// stored mutable state for the promise to cover, so it can conform to `Sendable`
/// for real and the compiler checks the rest.
///
/// ## Why it cannot simply be `OSAllocatedUnfairLock`
///
/// That is the checked primitive, and where it fits it is the better answer — the
/// device-check latch uses it. It requires its state to be `Sendable`, and the
/// state on this path is CoreFoundation objects: `CFMachPort`, `CFRunLoopSource`,
/// `CFRunLoop`, `IOHIDManager`. None of them conforms, and none of them can be
/// made to from here. Holding a non-`Sendable` value safely behind a lock is
/// exactly the thing the language cannot express, and exactly what this type is.
///
/// ## What it does not protect against
///
/// `withLock` hands the state to its body, and a body could store that reference
/// somewhere it outlives the lock. Nothing prevents that — it is the same hole
/// `NSLock.withLock` has. Keeping the state type private to its owner is what
/// closes it: a private class cannot be named, so it cannot be stored, outside
/// the file that declares it. Every user of this type does that.
///
/// ## Re-entrancy
///
/// The lock is recursive because the tap callback calls `stop()` on the object
/// whose lock it already holds, and because a state class rather than a mutable
/// struct is what makes that sound: a re-entrant `withLock` hands out the same
/// object instead of a second `inout` view of one value, which would be an
/// exclusivity violation. Nothing that holds this lock ever waits on the tap
/// thread, so re-entrancy cannot become deadlock.
final class Guarded<State: AnyObject>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let state: State

    init(_ state: State) {
        self.state = state
    }

    /// Run `body` with the state, holding the lock for its whole duration.
    ///
    /// - Important: `body` must not let the state escape, and must not block on
    ///   another thread that could be waiting for this lock.
    func withLock<R>(_ body: (State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(state)
    }
}
