import Testing
import Foundation
import os
@testable import PriTypeCore

// `Guarded` is the one place in this package where concurrency checking is
// switched off, so it is the one place that has to earn it. Every type on the
// keystroke path now conforms to `Sendable` on the strength of this file.

@Suite("Guarded state")
struct GuardedTests {

    private final class Counter {
        var value = 0
        var seenInsideLock: [Int] = []
    }

    @Test("Concurrent writers cannot interleave inside the lock")
    func mutualExclusion() async {
        let guarded = Guarded(Counter())
        let writers = 8
        let incrementsEach = 2_000

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<writers {
                group.addTask {
                    for _ in 0..<incrementsEach {
                        // A read-modify-write is the operation a lock exists for:
                        // without one this lands well short of the total.
                        guarded.withLock { $0.value += 1 }
                    }
                }
            }
        }
        #expect(guarded.withLock { $0.value } == writers * incrementsEach)
    }

    @Test("A body sees the state no other body is part-way through changing")
    func noTornReads() async {
        // Two fields kept in step: the second is only ever the negation of the
        // first. A reader that got between the two writes would see them disagree.
        final class Pair {
            var forward = 0
            var backward = 0
        }
        let guarded = Guarded(Pair())
        let disagreements = OSAllocatedUnfairLockCounter()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 1...5_000 {
                    guarded.withLock { pair in
                        pair.forward = index
                        pair.backward = -index
                    }
                }
            }
            group.addTask {
                for _ in 1...5_000 {
                    guarded.withLock { pair in
                        if pair.forward != -pair.backward { disagreements.increment() }
                    }
                }
            }
        }
        #expect(disagreements.value == 0)
    }

    @Test("A body may take the lock again without deadlocking")
    func reentrancy() {
        // This is not a nicety: the tap callback holds the lock for a whole event
        // and calls `stop()`, which takes it again. A non-recursive lock here
        // would hang the machine's entire keyboard rather than fail a test.
        let guarded = Guarded(Counter())
        guarded.withLock { outer in
            outer.value = 1
            guarded.withLock { inner in
                inner.value += 1
                // The same object, not a copy: this is why the state is a class.
                #expect(inner === outer)
            }
            #expect(outer.value == 2)
        }
        #expect(guarded.withLock { $0.value } == 2)
    }

    @Test("A value returned from the body comes back out")
    func returnsValues() {
        let guarded = Guarded(Counter())
        guarded.withLock { $0.value = 42 }
        #expect(guarded.withLock { $0.value } == 42)
    }

    @Test("A throwing body releases the lock on its way out")
    func rethrowsWithoutHoldingTheLock() {
        struct Boom: Error {}
        let guarded = Guarded(Counter())
        #expect(throws: Boom.self) {
            try guarded.withLock { _ -> Void in throw Boom() }
        }
        // Would hang rather than fail if the lock had been left held.
        #expect(guarded.withLock { $0.value } == 0)
    }
}

/// A counter that needs no escape hatch of its own, so this file's assertions do
/// not rest on the thing they are testing.
private final class OSAllocatedUnfairLockCounter: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: 0)
    var value: Int { storage.withLock { $0 } }
    func increment() { storage.withLock { $0 += 1 } }
}

@Suite("Keystroke path concurrency")
struct KeystrokePathSendabilityTests {

    /// Accepts only a type the compiler has checked, so `@unchecked` would not
    /// satisfy it... but neither would it fail. What this pins down is that these
    /// types conform at all: if one of them goes back to carrying unprotected
    /// mutable state, it stops compiling here rather than at some call site a
    /// contributor is free to work around with a capture list.
    private func requireSendable<T: Sendable>(_ type: T.Type) {}

    @Test("Every type the tap and HID callbacks touch is Sendable")
    func tapBoundaryIsSendable() {
        requireSendable(RightCommandSuppressor.self)
        requireSendable(EventTapThread.self)
        requireSendable(IOKitManager.self)
        requireSendable(ToggleExclusionPolicy.self)
        requireSendable(ConfigurationManager.self)
        requireSendable(PolledPreference.self)
    }

    @Test("The suppressor's callbacks survive being read from another thread")
    func callbacksAreReadableConcurrently() async {
        let tap = RightCommandSuppressor()
        let calls = OSAllocatedUnfairLockCounter()
        tap.onToggle = { _ in calls.increment() }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<500 {
                        _ = tap.isRunning
                        _ = tap.lastToggleProvenance
                        _ = tap.isRecordingKey
                    }
                }
            }
            group.addTask {
                for _ in 0..<500 { tap.isRecordingKey = false }
            }
        }
        #expect(calls.value == 0)
    }
}
