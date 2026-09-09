import Foundation
import Testing
@testable import PriTypeCore

@Suite("Exclusive key recording ownership")
@MainActor
struct KeyRecordingSessionsTests {
    @Test("Starting Hanja recording cancels the pending toggle recording")
    func replacementCancelsPrevious() {
        let sessions = KeyRecordingSessions()
        let toggle = UUID(), hanja = UUID()
        var toggleRecording = true
        sessions.begin(owner: toggle) { toggleRecording = false }
        sessions.begin(owner: hanja) {}
        #expect(!toggleRecording)
        #expect(!sessions.owns(toggle))
        #expect(sessions.owns(hanja))
        #expect(!sessions.end(owner: toggle))
        #expect(sessions.owns(hanja))
        #expect(sessions.end(owner: hanja))
    }

    @Test("Queued old results cannot overwrite either the new or restarted row")
    func staleResults() {
        let sessions = KeyRecordingSessions()
        let first = UUID(), second = UUID(), restarted = UUID()
        var received: [Int] = []
        sessions.begin(owner: first) {}
        let queuedFirst = { if sessions.owns(first) { received.append(105) } }
        sessions.begin(owner: second) {}
        queuedFirst()
        if sessions.owns(second) { received.append(106) }
        sessions.end(owner: second)
        sessions.begin(owner: restarted) {}
        queuedFirst()
        #expect(received == [106])
        #expect(!sessions.end(owner: first))
        #expect(sessions.owns(restarted))
    }

    @Test("Cancellation may end its old owner without clearing the replacement")
    func reentrantCancellation() {
        let sessions = KeyRecordingSessions()
        let old = UUID(), new = UUID()
        var cancellations = 0
        sessions.begin(owner: old) {
            cancellations += 1
            sessions.end(owner: old)
        }
        sessions.begin(owner: new) {}
        #expect(cancellations == 1)
        #expect(sessions.owns(new))
    }
}
