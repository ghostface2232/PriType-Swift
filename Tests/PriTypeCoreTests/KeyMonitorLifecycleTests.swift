import Testing
@testable import PriTypeCore

@Suite("Event tap failure handoff")
struct EventTapFailureTrackerTests {
    @Test("Third disable hands off exactly once and never re-enables the tap")
    func oneShotHandoff() {
        var tracker = EventTapFailureTracker(maxRetries: 3, stableResetInterval: 60)

        #expect(tracker.recordDisable(at: 1) == .reenable(attempt: 1))
        #expect(tracker.recordDisable(at: 2) == .reenable(attempt: 2))
        #expect(tracker.recordDisable(at: 3) == .handoffToIOKit)
        #expect(tracker.recordDisable(at: 4) == .ignore)
        #expect(tracker.hasHandedOff)
    }

    @Test("A stable interval resets transient failure count")
    func stableIntervalReset() {
        var tracker = EventTapFailureTracker(maxRetries: 3, stableResetInterval: 60)

        #expect(tracker.recordDisable(at: 1) == .reenable(attempt: 1))
        #expect(tracker.recordDisable(at: 2) == .reenable(attempt: 2))
        #expect(tracker.recordDisable(at: 63) == .reenable(attempt: 1))
        #expect(!tracker.hasHandedOff)
    }

    @Test("A new CGEventTap lifecycle can recover independently")
    func lifecycleReset() {
        var tracker = EventTapFailureTracker(maxRetries: 1)
        #expect(tracker.recordDisable(at: 1) == .handoffToIOKit)

        tracker.reset()

        #expect(tracker.recordDisable(at: 2) == .handoffToIOKit)
    }
}
