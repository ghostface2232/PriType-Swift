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
