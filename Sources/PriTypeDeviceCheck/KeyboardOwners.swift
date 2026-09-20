import Foundation

/// Who, besides this process, is known to take exclusive hold of keyboards.
///
/// ## Why this is a list of names and not a lookup
///
/// `IOHIDManagerOpen` answering `kIOReturnExclusiveAccess` says only that
/// somebody else got there first; IOKit does not say who, and there is no
/// supported way to ask. The honest report is therefore "something owns them",
/// and the operator has to be told what to look for rather than what to do.
///
/// Naming one suspect and calling it the answer is worse than saying nothing,
/// which is what this used to do: it told the operator to quit PriTypeV2, and on
/// the machine this was written against, quitting PriTypeV2 changed nothing —
/// Karabiner-Elements had the keyboards, and the run had sent someone off to
/// break their own input method for no reason.
///
/// So the process list is consulted for the owners that are actually plausible,
/// every match is reported, and no claim is made that the list is complete.
enum KeyboardOwners {
    /// Processes that seize HID keyboards, by the substring that identifies them.
    ///
    /// Keyboard remappers and virtual-keyboard drivers grab devices exclusively;
    /// that is how they work. PriType's own installed build is here because it is
    /// the expected owner on a working Mac.
    static let known: [(substring: String, name: String)] = [
        ("PriTypeV2", "PriTypeV2 (the installed input method)"),
        ("Karabiner", "Karabiner-Elements"),
        ("Hammerspoon", "Hammerspoon"),
        ("BetterTouchTool", "BetterTouchTool"),
        ("Keyboard Maestro Engine", "Keyboard Maestro"),
        ("kmonad", "kmonad"),
    ]

    /// The known keyboard-grabbing processes running right now.
    ///
    /// - Parameter runningCommands: one entry per running process, as a command
    ///   path. Injected so the matching can be tested without a process table.
    static func plausibleOwners(in runningCommands: [String]) -> [String] {
        var found: [String] = []
        for entry in known where runningCommands.contains(where: { $0.contains(entry.substring) }) {
            if !found.contains(entry.name) { found.append(entry.name) }
        }
        return found
    }

    /// The advice line for a run that could not open the keyboards.
    static func advice(owners: [String]) -> String {
        guard !owners.isEmpty else {
            return "another process owns the keyboards; nothing this check recognizes is running, "
                 + "so look for a keyboard remapper or another input method"
        }
        return "another process owns the keyboards; running now: \(owners.joined(separator: ", "))"
    }

    /// Ask the system which of them are running. Returns the advice line.
    static func currentAdvice() -> String {
        advice(owners: plausibleOwners(in: runningCommands()))
    }

    /// Every running process's executable path.
    ///
    /// `comm`, not `command`: the second one includes arguments, and this
    /// process's own shell is in the list. A run started from a script that so
    /// much as mentions one of these names by name would then find it "running"
    /// — which it did, the first time this was written, reporting four remappers
    /// that were not installed because the command that built this file listed
    /// them. Empty when `ps` cannot be run, which degrades to the "nothing
    /// recognized" wording rather than failing.
    private static func runningCommands() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "comm"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Failable rather than lossy: a process list that did not decode is not
        // a process list with a few characters missing, and reporting "nothing
        // recognized" is the honest answer to one this could not read.
        guard let listing = String(bytes: data, encoding: .utf8) else { return [] }
        return listing.split(separator: "\n").map(String.init)
    }
}
