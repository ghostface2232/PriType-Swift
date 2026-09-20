import Foundation

/// Answers "is the plain ABC layout still enabled?" from a *fresh* process.
///
/// HIToolbox caches the enabled-input-source list per process. On macOS 26 and
/// later that cache is never refreshed after a direct preference write: not by
/// `kTISNotifyEnabledKeyboardInputSourcesChanged`, not when TextInputMenuAgent
/// restarts, not by re-listing all sources. `TISDisableInputSource` is no
/// alternative — for the last keyboard layout it returns `noErr` and changes
/// nothing. So the running input method can only observe its own removal from a
/// process that started after the write; checking in-process reports "still
/// enabled" forever and turned every successful removal into a "Failed" pill.
///
/// The probe re-launches the main executable with `argument`. The child answers
/// on stdout and exits before AppKit or IMK start (see `main.swift`).
public enum ABCLayoutStatusProbe {
    public static let argument = "--abc-layout-status"
    static let disabledOutput = "abc-layout: disabled"
    static let enabledOutput = "abc-layout: enabled"

    /// Call first thing in `main.swift`. Exits the process when the probe was
    /// requested; returns normally for an ordinary launch.
    public static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard arguments.dropFirst().contains(argument) else { return }
        let disabled = InputSourceManager.shared.isABCDisabledAccordingToTIS()
        print(disabled ? disabledOutput : enabledOutput)
        exit(0)
    }

    /// `true`/`false` for a well-formed answer, `nil` for anything else.
    static func parse(_ output: String) -> Bool? {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case disabledOutput: return true
        case enabledOutput: return false
        default: return nil
        }
    }

    /// Run the probe in a fresh process and return its answer.
    ///
    /// `false` when the child cannot be launched, exceeds `timeout`, exits
    /// abnormally, or prints something else: an unanswered probe cannot prove
    /// absence. Blocks the calling thread for the child's lifetime, so call it off
    /// the main thread.
    public static func isABCDisabledInFreshProcess(
        executable: URL? = Bundle.main.executableURL,
        timeout: TimeInterval = 2
    ) -> Bool {
        answerFromFreshProcess(executable: executable, timeout: timeout) ?? false
    }

    /// The same probe, telling a real answer from no answer at all.
    ///
    /// The app collapses the two: a probe that did not answer cannot prove ABC is
    /// gone, so it reports "still enabled" and the user tries again. A
    /// verification run has to separate them — "ABC is enabled" is a fact about
    /// the machine, while "the probe never answered" is this mechanism being
    /// broken, and the second one is the finding.
    ///
    /// - Returns: whether ABC is disabled, or `nil` when the child produced no
    ///   usable answer.
    public static func answerFromFreshProcess(
        executable: URL? = Bundle.main.executableURL,
        timeout: TimeInterval = 2
    ) -> Bool? {
        guard let executable else {
            DebugLogger.log("ABCLayoutStatusProbe: no executable URL")
            return nil
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [argument]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            DebugLogger.log("ABCLayoutStatusProbe: launch failed — \(error)")
            return nil
        }
        // The answer is one short line, far below the pipe buffer, so waiting for
        // exit before reading cannot deadlock. A hung child is killed, not awaited.
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            DebugLogger.log("ABCLayoutStatusProbe: timed out")
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, let answer = parse(output) else {
            DebugLogger.log("ABCLayoutStatusProbe: unusable answer status=\(process.terminationStatus) output=\(output)")
            return nil
        }
        return answer
    }
}
