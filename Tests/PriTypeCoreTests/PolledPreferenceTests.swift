import Foundation
import Testing
@testable import PriTypeCore

/// `PolledPreference` is read from inside the CGEventTap callback, where a
/// synchronous round trip to the preferences system is not merely slow: a callback
/// that overruns is disabled by the window server and its keystroke is lost.
@Suite("Polled preference")
struct PolledPreferenceTests {

    /// Counts reads and records which thread each one happened on.
    private final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        private var _onCallerThread = 0
        var value = false
        /// Held for the duration of each read, to stand in for a slow lookup.
        var delay: TimeInterval = 0

        func read(callerThread: mach_port_t) -> Bool {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return lock.withLock {
                _count += 1
                if Self.currentThread == callerThread { _onCallerThread += 1 }
                return value
            }
        }

        /// A thread identity that can cross into a `@Sendable` closure, which
        /// `Thread` itself cannot.
        static var currentThread: mach_port_t { pthread_mach_thread_np(pthread_self()) }

        var count: Int { lock.withLock { _count } }
        var onCallerThread: Int { lock.withLock { _onCallerThread } }
    }

    private func makePreference(_ source: Source, interval: TimeInterval = 0.05) -> PolledPreference {
        let caller = Source.currentThread
        return PolledPreference(interval: interval) { source.read(callerThread: caller) }
    }

    /// Wait for a condition the refresh queue satisfies, rather than for a duration.
    private func eventually(_ condition: () -> Bool) -> Bool {
        for _ in 0..<200 where !condition() {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    @Test("The first read has no cache to answer from, so it happens here")
    func firstReadIsSynchronous() {
        let source = Source()
        source.value = true
        let preference = makePreference(source)
        #expect(preference.value)
        #expect(source.count == 1)
        #expect(source.onCallerThread == 1, "there was nothing else it could do")
    }

    @Test("A stale value is answered at once and re-read somewhere else")
    func refreshLeavesTheCallersThread() {
        let source = Source()
        source.value = false
        let preference = makePreference(source)
        #expect(!preference.value)

        source.value = true
        source.delay = 0.05       // a lookup slow enough to matter in a tap callback
        Thread.sleep(forTimeInterval: 0.06)   // let the interval lapse

        // The read that finds the cache stale must not pay for the lookup.
        let start = Date()
        let answered = preference.value
        let elapsed = Date().timeIntervalSince(start)
        #expect(!answered, "still the cached value — the new one is not back yet")
        #expect(elapsed < 0.03, "the caller did not wait for the lookup (took \(elapsed)s)")

        #expect(eventually { preference.value }, "and the new value lands on its own")
        #expect(source.onCallerThread == 1, "only the very first read was on this thread")
    }

    @Test("Several stale reads start one refresh between them")
    func concurrentReadsStartOneRefresh() {
        let source = Source()
        let preference = makePreference(source)
        _ = preference.value
        source.delay = 0.05
        Thread.sleep(forTimeInterval: 0.06)

        for _ in 0..<50 { _ = preference.value }
        #expect(eventually { source.count == 2 })
        #expect(source.count == 2, "one first read, one refresh")
    }

    @Test("A value this process just wrote is read again at once, not eventually")
    func invalidateIsSynchronous() {
        let source = Source()
        source.value = false
        let preference = makePreference(source, interval: 3600)
        #expect(!preference.value)

        source.value = true
        preference.invalidate()
        #expect(preference.value, "the setting the user just changed applies to the next key")
    }

    @Test("A refresh in flight cannot undo a value written after it started")
    func invalidateBeatsAnInFlightRefresh() {
        let source = Source()
        source.value = false
        let preference = makePreference(source)
        #expect(!preference.value)

        // Start a refresh that will report the OLD value, slowly.
        source.delay = 0.1
        Thread.sleep(forTimeInterval: 0.06)
        _ = preference.value

        // Meanwhile this process writes the preference and invalidates.
        source.value = true
        source.delay = 0
        preference.invalidate()
        #expect(preference.value)

        // The slow refresh lands now, carrying the value from before the write.
        Thread.sleep(forTimeInterval: 0.15)
        #expect(preference.value, "the stale answer was dropped, not cached over the new one")
    }
}
