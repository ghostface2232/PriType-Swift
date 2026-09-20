import Foundation

/// The vocabulary of the on-device verification run.
///
/// ## Why this exists
///
/// The in-process suite drives `PriTypeInputController` against a fake text
/// client, which is what makes it fast and deterministic — and is exactly why it
/// cannot answer the questions that matter most on a real Mac. `IOHIDManager`
/// reports only hardware, so no synthetic event reaches the fallback path at all;
/// HIToolbox caches the enabled-input-source list per process, so a running input
/// method cannot observe its own effect on it; and a `CGEventTap` that the system
/// refuses to create fails at a layer no fake can stand in for.
///
/// These checks run against the real system and report what they actually
/// observed. They do not duplicate the suite: a question the suite can answer
/// belongs in the suite, where it runs on every push.
///
/// ## The rule this file exists to enforce
///
/// A check that could not run is not a check that passed. `PriTypeVerify`, the
/// runner this replaces, had checks that printed `WARNING` and returned success
/// either way, and its assertions compiled out of a release build entirely. So
/// there is no warning outcome here: a check passes, fails, or is skipped with
/// the precondition it found unmet, and a skip is visible in the exit status.
public enum DeviceCheckOutcome: Sendable, Equatable {
    /// The check ran against the real system and the system behaved.
    case passed
    /// The check ran and the system did not behave. Carries what was observed.
    case failed(String)
    /// The check could not run. Carries the precondition that was unmet, in the
    /// operator's terms — "PriTypeV2 is running", not "kIOReturnExclusiveAccess".
    case skipped(String)

    public var isPassed: Bool { if case .passed = self { return true }; return false }
    public var isFailed: Bool { if case .failed = self { return true }; return false }
    public var isSkipped: Bool { if case .skipped = self { return true }; return false }
}

/// One check's identity and what became of it.
public struct DeviceCheckResult: Sendable, Equatable {
    /// Stable machine name, for scripting and for naming a check in a report.
    public let id: String
    /// What the check claims about the system, in one line.
    public let title: String
    public let outcome: DeviceCheckOutcome
    /// What was observed, whatever the outcome. Present on a pass too: "the tap
    /// was created and enabled" is the evidence that the pass means something.
    public let evidence: String?

    public init(id: String, title: String, outcome: DeviceCheckOutcome, evidence: String? = nil) {
        self.id = id
        self.title = title
        self.outcome = outcome
        self.evidence = evidence
    }
}

/// The process exit status.
///
/// A skip gets its own status rather than sharing success: a CI job or an
/// operator that treats "2" as "fine" is making that choice explicitly, where
/// "0" would have hidden it.
public enum DeviceCheckExitStatus: Int32, Sendable, Equatable {
    /// Every check that was selected ran, and every one of them passed.
    case allPassed = 0
    /// At least one check ran and failed. Outranks every other status.
    case someFailed = 1
    /// Nothing failed, but at least one check could not run.
    case someSkipped = 2
    /// No check ran at all — an empty selection, which is not a pass.
    case nothingRan = 3
}

/// What a whole run observed.
public struct DeviceCheckReport: Sendable, Equatable {
    public let results: [DeviceCheckResult]

    public init(results: [DeviceCheckResult]) {
        self.results = results
    }

    public var passed: [DeviceCheckResult] { results.filter { $0.outcome.isPassed } }
    public var failed: [DeviceCheckResult] { results.filter { $0.outcome.isFailed } }
    public var skipped: [DeviceCheckResult] { results.filter { $0.outcome.isSkipped } }

    /// Failure outranks a skip, and a skip outranks success. An empty run is its
    /// own status: a selection that matched no check has proven nothing, and
    /// returning 0 for it is how a typo in a filter becomes a green run.
    public var exitStatus: DeviceCheckExitStatus {
        if results.isEmpty { return .nothingRan }
        if !failed.isEmpty { return .someFailed }
        if !skipped.isEmpty { return .someSkipped }
        return .allPassed
    }

    /// The report an operator reads. Evidence is printed for every outcome,
    /// including a pass, so the line says what was observed and not merely that
    /// something was.
    public func render() -> String {
        var lines: [String] = []
        for result in results {
            let mark: String
            let note: String
            switch result.outcome {
            case .passed:
                mark = "PASS"
                note = ""
            case .failed(let reason):
                mark = "FAIL"
                note = reason
            case .skipped(let reason):
                mark = "SKIP"
                note = "precondition unmet — \(reason)"
            }
            lines.append("\(mark)  \(result.id)  \(result.title)")
            if !note.isEmpty { lines.append("      \(note)") }
            if let evidence = result.evidence { lines.append("      observed: \(evidence)") }
        }
        lines.append("")
        lines.append("\(passed.count) passed, \(failed.count) failed, \(skipped.count) skipped"
            + "  (exit \(exitStatus.rawValue))")
        if !skipped.isEmpty {
            lines.append("A skipped check has verified nothing. Meet its precondition and run it again.")
        }
        return lines.joined(separator: "\n")
    }
}
