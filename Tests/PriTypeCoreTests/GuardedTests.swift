import Testing
import Foundation
import os
import CoreGraphics
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
        // The re-acquisition has to be on ANOTHER thread. The lock is recursive,
        // so a leaked lock would let this same thread straight back in and the
        // test would pass while the defect it is named for was present.
        let acquired = DispatchSemaphore(value: 0)
        // Both annotations are load-bearing: `signal()` returns an `Int`, so
        // without them `withLock`'s generic result is inferred from a value this
        // closure exists to throw away. Swift 6.4 lets that pass and the 6.2
        // toolchain CI builds with does not.
        Thread {
            guarded.withLock { (_: Counter) -> Void in
                _ = acquired.signal()
            }
        }.start()
        #expect(acquired.wait(timeout: .now() + 2) == .success,
                "the lock was still held after the body threw")
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

    @Test("The six types converted off @unchecked still conform without it")
    func convertedTypesAreCheckedSendable() {
        // Deliberately not "every type the tap touches": `InputModeCoordinator`
        // and `HanjaCandidateWindow` are entered from the tap callback too and
        // are still `@unchecked`, which this could not detect anyway. What it
        // pins is that these six have not quietly gone back.
        requireSendable(RightCommandSuppressor.self)
        requireSendable(EventTapThread.self)
        requireSendable(IOKitManager.self)
        requireSendable(ToggleExclusionPolicy.self)
        requireSendable(ConfigurationManager.self)
        requireSendable(PolledPreference.self)
    }

    @Test("Every press reaches the callback once while other threads read the same state")
    func eventsCountedWhileStateIsRead() async throws {
        // The tap has exactly one producer — its own thread — and readers on
        // main: the settings window asking whether recording is on, the IOKit
        // fallback asking the same, a report reading the last provenance. That is
        // the shape here. Feeding events from several threads at once would not
        // be more rigorous, it would be meaningless: `toggleModifierIsDown` models
        // one physical key, so two concurrent presses are one down edge and the
        // count would be a property of the interleaving rather than of the lock.
        let tap = RightCommandSuppressor()
        let toggles = OSAllocatedUnfairLockCounter()
        tap.onToggle = { _ in toggles.increment() }

        let presses = 800
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<presses {
                    guard let press = CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: true),
                          let release = CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: false)
                    else { continue }
                    // Down edge then up edge: the suppressor toggles on the down
                    // edge only, so the pair is exactly one toggle.
                    press.flags = CGEventFlags(rawValue: 0x100010)
                    release.flags = CGEventFlags(rawValue: 0)
                    for event in [press, release] {
                        _ = tap.handleEvent(type: .flagsChanged, event: event,
                                            toggle: .defaultToggle, hanja: .defaultHanja,
                                            toggleEnabled: true, hanjaEnabled: false,
                                            trigger: .press, excludedOverride: false)
                    }
                }
            }
            for _ in 0..<3 {
                group.addTask {
                    for _ in 0..<2_000 {
                        _ = tap.isRunning
                        _ = tap.lastToggleProvenance
                        _ = tap.isRecordingKey
                    }
                }
            }
            group.addTask {
                // A writer too: the settings window entering and leaving
                // recording mode replaces the recording state under the readers.
                for _ in 0..<500 { tap.isRecordingKey = false }
            }
        }
        #expect(toggles.value == presses)
        #expect(tap.lastToggleProvenance != nil)
    }
}
