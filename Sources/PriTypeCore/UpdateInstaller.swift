import Foundation
import os

/// Downloads a release, proves it is genuine, and installs it.
///
/// PriType lives in `/Library/Input Methods`, which only root can write, so the
/// install itself is a privileged command the user authorizes once. Two details
/// shape everything here:
///
/// - The package's `preinstall` kills PriTypeV2. The process that starts the
///   install is therefore killed halfway through it, so the command is detached
///   and left to finish on its own. How it went is read back from root's log:
///   by the process that started it if the install fails before `preinstall`
///   runs, else on the next launch, if there is one: a failure after `preinstall`
///   has removed the bundle leaves nothing to launch.
/// - Nothing about the download is trustworthy on its own — the PKG is
///   unsigned, and its root scripts are outside the app's code signature — so
///   `UpdateSignature` has to accept it before the installer is ever offered
///   the file.
public final class UpdateInstaller: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = UpdateInstaller()

    /// The app has exactly one of these — `shared`. Tests make their own.
    init() {}

    // MARK: - Types

    /// What the settings window shows while an install runs.
    public enum Phase: Sendable, Equatable {
        /// Fraction is `nil` until the server states a length.
        case downloading(fraction: Double?)
        case verifying
        /// The authorization dialog is up; the user has not answered yet.
        case awaitingAuthorization
        /// Handed to `installer`. PriType is about to be killed and relaunched,
        /// unless the install fails first, which `install` then throws.
        case installing
    }

    public enum Failure: Error, Equatable {
        /// This release has no signed package to install.
        case noInstallableAssets
        case download(String)
        /// The package is larger than any PriType release plausibly is.
        case implausibleSize(Int)
        case verification(UpdateSignature.Failure)
        /// The user dismissed the authorization dialog.
        case authorizationCancelled
        case authorizationFailed(String)
        /// Another run has the dialog up or root's installer running. Its staging
        /// directory and its marker are in use, so this run touches neither.
        case alreadyInstalling
        /// Root's installer ended and did not replace what is running.
        case installIncomplete
    }

    /// What root's log says about the install it was opened for.
    enum InstallLogState: Equatable {
        case absent
        /// Opened and not finished. `age`: since root last wrote to it.
        case running(age: TimeInterval)
        case finished(status: Int32)
    }

    /// Where an install attempt stands, judged from outside it.
    enum InstallOutcome: Equatable {
        case landed
        case incomplete
        /// Root is still at work: nothing can be said yet.
        case undecided
    }

    // MARK: - Constants

    /// A ceiling on what will be downloaded. PriType's package is a few MB; a
    /// far larger one means something other than a PriType release.
    private static let maximumPackageSize = 200 * 1024 * 1024

    /// Manifest and signature are tiny. Refusing anything bigger keeps a
    /// surprising response from being read into memory whole.
    private static let maximumMetadataSize = 64 * 1024

    static let packageFileName = "PriTypeV2_Release.pkg"
    /// The release's signed manifest and its signature, kept beside the package.
    static let manifestFileName = UpdateChecker.manifestAssetName
    static let signatureFileName = UpdateChecker.signatureAssetName

    /// Where root records how the install went.
    ///
    /// A directory only root can write, because root is what opens it. The log
    /// used to sit next to the download in the user's caches, and a redirection
    /// by root into a user-owned directory follows whatever the user put there: a
    /// symlink planted at the log's path had root truncate and overwrite the file
    /// it pointed to, and a directory swapped for a symlink had root create files
    /// wherever it led. Readable by everyone, as the rest of `/var/log` is.
    static let installLogPath = "/private/var/log/pritype-update.log"

    /// How often root's log is read while an install runs.
    private static let installWatchInterval: Duration = .seconds(1)

    /// How long root may go without writing to its log before it is taken to be
    /// gone: a restart or a kill leaves a log with no status in it for good.
    static let installDeadline: TimeInterval = 10 * 60

    // MARK: - Privileged Run

    /// Whether a run has reached the dialog or root's installer. Only one may: a
    /// second would empty the staging directory the first asked root to read, and
    /// answer for the first's marker.
    private let privilegedRun = OSAllocatedUnfairLock(initialState: false)

    private var hasPrivilegedRun: Bool {
        privilegedRun.withLock { $0 }
    }

    func claimPrivilegedRun() -> Bool {
        privilegedRun.withLock { held in
            defer { held = true }
            return !held
        }
    }

    func releasePrivilegedRun() {
        privilegedRun.withLock { $0 = false }
    }

    // MARK: - Install

    /// Downloads, verifies and installs `update`.
    ///
    /// Does not return while root's installer runs, and once `preinstall` runs it
    /// never returns at all: that kills PriType whether the install then succeeds
    /// or not. One that fails before then leaves PriType alive and throws
    /// `Failure.installIncomplete`, after notifying the user as on a next launch,
    /// so it reaches them even if the window that asked is gone.
    ///
    /// - Parameter progress: called on an arbitrary queue as the phase changes.
    public func install(
        _ update: UpdateChecker.UpdateInfo,
        progress: @escaping @Sendable (Phase) -> Void
    ) async throws {
        guard let assets = update.assets else { throw Failure.noInstallableAssets }
        guard assets.packageSize <= Self.maximumPackageSize else {
            throw Failure.implausibleSize(assets.packageSize)
        }
        guard !hasPrivilegedRun else { throw Failure.alreadyInstalling }

        let staging = try stagingDirectory(for: update.version)
        let packageURL = staging.appendingPathComponent(Self.packageFileName)

        progress(.downloading(fraction: nil))
        try await downloadPackage(from: assets.package, to: packageURL, progress: progress)

        progress(.verifying)
        let manifestData = try await downloadMetadata(from: assets.manifest)
        let signatureData = try await downloadMetadata(from: assets.signature)
        _ = try Self.verifiedDigest(
            packageURL: packageURL,
            manifest: manifestData,
            signature: signatureData,
            expectedVersion: update.version
        )
        // Nothing else in here looks: past this point a cancelled run would still
        // put the password dialog up.
        try Task.checkCancellation()
        // Kept beside the package for the authorization child, which trusts
        // nothing it is handed and verifies all three again itself.
        try manifestData.write(to: staging.appendingPathComponent(Self.manifestFileName))
        try signatureData.write(to: staging.appendingPathComponent(Self.signatureFileName))

        guard claimPrivilegedRun() else { throw Failure.alreadyInstalling }
        defer { releasePrivilegedRun() }

        progress(.awaitingAuthorization)
        // Recorded before the dialog, not after: once the command starts, this
        // process can be killed at any moment, and the next launch needs to know
        // an install was attempted in order to report how it went.
        ConfigurationManager.shared.pendingUpdateVersion = update.version
        do {
            try await launchPrivilegedInstall(staging: staging)
        } catch {
            ConfigurationManager.shared.pendingUpdateVersion = nil
            throw error
        }
        progress(.installing)

        // Detached: cancelling the caller calls nothing off, root answers to no
        // one here, and a cancelled sleep would turn this into a busy loop.
        let pending = update.version
        let outcome = await Task.detached(priority: .utility) {
            await Self.awaitInstallOutcome(pending: pending, runningVersion: AboutInfo.version)
        }.value
        Self.settleInstall(outcome, pending: pending, runningVersion: AboutInfo.version)
        guard outcome == .landed else { throw Failure.installIncomplete }
    }

    // MARK: - Verification

    /// Returns the package digest once the release vouches for it.
    static func verifiedDigest(
        packageURL: URL,
        manifest: Data,
        signature: Data,
        expectedVersion: String,
        publicKeyBase64: String = UpdateSignature.releasePublicKeyBase64
    ) throws -> String {
        guard let signatureText = String(bytes: signature, encoding: .utf8) else {
            throw Failure.verification(.badSignature)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: packageURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        let digest = try UpdateSignature.sha256Hex(ofFileAt: packageURL)

        do {
            let verified = try UpdateSignature.verifiedManifest(
                manifest: manifest,
                signatureText: signatureText,
                publicKeyBase64: publicKeyBase64
            )
            try UpdateSignature.check(
                verified,
                expectedVersion: expectedVersion,
                packageDigest: digest,
                packageSize: size
            )
        } catch let failure as UpdateSignature.Failure {
            DebugLogger.log("UpdateInstaller: Verification failed - \(failure)")
            throw Failure.verification(failure)
        }

        return digest
    }

    // MARK: - Privileged Install

    /// Starts the install as root and returns as soon as it is running.
    ///
    /// The command is detached (`&` with its output redirected) for two reasons:
    /// `do shell script` waits for the command's output to close, and the
    /// package kills PriType while installing. Detaching means the installer
    /// survives the death of the process that asked for it.
    ///
    /// Root copies the package into a directory only root can write and checks
    /// the digest again there. Verifying a file in a user-writable directory and
    /// then handing that same path to a root installer would leave a window in
    /// which the file could be swapped for another one.
    private func launchPrivilegedInstall(staging: URL) async throws {
        guard let executable = Bundle.main.executableURL else {
            throw Failure.authorizationFailed("no executable to ask for authorization")
        }
        try await Self.authorizeInChild(executable: executable, staging: staging)
        DebugLogger.log("UpdateInstaller: Install started, awaiting termination")
    }

    // MARK: - Authorization Child

    /// The argument that makes the executable ask for authorization and exit.
    public static let authorizationArgument = "--authorize-update-install"

    /// How the authorization child ends.
    enum AuthorizationExit: Int32 {
        /// Authorized; root's command is running on its own.
        case started = 0
        /// Refused, or the staged release did not verify; the reason is on
        /// standard error.
        case failed = 1
        /// The user closed the dialog.
        case cancelled = 3
        /// Called with something other than one staging directory.
        case usage = 64
    }

    /// Runs the authorization dialog in a child process and waits for it
    /// without blocking.
    ///
    /// `do shell script … with administrator privileges` holds its thread until
    /// the user answers the dialog, and `NSAppleScript` belongs on the main
    /// thread. In the input method that thread serves every keystroke of every
    /// app, so while the dialog waited, typing anywhere else went unanswered.
    /// The child is this same executable, so the dialog still names PriType.
    static func authorizeInChild(executable: URL, staging: URL) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = [authorizationArgument, staging.path]
        let standardError = Pipe()
        process.standardError = standardError
        process.standardOutput = FileHandle.nullDevice

        let (reason, status) = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: ($0.terminationReason, $0.terminationStatus)) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: Failure.authorizationFailed("cannot start: \(error.localizedDescription)"))
            }
        }

        // A signal's number is not an exit status: SIGQUIT is 3, like a cancel.
        switch reason == .exit ? AuthorizationExit(rawValue: status) : nil {
        case .started:
            return
        case .cancelled:
            // A decision, not a fault: the download stays staged and the button
            // stays available.
            throw Failure.authorizationCancelled
        default:
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = !detail.isEmpty ? detail
                : reason == .exit ? "exit status \(status)" : "killed by signal \(status)"
            DebugLogger.log("UpdateInstaller: Authorization failed - \(message)")
            throw Failure.authorizationFailed(message)
        }
    }

    /// Call first thing in `main.swift`. Asks for authorization and exits when
    /// this launch is the authorization child; returns for an ordinary launch.
    public static func runAuthorizationIfRequested(arguments: [String] = CommandLine.arguments) {
        let arguments = Array(arguments.dropFirst())
        guard arguments.first == authorizationArgument else { return }
        let exitCode = authorize(arguments: Array(arguments.dropFirst()))
        exit(exitCode.rawValue)
    }

    /// The child's work: verify the staged release, then ask to install it.
    ///
    /// Anyone who can run PriType can run it with `authorizationArgument`, and
    /// a dialog that names PriType is one a user trusts. So the child takes
    /// nothing on its caller's word — not a path to install, not a digest.
    /// It is given a directory and installs only what verifies there: a
    /// manifest signed with the release key, for a version newer than the one
    /// running, describing the package beside it byte for byte. The worst a
    /// stranger can do with it is offer the user a genuine PriType update.
    /// Root checks the digest again after copying the package somewhere only
    /// root can write, so the file cannot be swapped after this check.
    static func authorize(
        arguments: [String],
        runningVersion: String = AboutInfo.version,
        channel: ReleaseChannel = AboutInfo.releaseChannel,
        publicKeyBase64: String = UpdateSignature.releasePublicKeyBase64,
        execute: (String) -> NSDictionary? = executeAppleScript
    ) -> AuthorizationExit {
        guard arguments.count == 1, arguments[0].hasPrefix("/") else {
            FileHandle.standardError.write(Data("usage: \(authorizationArgument) <staging directory>\n".utf8))
            return .usage
        }
        let staging = URL(fileURLWithPath: arguments[0], isDirectory: true)
        let packageURL = staging.appendingPathComponent(packageFileName)

        let digest: String
        do {
            let manifest = try readMetadata(staging.appendingPathComponent(manifestFileName))
            let signature = try readMetadata(staging.appendingPathComponent(signatureFileName))
            let version = try UpdateSignature.verifiedManifest(
                manifest: manifest,
                signatureText: String(bytes: signature, encoding: .utf8) ?? "",
                publicKeyBase64: publicKeyBase64
            ).version
            guard UpdateChecker.offersUpdate(latest: version, current: runningVersion, channel: channel) else {
                throw Failure.authorizationFailed("\(version) is not newer than the running \(runningVersion)")
            }
            digest = try verifiedDigest(
                packageURL: packageURL,
                manifest: manifest,
                signature: signature,
                expectedVersion: version,
                publicKeyBase64: publicKeyBase64
            )
        } catch {
            FileHandle.standardError.write(Data("the staged update did not verify: \(error)\n".utf8))
            return .failed
        }

        let source = authorizationScript(
            command: installCommand(packagePath: packageURL.path, digest: digest),
            prompt: L10n.update.authorizationPrompt
        )
        guard let error = execute(source) else { return .started }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return .failed
    }

    /// Reads a staged manifest or signature, refusing anything implausibly big.
    private static func readMetadata(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumMetadataSize + 1) ?? Data()
        guard data.count <= maximumMetadataSize else {
            throw Failure.download("\(url.lastPathComponent) is larger than \(maximumMetadataSize) bytes")
        }
        return data
    }

    /// Runs `source`, returning the error `NSAppleScript` reports, if any.
    static func executeAppleScript(_ source: String) -> NSDictionary? {
        guard let script = NSAppleScript(source: source) else {
            return [NSAppleScript.errorMessage: "cannot build the install script"]
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error
    }

    /// The command root runs: stage the package where only root can write,
    /// check its digest there, install it, then clean up and record the status.
    ///
    /// It ends detached (`&`) with its output redirected, because `do shell
    /// script` waits for the output to close and the package kills PriType
    /// while the installer is still running.
    ///
    /// The package path is the only user-controlled path in it, and root only
    /// reads it. Everything root writes is in a directory only root can write:
    /// its own staging directory, and `installLogPath`.
    ///
    /// The log is emptied before the command returns, not when the detached part
    /// gets around to opening it: from the moment authorization succeeds, a status
    /// in the log is this install's and not the last one's. Every way out of the
    /// detached part writes a status, since a log without one means root is at work.
    static func installCommand(packagePath: String, digest: String) -> String {
        let log = shellQuoted(installLogPath)
        return """
        : > \(log); /bin/chmod 644 \(log)
        ( staging=$(/usr/bin/mktemp -d /private/tmp/pritype-update.XXXXXX) || { echo "status=70"; exit 70; }
          /bin/cp \(shellQuoted(packagePath)) "$staging/package.pkg" \
        && [ "$(/usr/bin/shasum -a 256 "$staging/package.pkg" | /usr/bin/cut -d ' ' -f 1)" = \(shellQuoted(digest)) ] \
        && /usr/sbin/installer -pkg "$staging/package.pkg" -target /
          status=$?
          /bin/rm -rf "$staging"
          echo "status=$status" ) >> \(log) 2>&1 &
        """
    }

    /// The AppleScript that asks for authorization and runs `command` as root.
    static func authorizationScript(command: String, prompt: String) -> String {
        """
        do shell script \(appleScriptQuoted(command)) \
        with prompt \(appleScriptQuoted(prompt)) \
        with administrator privileges
        """
    }

    /// Wraps a value so the shell reads it as one literal argument.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Wraps a value as an AppleScript string literal.
    static func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    // MARK: - Downloads

    private func downloadPackage(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Phase) -> Void
    ) async throws {
        let download = PackageDownload(
            destination: destination,
            maximumSize: Self.maximumPackageSize
        ) { fraction in
            progress(.downloading(fraction: fraction))
        }

        do {
            try await download.run(url: url)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Self.downloadError(from: error, taskIsCancelled: Task.isCancelled)
        }
    }

    /// What a failed download amounts to. A task cancelled mid-download fails with
    /// `URLError.cancelled`, which is the user's decision and not a failure. Only
    /// the task's own state can say so: the size limit cancels the download too.
    static func downloadError(from error: any Error, taskIsCancelled: Bool) -> any Error {
        taskIsCancelled ? CancellationError() : Failure.download(error.localizedDescription)
    }

    private func downloadMetadata(from url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw Failure.download("invalid response")
            }
            guard http.statusCode == 200 else {
                throw Failure.download("HTTP \(http.statusCode)")
            }
            guard data.count <= Self.maximumMetadataSize else {
                throw Failure.download("\(url.lastPathComponent) is implausibly large")
            }
            return data
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Self.downloadError(from: error, taskIsCancelled: Task.isCancelled)
        }
    }

    // MARK: - Staging

    /// A per-version directory under Caches, emptied of anything left over.
    ///
    /// Per version so a half-finished download of an older release is never
    /// mistaken for this one's package.
    private func stagingDirectory(for version: String) throws -> URL {
        let directory = try Self.updatesDirectory().appendingPathComponent(version, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func updatesDirectory() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.pritype.inputmethod.v2", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    // MARK: - Reporting an Install

    /// Reports how the last in-app install went, if one was attempted.
    ///
    /// The installer kills PriType partway through, so the process that started
    /// an install rarely lives to report it. This runs on the next launch instead:
    /// the marker was written before the password dialog, so finding it means an
    /// install was attempted.
    ///
    /// That launch can come before the install is over. IMK relaunches the old
    /// build if a key arrives between `preinstall`'s kill and its removal of the
    /// bundle, and `postinstall` launches the new one while the installer is still
    /// running. Judged then, the first would report a failure just before the
    /// install landed. So while root is at work the marker stays, and this waits:
    /// `postinstall` kills an old build, and the new one hears the status.
    public static func reportPendingInstall() {
        guard let pending = ConfigurationManager.shared.pendingUpdateVersion else { return }
        let running = AboutInfo.version
        let outcome = installOutcome(pending: pending, runningVersion: running, log: readInstallLog())
        guard outcome == .undecided else {
            settleInstall(outcome, pending: pending, runningVersion: running)
            return
        }

        DebugLogger.log("UpdateInstaller: The install of \(pending) is still running; waiting for it")
        guard shared.claimPrivilegedRun() else { return }
        Task.detached(priority: .utility) {
            defer { shared.releasePrivilegedRun() }
            let settled = await awaitInstallOutcome(pending: pending, runningVersion: running)
            settleInstall(settled, pending: pending, runningVersion: running)
        }
    }

    /// Waits until the install can be judged. `readLog` and `sleep` are for tests.
    static func awaitInstallOutcome(
        pending: String,
        runningVersion: String,
        readLog: @Sendable () -> InstallLogState = readInstallLog,
        sleep: @Sendable () async -> Void = { try? await Task.sleep(for: installWatchInterval) }
    ) async -> InstallOutcome {
        while true {
            let outcome = installOutcome(pending: pending, runningVersion: runningVersion, log: readLog())
            guard outcome == .undecided else { return outcome }
            await sleep()
        }
    }

    /// Whether the install landed, from the version now running and root's log.
    ///
    /// The version alone cannot say: it cannot tell a build that lost from one that
    /// is about to be replaced. And the log alone cannot either: after a failure the
    /// user may install the same release by hand, and the failed log is still there.
    static func installOutcome(
        pending: String,
        runningVersion: String,
        log: InstallLogState,
        channel: ReleaseChannel = AboutInfo.releaseChannel
    ) -> InstallOutcome {
        // Installed by hand in the meantime: the log is about something else.
        if UpdateChecker.isNewer(runningVersion, than: pending) { return .landed }
        let landed = installLanded(pending: pending, runningVersion: runningVersion)
        switch log {
        case .finished(let status) where status != 0:
            // A beta is offered the release of its own number, so for it a matching
            // version says nothing. For anyone else it says the bundle was replaced.
            return landed && channel != .beta ? .landed : .incomplete
        case .running(let age) where age < installDeadline:
            return .undecided
        case .absent, .finished, .running:
            return landed ? .landed : .incomplete
        }
    }

    /// Tells the user how the install went and ends the attempt.
    private static func settleInstall(_ outcome: InstallOutcome, pending: String, runningVersion: String) {
        ConfigurationManager.shared.pendingUpdateVersion = nil

        if outcome == .landed {
            DebugLogger.log("UpdateInstaller: Update to \(pending) landed")
            UpdateNotifier.shared.notifyInstallResult(
                title: L10n.update.installedTitle,
                body: String(format: L10n.update.installedBody, runningVersion)
            )
        } else {
            // The log is the only account of what root actually did.
            let log = installLog() ?? "(no log)"
            DebugLogger.log("UpdateInstaller: Update to \(pending) did not land. installer log: \(log)")
            UpdateNotifier.shared.notifyInstallResult(
                title: L10n.update.installIncompleteTitle,
                body: String(format: L10n.update.installIncompleteBody, pending)
            )
        }

        discardStagedDownloads()
    }

    /// Whether the version now running means the pending install succeeded.
    ///
    /// Equal counts as landed, and so does newer: a user who installed a later
    /// release by hand in the meantime has no failure to hear about.
    static func installLanded(pending: String, runningVersion: String) -> Bool {
        !UpdateChecker.isNewer(
            UpdateChecker.normalizeVersion(pending),
            than: UpdateChecker.normalizeVersion(runningVersion)
        )
    }

    /// Removes staged downloads. Called once an install has been accounted for.
    public static func discardStagedDownloads() {
        guard let directory = try? updatesDirectory() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// The log the last privileged install wrote, if there is one.
    static func installLog() -> String? {
        guard let data = FileManager.default.contents(atPath: installLogPath) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    @Sendable
    static func readInstallLog() -> InstallLogState {
        let attributes = try? FileManager.default.attributesOfItem(atPath: installLogPath)
        let modified = attributes?[.modificationDate] as? Date
        return installLogState(text: installLog(), age: modified.map { Date().timeIntervalSince($0) } ?? 0)
    }

    /// Root ends its log with a `status=` line, and writes it only when finished.
    static func installLogState(text: String?, age: TimeInterval) -> InstallLogState {
        guard let text else { return .absent }
        guard let last = text.split(whereSeparator: \.isNewline).last, last.hasPrefix("status="),
              let status = Int32(last.dropFirst("status=".count)) else {
            return .running(age: age)
        }
        return .finished(status: status)
    }
}

// MARK: - Package Download

/// A download that reports progress and writes to a known path.
///
/// `URLSession`'s async `download(for:)` reports no progress, and iterating
/// `bytes(for:)` a byte at a time is far slower than the network for a package
/// this size, so this uses the delegate API directly.
private final class PackageDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let maximumSize: Int
    private let onProgress: @Sendable (Double?) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var moveFailure: (any Error)?

    init(
        destination: URL,
        maximumSize: Int,
        onProgress: @escaping @Sendable (Double?) -> Void
    ) {
        self.destination = destination
        self.maximumSize = maximumSize
        self.onProgress = onProgress
    }

    func run(url: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > Int64(maximumSize) || totalBytesWritten > Int64(maximumSize) {
            downloadTask.cancel()
            return
        }
        guard totalBytesExpectedToWrite > 0 else {
            onProgress(nil)
            return
        }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    // The temporary file is deleted the moment this returns, so the move has to
    // happen here rather than after the continuation resumes.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            lock.lock()
            moveFailure = UpdateInstaller.Failure.download("HTTP \(http.statusCode)")
            lock.unlock()
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.lock()
            moveFailure = error
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let moveFailure = self.moveFailure
        lock.unlock()

        if let error {
            finish(.failure(error))
        } else if let moveFailure {
            finish(.failure(moveFailure))
        } else {
            finish(.success(()))
        }
    }
}
