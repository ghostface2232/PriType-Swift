import Foundation

/// Downloads a release, proves it is genuine, and installs it.
///
/// PriType lives in `/Library/Input Methods`, which only root can write, so the
/// install itself is a privileged command the user authorizes once. Two details
/// shape everything here:
///
/// - The package's `preinstall` kills PriTypeV2. The process that starts the
///   install is therefore killed halfway through it, so the command is detached
///   and left to finish on its own; nothing after it can report the outcome.
///   What happened is read back from a log on the next launch instead.
/// - Nothing about the download is trustworthy on its own — the PKG is
///   unsigned, and its root scripts are outside the app's code signature — so
///   `UpdateSignature` has to accept it before the installer is ever offered
///   the file.
public final class UpdateInstaller: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = UpdateInstaller()

    private init() {}

    // MARK: - Types

    /// What the settings window shows while an install runs.
    public enum Phase: Sendable, Equatable {
        /// Fraction is `nil` until the server states a length.
        case downloading(fraction: Double?)
        case verifying
        /// The authorization dialog is up; the user has not answered yet.
        case awaitingAuthorization
        /// Handed to `installer`. PriType is about to be killed and relaunched.
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
    }

    // MARK: - Constants

    /// A ceiling on what will be downloaded. PriType's package is a few MB; a
    /// far larger one means something other than a PriType release.
    private static let maximumPackageSize = 200 * 1024 * 1024

    /// Manifest and signature are tiny. Refusing anything bigger keeps a
    /// surprising response from being read into memory whole.
    private static let maximumMetadataSize = 64 * 1024

    private static let packageFileName = "PriTypeV2_Release.pkg"
    static let installLogFileName = "install.log"

    // MARK: - Install

    /// Downloads, verifies and installs `update`.
    ///
    /// Returns once the privileged command has been started, not once it has
    /// finished: by then PriType is being terminated by the installer.
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

        let staging = try stagingDirectory(for: update.version)
        let packageURL = staging.appendingPathComponent(Self.packageFileName)

        progress(.downloading(fraction: nil))
        try await downloadPackage(from: assets.package, to: packageURL, progress: progress)

        progress(.verifying)
        let manifestData = try await downloadMetadata(from: assets.manifest)
        let signatureData = try await downloadMetadata(from: assets.signature)
        let digest = try verify(
            packageURL: packageURL,
            manifest: manifestData,
            signature: signatureData,
            version: update.version
        )

        progress(.awaitingAuthorization)
        // Recorded before the dialog, not after: once the command starts, this
        // process can be killed at any moment, and the next launch needs to know
        // an install was attempted in order to report how it went.
        ConfigurationManager.shared.pendingUpdateVersion = update.version
        do {
            try await launchPrivilegedInstall(
                packageURL: packageURL,
                digest: digest,
                logURL: staging.appendingPathComponent(Self.installLogFileName)
            )
        } catch {
            ConfigurationManager.shared.pendingUpdateVersion = nil
            throw error
        }
        progress(.installing)
    }

    // MARK: - Verification

    /// Returns the package digest once the release vouches for it.
    private func verify(
        packageURL: URL,
        manifest: Data,
        signature: Data,
        version: String
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
                signatureText: signatureText
            )
            try UpdateSignature.check(
                verified,
                expectedVersion: version,
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
    @MainActor
    private func launchPrivilegedInstall(packageURL: URL, digest: String, logURL: URL) async throws {
        // The authorization dialog blocks the main thread while it is up, so the
        // settings window gets a frame to draw "waiting for authorization"
        // first. Without it the window simply freezes on the previous phase.
        try? await Task.sleep(nanoseconds: 120_000_000)

        let source = Self.authorizationScript(
            command: Self.installCommand(
                packagePath: packageURL.path,
                digest: digest,
                logPath: logURL.path
            ),
            prompt: L10n.update.authorizationPrompt
        )

        guard let script = NSAppleScript(source: source) else {
            throw Failure.authorizationFailed("cannot build the install script")
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            // -128 is the user closing the dialog, which is a decision, not a
            // fault: the download stays staged and the button stays available.
            if (error[NSAppleScript.errorNumber] as? Int) == -128 {
                throw Failure.authorizationCancelled
            }
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            DebugLogger.log("UpdateInstaller: Authorization failed - \(message)")
            throw Failure.authorizationFailed(message)
        }

        DebugLogger.log("UpdateInstaller: Install started, awaiting termination")
    }

    /// The command root runs: stage the package where only root can write,
    /// check its digest there, install it, then clean up and record the status.
    ///
    /// It ends detached (`&`) with its output redirected, because `do shell
    /// script` waits for the output to close and the package kills PriType
    /// while the installer is still running.
    static func installCommand(packagePath: String, digest: String, logPath: String) -> String {
        """
        ( staging=$(/usr/bin/mktemp -d /private/tmp/pritype-update.XXXXXX) || exit 70
          /bin/cp \(shellQuoted(packagePath)) "$staging/package.pkg" \
        && [ "$(/usr/bin/shasum -a 256 "$staging/package.pkg" | /usr/bin/cut -d ' ' -f 1)" = \(shellQuoted(digest)) ] \
        && /usr/sbin/installer -pkg "$staging/package.pkg" -target /
          status=$?
          /bin/rm -rf "$staging"
          echo "status=$status" ) > \(shellQuoted(logPath)) 2>&1 &
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
            throw Failure.download(error.localizedDescription)
        }
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
            throw Failure.download(error.localizedDescription)
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
    /// The installer kills PriType partway through, so nothing in the process
    /// that started an install can report its outcome. This runs on the next
    /// launch instead and decides from the version now running: the marker was
    /// written before the install began, so finding it means an install was
    /// started and either landed or did not.
    ///
    /// - Parameter runningVersion: the version this build reports, overridable
    ///   for tests.
    public static func reportPendingInstall(runningVersion: String = AboutInfo.version) {
        guard let pending = ConfigurationManager.shared.pendingUpdateVersion else { return }
        ConfigurationManager.shared.pendingUpdateVersion = nil

        if installLanded(pending: pending, runningVersion: runningVersion) {
            DebugLogger.log("UpdateInstaller: Update to \(pending) landed")
            UpdateNotifier.shared.notifyInstallResult(
                title: L10n.update.installedTitle,
                body: String(format: L10n.update.installedBody, runningVersion)
            )
        } else {
            // The log is the only account of what root actually did, and it is
            // gone as soon as the staging directory is.
            let log = installLog(for: pending) ?? "(no log)"
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

    /// The log the privileged command wrote for `version`, if it left one.
    static func installLog(for version: String) -> String? {
        guard let directory = try? updatesDirectory() else { return nil }
        let log = directory
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent(installLogFileName)
        guard let data = FileManager.default.contents(atPath: log.path) else { return nil }
        return String(bytes: data, encoding: .utf8)
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
