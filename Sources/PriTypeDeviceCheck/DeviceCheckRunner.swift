import Foundation

/// A single question asked of the real system.
public protocol DeviceCheck: Sendable {
    /// Stable machine name. Also what `--only` matches.
    var id: String { get }
    /// What the check claims, in one line.
    var title: String { get }
    /// Whether a physical person has to press a key for this check to run.
    ///
    /// Interactive checks are the reason this tool exists — `IOHIDManager`
    /// reports hardware and nothing else — but they cannot run unattended, so
    /// they are off unless asked for.
    var requiresOperator: Bool { get }
    /// Whether running this changes system state the operator would have to put
    /// back: an enabled input source, a written preference, a granted permission.
    ///
    /// `PriTypeVerify` wrote the real `UserDefaults` domain while verifying it,
    /// which left the machine holding whatever the run had decided to try. The
    /// runner refuses to run a mutating check unless it is asked twice — once by
    /// selecting it, once with `--allow-mutation`.
    var mutatesSystemState: Bool { get }

    /// Run against the real system. Never traps and never asserts: an assertion
    /// disappears from a release build, and this tool's whole job is to report
    /// what a real machine did.
    func run() -> DeviceCheckFinding
}

public extension DeviceCheck {
    var requiresOperator: Bool { false }
    var mutatesSystemState: Bool { false }
}

/// What one check observed.
public struct DeviceCheckFinding: Sendable, Equatable {
    public let outcome: DeviceCheckOutcome
    public let evidence: String?

    public init(_ outcome: DeviceCheckOutcome, evidence: String? = nil) {
        self.outcome = outcome
        self.evidence = evidence
    }

    public static func passed(_ evidence: String) -> DeviceCheckFinding {
        DeviceCheckFinding(.passed, evidence: evidence)
    }
    public static func failed(_ reason: String, evidence: String? = nil) -> DeviceCheckFinding {
        DeviceCheckFinding(.failed(reason), evidence: evidence)
    }
    public static func skipped(_ reason: String, evidence: String? = nil) -> DeviceCheckFinding {
        DeviceCheckFinding(.skipped(reason), evidence: evidence)
    }
}

/// Which checks a run selects.
public struct DeviceCheckSelection: Sendable, Equatable {
    /// Include checks that need a person at the keyboard.
    public var includeInteractive: Bool
    /// Permit checks that change system state.
    public var allowMutation: Bool
    /// When non-empty, only these ids run.
    public var ids: Set<String>

    public init(includeInteractive: Bool = false, allowMutation: Bool = false, ids: Set<String> = []) {
        self.includeInteractive = includeInteractive
        self.allowMutation = allowMutation
        self.ids = ids
    }
}

public enum DeviceCheckRunner {
    /// Run the selected checks in order and collect what they observed.
    ///
    /// A check excluded by the selection is left out of the report entirely; a
    /// check that was selected but may not run — it mutates and mutation was not
    /// allowed — is reported as skipped, because the operator asked for it and
    /// has to be told it did not happen.
    public static func run(_ checks: [any DeviceCheck],
                           selection: DeviceCheckSelection = DeviceCheckSelection(),
                           log: (String) -> Void = { _ in }) -> DeviceCheckReport {
        var results: [DeviceCheckResult] = []
        for check in checks {
            if !selection.ids.isEmpty && !selection.ids.contains(check.id) { continue }
            if check.requiresOperator && !selection.includeInteractive && selection.ids.isEmpty { continue }

            if check.requiresOperator && !selection.includeInteractive {
                results.append(DeviceCheckResult(
                    id: check.id, title: check.title,
                    outcome: .skipped("needs a person at the keyboard; re-run with --interactive")))
                continue
            }
            if check.mutatesSystemState && !selection.allowMutation {
                results.append(DeviceCheckResult(
                    id: check.id, title: check.title,
                    outcome: .skipped("changes system state; re-run with --allow-mutation")))
                continue
            }

            log("running \(check.id)…")
            let finding = check.run()
            results.append(DeviceCheckResult(id: check.id, title: check.title,
                                             outcome: finding.outcome, evidence: finding.evidence))
        }
        return DeviceCheckReport(results: results)
    }

    /// Ids that do not name a check, so a typo in `--only` is an error rather
    /// than an empty, green run.
    public static func unknownIDs(in selection: DeviceCheckSelection,
                                  among checks: [any DeviceCheck]) -> Set<String> {
        selection.ids.subtracting(checks.map(\.id))
    }
}
