import Foundation
import Testing
@testable import PriTypeCore

/// The Debug log has a size limit, and it has to hold for a process that runs for
/// days — which is every input method. The rotation this covers used to check the
/// size only while no file handle was cached, i.e. exactly once per process.
@Suite("Debug log rotation", .serialized)
struct DebugLoggerRotationTests {

    /// A temporary log directory, removed afterwards, so no test writes into the
    /// log the user is reading.
    /// - Parameter existingContents: what an earlier run left in the log. Written
    ///   BEFORE the logger is pointed at the file, because replacing a file the
    ///   logger already holds open leaves it writing into the replaced one — and
    ///   the logger is global, so any other suite logging in that window is enough
    ///   to open it.
    private func withTemporaryLog(limit: Int, existingContents: Data? = nil,
                                  _ body: (URL) throws -> Void) rethrows {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pritype-log-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("pritype_debug.log")
        if let existingContents {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? existingContents.write(to: url)
        }
        DebugLogger.testOverrides = DebugLogger.TestOverrides(path: url.path, rotationLimit: limit)
        defer {
            DebugLogger.flushPendingWrites()
            DebugLogger.testOverrides = DebugLogger.TestOverrides()
            DebugLogger.log("rotation test finished; back to the real log")
            DebugLogger.flushPendingWrites()
            try? FileManager.default.removeItem(at: directory)
        }
        try body(url)
    }

    private func size(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func contents(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test("A long-running process keeps rotating, not just the first time")
    func rotatesWhileRunning() {
        withTemporaryLog(limit: 2_000) { url in
            let rotated = url.deletingPathExtension().appendingPathExtension("log.1")
            // Each line is well over 100 bytes with its timestamp, so this crosses
            // the limit several times over without one write ever doing it alone.
            for index in 0..<200 {
                DebugLogger.log("line \(index) " + String(repeating: "x", count: 100))
            }
            DebugLogger.flushPendingWrites()

            #expect(FileManager.default.fileExists(atPath: rotated.path),
                    "the file that filled up was moved aside")
            // Roughly 26 KiB went in. The bound is loose rather than exact because
            // the logger is global: another suite running alongside this one logs
            // into the same redirected file. Loose still separates a log that
            // rotates from one that only grows.
            #expect(size(of: url) < 6_000, "the live log is back near the limit")
        }
    }

    @Test("A log left oversized by an earlier run rotates instead of growing on")
    func rotatesAFileInheritedFromAnEarlierRun() {
        withTemporaryLog(limit: 1_000, existingContents: Data(repeating: 0x41, count: 5_000)) { url in
            DebugLogger.log("the first line of a new run")
            DebugLogger.flushPendingWrites()

            let rotated = url.deletingPathExtension().appendingPathExtension("log.1")
            #expect(size(of: rotated) > 1_000, "the inherited file is the one moved aside")
            #expect(!contents(of: url).contains("AAAA"), "and the run continues in a new one")
        }
    }

    @Test("A log deleted under the process is written again, not lost")
    func recoversFromDeletion() {
        withTemporaryLog(limit: 1_000_000) { url in
            DebugLogger.log("before the delete")
            DebugLogger.flushPendingWrites()
            try? FileManager.default.removeItem(at: url)

            DebugLogger.log("after the delete")
            DebugLogger.flushPendingWrites()

            #expect(contents(of: url).contains("after the delete"))
            #expect(!contents(of: url).contains("before the delete"),
                    "that line went with the old file")
        }
    }
}
