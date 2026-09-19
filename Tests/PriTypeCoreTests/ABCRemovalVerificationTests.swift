import Testing
import Foundation
@testable import PriTypeCore

@Suite("ABC removal live confirmation")
@MainActor
struct ABCRemovalVerificationTests {
    @Test("Retry cannot turn an unchanged live ABC source into success")
    func retryWithStaleTIS() async throws {
        var checks = 0
        var waits = 0
        // These are the two actual defaults outcomes across a first attempt and
        // its retry. TIS remains enabled for both attempts.
        for result: InputSourceManager.ABCRemovalResult in [.removed, .alreadyAbsent] {
            let confirmed = try await ABCRemovalVerification.confirm(
                result: result,
                isDisabled: { checks += 1; return false },
                wait: { waits += 1 }
            )
            #expect(!confirmed)
        }
        #expect(checks == 32)
        #expect(waits == 30)
    }

    @Test("Slow probes stop at the deadline instead of running all fifteen retries")
    func deadlineBoundsSlowProbes() async throws {
        var checks = 0
        let confirmed = try await ABCRemovalVerification.confirm(
            result: .removed,
            isDisabled: { checks += 1; return false },
            wait: {},
            deadline: .now
        )
        #expect(!confirmed)
        #expect(checks == 1)
    }

    @Test("A retry succeeds only after the live state catches up")
    func delayedRetrySuccess() async throws {
        var samples = [false, false, true]
        var waits = 0
        let confirmed = try await ABCRemovalVerification.confirm(
            result: .alreadyAbsent,
            isDisabled: { samples.removeFirst() },
            wait: { waits += 1 }
        )
        #expect(confirmed)
        #expect(waits == 2)
        #expect(samples.isEmpty)
    }

    @Test("Confirmed absence succeeds without unnecessary polling")
    func alreadyDisabled() async throws {
        for result: InputSourceManager.ABCRemovalResult in [.removed, .alreadyAbsent] {
            let confirmed = try await ABCRemovalVerification.confirm(
                result: result, isDisabled: { true },
                wait: { Issue.record("No wait is needed when TIS already confirms removal") }
            )
            #expect(confirmed)
        }
    }

    @Test("Failed writes cannot be hidden by a clean TIS snapshot")
    func failedWrite() async throws {
        let confirmed = try await ABCRemovalVerification.confirm(
            result: .failed(reason: "unreadable preferences"),
            isDisabled: { Issue.record("Failed writes should stop before querying TIS"); return true },
            wait: { Issue.record("Failed writes should not poll") }
        )
        #expect(!confirmed)
    }

    @Test("A cancelled attempt cannot publish a later successful result")
    func cancelledAttempt() async {
        let task = Task { @MainActor in
            try await ABCRemovalVerification.confirm(
                result: .alreadyAbsent,
                isDisabled: { Issue.record("Cancelled attempt must not query TIS"); return true },
                wait: {}
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Cancellation during polling prevents subsequent live-state checks")
    func cancelledWhileWaiting() async {
        var reads = 0
        do {
            _ = try await ABCRemovalVerification.confirm(
                result: .removed,
                isDisabled: { reads += 1; return false },
                wait: { throw CancellationError() }
            )
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(reads == 1)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Unavailable TIS queries and ABC variants are distinguished")
    func liveQueryEvidence() {
        #expect(!InputSourceManager.isABCDisabled(in: nil))
        #expect(!InputSourceManager.isABCDisabled(in: ["com.apple.keylayout.ABC"]))
        #expect(InputSourceManager.isABCDisabled(in: ["com.apple.keylayout.ABC-QWERTZ", "com.apple.inputmethod.SCIM.ITABC"]))
        #expect(InputSourceManager.isABCDisabled(in: []))
    }
}
