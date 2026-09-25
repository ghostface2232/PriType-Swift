import CryptoKit
import Foundation
import Testing
@testable import PriTypeCore

// MARK: - Update Signature Tests

/// These cover what stands between a downloaded file and a root installer.
@Suite("UpdateSignature")
struct UpdateSignatureTests {

    private static let signingKey = Curve25519.Signing.PrivateKey()
    private static var publicKey: String { signingKey.publicKey.rawRepresentation.base64EncodedString() }

    private static func manifestData(
        version: String = "2.9.0",
        sha256: String = String(repeating: "a", count: 64),
        size: Int = 4096,
        minimumSystemVersion: String? = "14.0"
    ) -> Data {
        var fields: [String: Any] = ["version": version, "sha256": sha256, "size": size]
        if let minimumSystemVersion {
            fields["minimumSystemVersion"] = minimumSystemVersion
        }
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    private static func signature(for data: Data) throws -> String {
        try signingKey.signature(for: data).base64EncodedString()
    }

    // MARK: - Signature

    @Test("A manifest signed by the release key is accepted")
    func acceptsGenuineManifest() throws {
        let data = Self.manifestData()
        let manifest = try UpdateSignature.verifiedManifest(
            manifest: data,
            signatureText: try Self.signature(for: data) + "\n",
            publicKeyBase64: Self.publicKey
        )

        #expect(manifest.version == "2.9.0")
        #expect(manifest.size == 4096)
        #expect(manifest.minimumSystemVersion == "14.0")
    }

    @Test("A manifest edited after signing is rejected")
    func rejectsTamperedManifest() throws {
        let original = Self.manifestData()
        let signature = try Self.signature(for: original)
        // Same shape, different package: exactly what an attacker would swap in.
        let tampered = Self.manifestData(sha256: String(repeating: "b", count: 64))

        #expect(throws: UpdateSignature.Failure.badSignature) {
            try UpdateSignature.verifiedManifest(
                manifest: tampered,
                signatureText: signature,
                publicKeyBase64: Self.publicKey
            )
        }
    }

    @Test("A signature from another key is rejected")
    func rejectsForeignSignature() throws {
        let data = Self.manifestData()
        let otherKey = Curve25519.Signing.PrivateKey()
        let signature = try otherKey.signature(for: data).base64EncodedString()

        #expect(throws: UpdateSignature.Failure.badSignature) {
            try UpdateSignature.verifiedManifest(
                manifest: data,
                signatureText: signature,
                publicKeyBase64: Self.publicKey
            )
        }
    }

    @Test("Malformed signature text is rejected rather than ignored")
    func rejectsMalformedSignature() {
        #expect(throws: UpdateSignature.Failure.badSignature) {
            try UpdateSignature.verifiedManifest(
                manifest: Self.manifestData(),
                signatureText: "not base64 %%%",
                publicKeyBase64: Self.publicKey
            )
        }
    }

    @Test("Without a configured key, verification fails closed")
    func failsClosedWithoutKey() throws {
        let data = Self.manifestData()
        let signature = try Self.signature(for: data)

        #expect(throws: UpdateSignature.Failure.keyNotConfigured) {
            try UpdateSignature.verifiedManifest(manifest: data, signatureText: signature, publicKeyBase64: "")
        }
        #expect(throws: UpdateSignature.Failure.keyNotConfigured) {
            try UpdateSignature.verifiedManifest(
                manifest: data,
                signatureText: signature,
                publicKeyBase64: "not-a-key"
            )
        }
    }

    @Test("Signed but unreadable JSON is rejected")
    func rejectsMalformedManifest() throws {
        let data = Data("{\"version\": \"2.9.0\"}".utf8)

        #expect(throws: UpdateSignature.Failure.malformedManifest) {
            try UpdateSignature.verifiedManifest(
                manifest: data,
                signatureText: try Self.signature(for: data),
                publicKeyBase64: Self.publicKey
            )
        }
    }

    @Test("The key the app ships with is a usable Ed25519 key")
    func shippingKeyIsUsable() throws {
        let key = UpdateSignature.releasePublicKeyBase64
        let raw = try #require(Data(base64Encoded: key), "the shipping key is not base64")
        #expect(throws: Never.self) {
            try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        }
    }

    @Test("The app reads a manifest the release workflow actually produced")
    func acceptsRealReleaseManifest() throws {
        // Fixtures from a real run of release.yml, signed with the release
        // secret. Everything else here signs with a key generated in-process,
        // which would pass even if the shipping key, the workflow's output
        // format and the app's reader had drifted apart. Regenerate both files
        // from a workflow run if the signing key is ever rotated.
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let manifestData = try Data(contentsOf: fixtures.appendingPathComponent("update.json"))
        let signature = try String(
            contentsOf: fixtures.appendingPathComponent("update.json.sig"),
            encoding: .utf8
        )

        let manifest = try UpdateSignature.verifiedManifest(manifest: manifestData, signatureText: signature)

        #expect(manifest.version == "2.8.0")
        #expect(manifest.minimumSystemVersion == "14.0")
        #expect(manifest.size == 5_043_898)
        #expect(manifest.sha256.count == 64)
    }

    // MARK: - Manifest Rules

    private static let sampleManifest = UpdateManifest(
        version: "2.9.0",
        sha256: "abc123",
        size: 4096,
        minimumSystemVersion: "14.0"
    )

    private static let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)

    @Test("A manifest that matches the release and the file is accepted")
    func acceptsMatchingManifest() {
        #expect(throws: Never.self) {
            try UpdateSignature.check(
                Self.sampleManifest,
                expectedVersion: "2.9.0",
                packageDigest: "ABC123",
                packageSize: 4096,
                systemVersion: Self.sonoma
            )
        }
    }

    @Test("An older release's manifest cannot be replayed as a newer one")
    func rejectsReplayedManifest() {
        // Both files are validly signed; only the version pin catches this.
        #expect(throws: UpdateSignature.Failure.versionMismatch(manifest: "2.9.0", expected: "2.9.1")) {
            try UpdateSignature.check(
                Self.sampleManifest,
                expectedVersion: "2.9.1",
                packageDigest: "abc123",
                packageSize: 4096,
                systemVersion: Self.sonoma
            )
        }
    }

    @Test("A package the manifest does not describe is rejected")
    func rejectsMismatchedPackage() {
        #expect(throws: UpdateSignature.Failure.packageMismatch) {
            try UpdateSignature.check(
                Self.sampleManifest,
                expectedVersion: "2.9.0",
                packageDigest: "def456",
                packageSize: 4096,
                systemVersion: Self.sonoma
            )
        }
        #expect(throws: UpdateSignature.Failure.packageMismatch) {
            try UpdateSignature.check(
                Self.sampleManifest,
                expectedVersion: "2.9.0",
                packageDigest: "abc123",
                packageSize: 4097,
                systemVersion: Self.sonoma
            )
        }
    }

    @Test("A release needing a newer macOS is not installed")
    func rejectsUnsupportedSystem() {
        let manifest = UpdateManifest(
            version: "2.9.0",
            sha256: "abc123",
            size: 4096,
            minimumSystemVersion: "26.0"
        )

        #expect(throws: UpdateSignature.Failure.unsupportedSystem(required: "26.0")) {
            try UpdateSignature.check(
                manifest,
                expectedVersion: "2.9.0",
                packageDigest: "abc123",
                packageSize: 4096,
                systemVersion: Self.sonoma
            )
        }
    }

    @Test("Minimum system version compares component by component")
    func systemVersionComparison() {
        let version = { (major: Int, minor: Int) in
            OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
        }

        #expect(UpdateSignature.satisfies(version(14, 0), minimum: "14"))
        #expect(UpdateSignature.satisfies(version(14, 0), minimum: "14.0.0"))
        #expect(UpdateSignature.satisfies(version(15, 1), minimum: "14.6"))
        #expect(UpdateSignature.satisfies(version(14, 10), minimum: "14.9"))
        #expect(!UpdateSignature.satisfies(version(14, 5), minimum: "14.6"))
        #expect(!UpdateSignature.satisfies(version(13, 9), minimum: "14.0"))
    }

    // MARK: - Digest

    @Test("The file digest matches the one taken over the same bytes")
    func fileDigestMatches() throws {
        let bytes = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 % 251) })
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pritype-digest-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(try UpdateSignature.sha256Hex(ofFileAt: url) == expected)
    }
}

// MARK: - Install Command Tests

@Suite("UpdateInstaller command")
struct UpdateInstallerCommandTests {

    @Test("The install command re-checks the digest as root before installing")
    func commandChecksDigestAsRoot() {
        let command = UpdateInstaller.installCommand(
            packagePath: "/Users/someone/Library/Caches/Updates/2.9.0/PriTypeV2_Release.pkg",
            digest: "abc123"
        )

        // Root copies the file out of the user-writable directory first, so the
        // bytes it checks are the bytes it installs.
        #expect(command.contains("/usr/bin/mktemp -d /private/tmp/pritype-update.XXXXXX"))
        #expect(command.contains("/bin/cp '/Users/someone/Library/Caches/Updates/2.9.0/PriTypeV2_Release.pkg'"))
        #expect(command.contains("= 'abc123' ]"))
        #expect(command.contains("/usr/sbin/installer -pkg \"$staging/package.pkg\" -target /"))
        // Detached, or the authorization call would block until the installer
        // has killed the process waiting on it.
        #expect(command.hasSuffix("2>&1 &"))
    }

    @Test("A path with a quote cannot break out of its argument")
    func quotingResistsInjection() {
        let command = UpdateInstaller.installCommand(
            packagePath: "/tmp/evil'; rm -rf / #.pkg",
            digest: "abc123"
        )

        #expect(command.contains("'/tmp/evil'\\''; rm -rf / #.pkg'"))
        #expect(!command.contains("; rm -rf / #.pkg'\n"))
    }

    @Test("Root writes its log only where no one but root can plant a symlink")
    func logLivesInRootOnlyDirectory() throws {
        let command = UpdateInstaller.installCommand(
            packagePath: "/Users/someone/Library/Caches/Updates/2.9.0/PriTypeV2_Release.pkg",
            digest: "abc123"
        )
        #expect(command.hasSuffix("> '\(UpdateInstaller.installLogPath)' 2>&1 &"))

        // Checked on this machine's filesystem rather than by the path's look: a
        // directory someone else can write lets them replace the log with a
        // symlink, and root's redirection would follow it.
        let directory = (UpdateInstaller.installLogPath as NSString).deletingLastPathComponent
        let attributes = try FileManager.default.attributesOfItem(atPath: directory)
        #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
        #expect((attributes[.ownerAccountID] as? NSNumber)?.intValue == 0)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        #expect(permissions & 0o022 == 0, "group or others can write \(directory)")
    }

    @Test("AppleScript quoting escapes what would end the literal")
    func appleScriptQuoting() {
        #expect(UpdateInstaller.appleScriptQuoted("say \"hi\"") == "\"say \\\"hi\\\"\"")
        #expect(UpdateInstaller.appleScriptQuoted("back\\slash") == "\"back\\\\slash\"")
    }

    @Test("Whether an install landed is read from the version now running")
    func installOutcomeFromRunningVersion() {
        #expect(UpdateInstaller.installLanded(pending: "2.9.0", runningVersion: "2.9.0"))
        // Still the old build: the installer never replaced the bundle.
        #expect(!UpdateInstaller.installLanded(pending: "2.9.0", runningVersion: "2.8.0"))
        // Installed something newer by hand in the meantime; nothing to report.
        #expect(UpdateInstaller.installLanded(pending: "2.9.0", runningVersion: "2.9.1"))
        // A tag written "2.9" and a bundle written "2.9.0" are one version.
        #expect(UpdateInstaller.installLanded(pending: "v2.9", runningVersion: "2.9.0"))
    }

    @Test("The authorization script asks for administrator privileges with a prompt")
    func authorizationScriptShape() {
        let script = UpdateInstaller.authorizationScript(command: "/bin/echo hi", prompt: "권한이 필요합니다")

        #expect(script.hasPrefix("do shell script \"/bin/echo hi\""))
        #expect(script.contains("with prompt \"권한이 필요합니다\""))
        #expect(script.hasSuffix("with administrator privileges"))
    }
}

// MARK: - Authorization Child Tests

@Suite("UpdateInstaller authorization child")
struct UpdateAuthorizationChildTests {
    private static let signingKey = Curve25519.Signing.PrivateKey()
    private static var publicKey: String { signingKey.publicKey.rawRepresentation.base64EncodedString() }

    /// A staging directory as `install` leaves it: the package, its manifest
    /// and the manifest's signature.
    private struct Staged {
        let directory: URL
        let package: Data
        var packagePath: String { directory.appendingPathComponent(UpdateInstaller.packageFileName).path }
        var digest: String { SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined() }
    }

    private static func staged(
        version: String = "99.0.0",
        signedBy key: Curve25519.Signing.PrivateKey = signingKey,
        describing described: Data? = nil
    ) throws -> Staged {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let package = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        let staged = Staged(directory: directory, package: package)
        try package.write(to: URL(fileURLWithPath: staged.packagePath))

        let facts = described ?? package
        let fields: [String: Any] = [
            "version": version,
            "sha256": SHA256.hash(data: facts).map { String(format: "%02x", $0) }.joined(),
            "size": facts.count,
        ]
        let manifest = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        try manifest.write(to: directory.appendingPathComponent(UpdateInstaller.manifestFileName))
        try Data(key.signature(for: manifest).base64EncodedString().utf8)
            .write(to: directory.appendingPathComponent(UpdateInstaller.signatureFileName))
        return staged
    }

    /// Runs the child's work against `staged`, recording whether it asked.
    private static func authorize(
        _ arguments: [String],
        running: String = "2.9.0"
    ) -> (exit: UpdateInstaller.AuthorizationExit, script: String?) {
        var script: String?
        let exit = UpdateInstaller.authorize(
            arguments: arguments, runningVersion: running, channel: .stable, publicKeyBase64: publicKey
        ) { script = $0; return nil }
        return (exit, script)
    }

    private static func child(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-child-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private enum Outcome: Equatable {
        case started
        case failed(UpdateInstaller.Failure)
    }

    private static let stagingURL = URL(fileURLWithPath: "/Users/someone/Library/Caches/Updates/99.0.0", isDirectory: true)

    private static func outcome(of body: String) async throws -> Outcome {
        let exe = try child(body)
        defer { try? FileManager.default.removeItem(at: exe) }
        do {
            try await UpdateInstaller.authorizeInChild(executable: exe, staging: stagingURL)
            return .started
        } catch let failure as UpdateInstaller.Failure {
            return .failed(failure)
        }
    }

    // MARK: Parent

    @Test("An ordinary launch is not treated as the authorization child")
    func ordinaryLaunchContinues() {
        // Would call exit() if it matched; returning is the assertion.
        UpdateInstaller.runAuthorizationIfRequested(arguments: ["PriTypeV2"])
        UpdateInstaller.runAuthorizationIfRequested(arguments: ["PriTypeV2", "--abc-layout-status"])
    }

    @Test("The child is handed the staging directory and nothing else")
    func childArguments() async throws {
        let record = FileManager.default.temporaryDirectory.appendingPathComponent("auth-args-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: record) }
        #expect(try await Self.outcome(of: "printf '%s\\n' \"$@\" > '\(record.path)'") == .started)
        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == [UpdateInstaller.authorizationArgument, Self.stagingURL.path])
    }

    @Test("Exit statuses map to started, cancelled and failed")
    func exitStatuses() async throws {
        #expect(try await Self.outcome(of: "exit 0") == .started)
        #expect(try await Self.outcome(of: "exit 3") == .failed(.authorizationCancelled))
        #expect(try await Self.outcome(of: "echo 'The administrator user name or password was incorrect.' >&2; exit 1")
                == .failed(.authorizationFailed("The administrator user name or password was incorrect.")))
        #expect(try await Self.outcome(of: "exit 64") == .failed(.authorizationFailed("exit status 64")))
        // Killed, e.g. by the package's `preinstall`, is not an authorization.
        #expect(try await Self.outcome(of: "kill -TERM $$") == .failed(.authorizationFailed("killed by signal 15")))
        #expect(try await Self.outcome(of: "kill -QUIT $$") == .failed(.authorizationFailed("killed by signal 3")))
    }

    @Test("A child that cannot start is a failure, not a hang")
    func missingExecutable() async {
        await #expect(throws: UpdateInstaller.Failure.self) {
            try await UpdateInstaller.authorizeInChild(
                executable: URL(fileURLWithPath: "/nonexistent/PriTypeV2"), staging: Self.stagingURL)
        }
    }

    @MainActor
    @Test("The main thread keeps running while the dialog waits for an answer")
    func mainThreadStaysFree() async throws {
        let exe = try Self.child("sleep 0.5; exit 0")
        defer { try? FileManager.default.removeItem(at: exe) }
        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        try await UpdateInstaller.authorizeInChild(executable: exe, staging: Self.stagingURL)
        ticker.cancel()
        #expect(ticks >= 10, "main ran \(ticks) times during a 0.5 s wait")
    }

    // MARK: Child

    @Test("A signed, newer release is installed by the digest the child computed")
    func genuineReleaseIsOffered() throws {
        let staged = try Self.staged()
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        let (exit, script) = Self.authorize([staged.directory.path])
        #expect(exit == .started)
        #expect(script == UpdateInstaller.authorizationScript(
            command: UpdateInstaller.installCommand(packagePath: staged.packagePath, digest: staged.digest),
            prompt: L10n.update.authorizationPrompt))
    }

    @Test("A package no release key signed is never offered to root")
    func unsignedPackageIsRefused() throws {
        // What a stranger running PriType could stage: their own package with a
        // manifest that matches it, signed by a key of their own.
        let staged = try Self.staged(signedBy: Curve25519.Signing.PrivateKey())
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        let (exit, script) = Self.authorize([staged.directory.path])
        #expect(exit == .failed)
        #expect(script == nil)
    }

    @Test("A package other than the one the manifest describes is refused")
    func swappedPackageIsRefused() throws {
        let staged = try Self.staged(describing: Data("the genuine release".utf8))
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        let (exit, script) = Self.authorize([staged.directory.path])
        #expect(exit == .failed)
        #expect(script == nil)
    }

    @Test("A genuine release no newer than the running one is refused")
    func downgradeIsRefused() throws {
        for version in ["2.9.0", "2.8.0"] {
            let staged = try Self.staged(version: version)
            defer { try? FileManager.default.removeItem(at: staged.directory) }
            let (exit, script) = Self.authorize([staged.directory.path], running: "2.9.0")
            #expect(exit == .failed, Comment(rawValue: version))
            #expect(script == nil)
        }
    }

    @Test("A directory without the release's manifest is refused")
    func missingManifestIsRefused() throws {
        let staged = try Self.staged()
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        try FileManager.default.removeItem(at: staged.directory.appendingPathComponent(UpdateInstaller.manifestFileName))
        let (exit, script) = Self.authorize([staged.directory.path])
        #expect(exit == .failed)
        #expect(script == nil)
    }

    @Test("The child reports a closed dialog and other errors apart")
    func childErrors() throws {
        let staged = try Self.staged()
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        func exit(_ error: NSDictionary) -> UpdateInstaller.AuthorizationExit {
            UpdateInstaller.authorize(
                arguments: [staged.directory.path], runningVersion: "2.9.0", channel: .stable,
                publicKeyBase64: Self.publicKey) { _ in error }
        }
        #expect(exit([NSAppleScript.errorNumber: -128, NSAppleScript.errorMessage: "User canceled."]) == .cancelled)
        #expect(exit([NSAppleScript.errorNumber: -60005, NSAppleScript.errorMessage: "wrong password"]) == .failed)
    }

    @Test("The child asks for nothing unless given one absolute directory")
    func childRejectsOtherArguments() {
        for arguments in [[], ["relative/staging"], ["/tmp/a", "/tmp/b"], ["/tmp/x.pkg", String(repeating: "ab", count: 32)]] {
            let (exit, script) = Self.authorize(arguments)
            #expect(exit == .usage, Comment(rawValue: "\(arguments)"))
            #expect(script == nil)
        }
    }
}
