import Testing
import Foundation
@testable import PriTypeCore

@Suite("ABC layout status probe")
struct ABCLayoutStatusProbeTests {
    private static func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("abc-probe-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("Only the two exact answers are understood")
    func parsing() {
        #expect(ABCLayoutStatusProbe.parse("abc-layout: disabled\n") == true)
        #expect(ABCLayoutStatusProbe.parse("abc-layout: enabled") == false)
        #expect(ABCLayoutStatusProbe.parse("") == nil)
        #expect(ABCLayoutStatusProbe.parse("disabled") == nil)
        #expect(ABCLayoutStatusProbe.parse("abc-layout: disabled\nextra") == nil)
    }

    @Test("An ordinary launch is not treated as a probe")
    func ordinaryLaunchContinues() {
        // Would call exit(0) if it matched; returning is the assertion.
        ABCLayoutStatusProbe.runIfRequested(arguments: ["PriTypeV2"])
        ABCLayoutStatusProbe.runIfRequested(arguments: [ABCLayoutStatusProbe.argument])
    }

    @Test("A fresh process answering 'disabled' confirms removal")
    func freshProcessDisabled() throws {
        let exe = try Self.script("echo '\(ABCLayoutStatusProbe.disabledOutput)'")
        defer { try? FileManager.default.removeItem(at: exe) }
        #expect(ABCLayoutStatusProbe.isABCDisabledInFreshProcess(executable: exe))
    }

    @Test("A fresh process answering 'enabled' does not")
    func freshProcessEnabled() throws {
        let exe = try Self.script("echo '\(ABCLayoutStatusProbe.enabledOutput)'")
        defer { try? FileManager.default.removeItem(at: exe) }
        #expect(!ABCLayoutStatusProbe.isABCDisabledInFreshProcess(executable: exe))
    }

    @Test("Silence, garbage, a failing exit, and a missing executable cannot prove absence")
    func unusableAnswers() throws {
        for body in ["true", "echo hello", "echo '\(ABCLayoutStatusProbe.disabledOutput)'; exit 3"] {
            let exe = try Self.script(body)
            defer { try? FileManager.default.removeItem(at: exe) }
            #expect(!ABCLayoutStatusProbe.isABCDisabledInFreshProcess(executable: exe), Comment(rawValue: body))
        }
        #expect(!ABCLayoutStatusProbe.isABCDisabledInFreshProcess(executable: nil))
        #expect(!ABCLayoutStatusProbe.isABCDisabledInFreshProcess(
            executable: URL(fileURLWithPath: "/nonexistent/pritype-probe")))
    }

    @Test("A hung probe is killed and reported as unconfirmed")
    func hungProbe() throws {
        let exe = try Self.script("sleep 30; echo '\(ABCLayoutStatusProbe.disabledOutput)'")
        defer { try? FileManager.default.removeItem(at: exe) }
        let start = Date()
        #expect(!ABCLayoutStatusProbe.isABCDisabledInFreshProcess(executable: exe, timeout: 0.5))
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
