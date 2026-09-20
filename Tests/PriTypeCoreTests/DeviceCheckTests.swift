import Testing
import Foundation
@testable import PriTypeDeviceCheck

// The on-device checks themselves cannot run here — that is the whole point of
// them. What is tested here is the machinery that decides what a run means: the
// runner's selection rules, the exit status, and the argument parsing. Those are
// the parts that, wrong, turn a run that verified nothing into a green one.
//
// `PriTypeVerify` is the reason this file exists. It was removed because its own
// checks were never tested: two of them printed a warning and returned success
// either way, and nothing noticed for as long as it shipped.

/// A check that reports whatever it was built with, and records that it ran.
private struct StubCheck: DeviceCheck {
    let id: String
    let title: String
    var requiresOperator = false
    var mutatesSystemState = false
    let finding: DeviceCheckFinding
    let ran: Ran

    final class Ran: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func record() { lock.withLock { count += 1 } }
    }

    init(id: String, title: String = "stub", requiresOperator: Bool = false,
         mutatesSystemState: Bool = false, finding: DeviceCheckFinding = .passed("stub")) {
        self.id = id
        self.title = title
        self.requiresOperator = requiresOperator
        self.mutatesSystemState = mutatesSystemState
        self.finding = finding
        self.ran = Ran()
    }

    func run() -> DeviceCheckFinding {
        ran.record()
        return finding
    }
}

@Suite("Device check report")
struct DeviceCheckReportTests {

    @Test("A skipped check is not a passed one")
    func skipIsNotPass() {
        let report = DeviceCheckReport(results: [
            DeviceCheckResult(id: "a", title: "a", outcome: .passed),
            DeviceCheckResult(id: "b", title: "b", outcome: .skipped("no keyboard")),
        ])
        #expect(report.passed.count == 1)
        #expect(report.skipped.count == 1)
        #expect(report.exitStatus == .someSkipped)
    }

    @Test("A failure outranks a skip, and a skip outranks success")
    func statusPrecedence() {
        let pass = DeviceCheckResult(id: "a", title: "a", outcome: .passed)
        let skip = DeviceCheckResult(id: "b", title: "b", outcome: .skipped("unmet"))
        let fail = DeviceCheckResult(id: "c", title: "c", outcome: .failed("broken"))

        #expect(DeviceCheckReport(results: [pass]).exitStatus == .allPassed)
        #expect(DeviceCheckReport(results: [pass, skip]).exitStatus == .someSkipped)
        #expect(DeviceCheckReport(results: [pass, skip, fail]).exitStatus == .someFailed)
        #expect(DeviceCheckReport(results: [pass, fail]).exitStatus == .someFailed)
    }

    @Test("A run with no checks in it has proven nothing")
    func emptyRunIsNotSuccess() {
        // A selection that matched nothing must not read as a green run — that is
        // how a typo becomes a passing verification.
        #expect(DeviceCheckReport(results: []).exitStatus == .nothingRan)
        #expect(DeviceCheckReport(results: []).exitStatus.rawValue != 0)
    }

    @Test("The rendered report names the unmet precondition and the evidence")
    func renderCarriesReasons() {
        let report = DeviceCheckReport(results: [
            DeviceCheckResult(id: "hid-open", title: "opens keyboards",
                              outcome: .skipped("another process owns the keyboards"),
                              evidence: "IOReturn -536870203"),
        ])
        let rendered = report.render()
        #expect(rendered.contains("SKIP"))
        #expect(rendered.contains("another process owns the keyboards"))
        #expect(rendered.contains("IOReturn -536870203"))
        #expect(rendered.contains("verified nothing"))
    }

    @Test("A passing check still shows what was observed")
    func passCarriesEvidence() {
        let report = DeviceCheckReport(results: [
            DeviceCheckResult(id: "event-tap", title: "tap comes up",
                              outcome: .passed, evidence: "tap created and enabled"),
        ])
        #expect(report.render().contains("tap created and enabled"))
    }
}

@Suite("Device check runner")
struct DeviceCheckRunnerTests {

    @Test("An interactive check is left out of an unattended run")
    func interactiveExcludedByDefault() {
        let interactive = StubCheck(id: "physical", requiresOperator: true)
        let report = DeviceCheckRunner.run([interactive])
        #expect(report.results.isEmpty)
        #expect(interactive.ran.value == 0)
    }

    @Test("An interactive check named explicitly, without --interactive, is skipped rather than run")
    func interactiveNamedButNotEnabled() {
        // Naming a check is asking for it, so silence would be wrong; running it
        // would block on a key press nobody was told to make.
        let interactive = StubCheck(id: "physical", requiresOperator: true)
        let report = DeviceCheckRunner.run([interactive],
                                           selection: DeviceCheckSelection(ids: ["physical"]))
        #expect(interactive.ran.value == 0)
        #expect(report.results.count == 1)
        #expect(report.results[0].outcome.isSkipped)
        #expect(report.exitStatus == .someSkipped)
    }

    @Test("--interactive runs the checks that need a person")
    func interactiveRunsWhenAsked() {
        let interactive = StubCheck(id: "physical", requiresOperator: true)
        let report = DeviceCheckRunner.run(
            [interactive], selection: DeviceCheckSelection(includeInteractive: true))
        #expect(interactive.ran.value == 1)
        #expect(report.exitStatus == .allPassed)
    }

    @Test("A check that would change the machine does not run unless allowed")
    func mutationRequiresConsent() {
        let mutating = StubCheck(id: "rewrites-defaults", mutatesSystemState: true)
        let guarded = DeviceCheckRunner.run([mutating])
        #expect(mutating.ran.value == 0)
        #expect(guarded.results[0].outcome.isSkipped)

        let allowed = DeviceCheckRunner.run([mutating],
                                            selection: DeviceCheckSelection(allowMutation: true))
        #expect(mutating.ran.value == 1)
        #expect(allowed.exitStatus == .allPassed)
    }

    @Test("--only runs the named checks and nothing else")
    func onlyFiltersByID() {
        let wanted = StubCheck(id: "wanted")
        let other = StubCheck(id: "other")
        let report = DeviceCheckRunner.run([wanted, other],
                                           selection: DeviceCheckSelection(ids: ["wanted"]))
        #expect(wanted.ran.value == 1)
        #expect(other.ran.value == 0)
        #expect(report.results.map(\.id) == ["wanted"])
    }

    @Test("An id that names no check is reported rather than silently dropped")
    func unknownIDsAreVisible() {
        let checks: [any DeviceCheck] = [StubCheck(id: "event-tap")]
        let selection = DeviceCheckSelection(ids: ["event-tap", "evnet-tap"])
        #expect(DeviceCheckRunner.unknownIDs(in: selection, among: checks) == ["evnet-tap"])
    }

    @Test("Checks run in the order given, and each one's outcome is carried through")
    func outcomesAreCarried() {
        let report = DeviceCheckRunner.run([
            StubCheck(id: "one", finding: .passed("fine")),
            StubCheck(id: "two", finding: .failed("broke", evidence: "IOReturn -1")),
            StubCheck(id: "three", finding: .skipped("unmet")),
        ])
        #expect(report.results.map(\.id) == ["one", "two", "three"])
        #expect(report.results[1].outcome == .failed("broke"))
        #expect(report.results[1].evidence == "IOReturn -1")
        #expect(report.exitStatus == .someFailed)
    }
}

@Suite("Device check arguments")
struct DeviceCheckArgumentsTests {

    @Test("An empty command line runs the unattended checks only")
    func defaults() throws {
        let parsed = try DeviceCheckArguments.parse([])
        #expect(!parsed.selection.includeInteractive)
        #expect(!parsed.selection.allowMutation)
        #expect(parsed.selection.ids.isEmpty)
        #expect(parsed.timeout == nil)
    }

    @Test("--only splits on commas and ignores the spaces around them")
    func onlyParsing() throws {
        let parsed = try DeviceCheckArguments.parse(["--only", "hid-open, event-tap ,"])
        #expect(parsed.selection.ids == ["hid-open", "event-tap"])
    }

    @Test("Flags combine")
    func flagsCombine() throws {
        let parsed = try DeviceCheckArguments.parse(["--interactive", "--timeout", "30", "--list"])
        #expect(parsed.selection.includeInteractive)
        #expect(parsed.timeout == 30)
        #expect(parsed.wantsList)
    }

    @Test("An unrecognized argument is an error, not an ignored word")
    func unrecognized() {
        #expect(throws: DeviceCheckArguments.ParseError.unrecognized("--intercative")) {
            try DeviceCheckArguments.parse(["--intercative"])
        }
    }

    @Test("A flag with nothing after it is an error")
    func missingValue() {
        #expect(throws: DeviceCheckArguments.ParseError.missingValue("--timeout")) {
            try DeviceCheckArguments.parse(["--timeout"])
        }
        #expect(throws: DeviceCheckArguments.ParseError.missingValue("--only")) {
            try DeviceCheckArguments.parse(["--only"])
        }
    }

    @Test("A timeout that is not a positive number of seconds is an error")
    func unusableTimeout() {
        #expect(throws: DeviceCheckArguments.ParseError.unusableTimeout("soon")) {
            try DeviceCheckArguments.parse(["--timeout", "soon"])
        }
        // Zero would make every interactive check fail instantly and look like a
        // real finding.
        #expect(throws: DeviceCheckArguments.ParseError.unusableTimeout("0")) {
            try DeviceCheckArguments.parse(["--timeout", "0"])
        }
    }
}

@Suite("Shipped device checks")
struct ShippedDeviceCheckTests {

    @Test("Every shipped check has a unique id")
    func uniqueIDs() {
        let checks = unattendedChecks + interactiveChecks()
        let ids = checks.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("No shipped check changes the machine it is measuring")
    func nothingMutates() {
        // The runner's guard is only as good as this staying true: a check that
        // starts writing preferences has to say so, and then a run needs
        // --allow-mutation before it happens.
        let checks = unattendedChecks + interactiveChecks()
        #expect(checks.allSatisfy { !$0.mutatesSystemState })
    }

    @Test("The checks that need hardware are the ones marked interactive")
    func interactiveSetIsExplicit() {
        #expect(unattendedChecks.allSatisfy { !$0.requiresOperator })
        #expect(interactiveChecks().allSatisfy { $0.requiresOperator })
        #expect(Set(interactiveChecks().map(\.id)) == ["physical-toggle-tap", "physical-toggle-hid"])
    }
}
