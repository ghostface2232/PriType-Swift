import Foundation
import PriTypeCore
import PriTypeDeviceCheck

// Answering the fresh-process probe has to come before anything else: the probe
// re-launches this executable to read an input-source list that its parent's
// HIToolbox has cached and will never refresh, and the child has to answer and
// exit before it does any work of its own.
ABCLayoutStatusProbe.runIfRequested()

// Read the installed input method's preferences, not this binary's. A
// command-line tool has no bundle identifier, so its own `UserDefaults.standard`
// is a domain PriType has never written a key to: left alone, every check that
// depends on configuration would have been testing the built-in defaults while
// reporting on the user's install. `preferences-domain` checks that this worked.
PreferencesDomain.use(suiteName: PreferencesDomain.priTypeSuiteName)

let usage = """
pritype-device-check — verify PriType against the machine it is installed on

  These checks ask the real system the questions the in-process test suite
  cannot: whether macOS grants this binary a tap, whether IOHIDManager opens the
  keyboards, and whether a key a person actually pressed arrives. A check that
  cannot run is reported as skipped, never as a pass.

USAGE
  pritype-device-check [--interactive] [--only id,id] [--timeout SECONDS]
  pritype-device-check --list

OPTIONS
  --interactive      also run the checks that need a key pressed by hand
  --only id,id       run only these checks, interactive ones included
  --timeout SECONDS  how long to wait for a key press (default 15)
  --allow-mutation   permit checks that change system state (none ship today)
  --list             print the checks and exit
  --help             print this and exit

EXIT STATUS
  0  every selected check ran and passed
  1  a check ran and failed
  2  nothing failed, but a check could not run
  3  no check ran at all
"""

func fail(_ message: String, status: Int32 = 64) -> Never {  // EX_USAGE
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(status)
}

let parsed: DeviceCheckArguments
do {
    parsed = try DeviceCheckArguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as DeviceCheckArguments.ParseError {
    fail("\(error.message)\n\n\(usage)")
} catch {
    fail("\(error)")
}

if parsed.wantsHelp {
    print(usage)
    exit(0)
}

let prompt = OperatorPrompt(timeout: parsed.timeout ?? 15)
let checks = unattendedChecks + interactiveChecks(prompt: prompt)

if parsed.wantsList {
    for check in checks {
        let kind = check.requiresOperator ? "interactive" : "unattended"
        print("\(check.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(kind)  \(check.title)")
    }
    exit(0)
}

// A filter that matches nothing would otherwise run zero checks and report an
// empty run — which does exit non-zero, but says "nothing ran" rather than "you
// misspelled this". Say which word was wrong.
let unknown = DeviceCheckRunner.unknownIDs(in: parsed.selection, among: checks)
guard unknown.isEmpty else {
    fail("no such check: \(unknown.sorted().joined(separator: ", "))\nrun --list to see them")
}

print("pritype-device-check — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("preferences: \(PreferencesDomain.currentSuiteName ?? "this process")")
print("")

let report = DeviceCheckRunner.run(checks, selection: parsed.selection)
print(report.render())
exit(report.exitStatus.rawValue)
