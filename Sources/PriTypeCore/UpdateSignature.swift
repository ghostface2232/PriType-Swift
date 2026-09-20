import CryptoKit
import Foundation

/// What a release says about the package it ships.
///
/// The bytes this is decoded from are the bytes the release workflow signed, so
/// every field here is covered by the signature.
public struct UpdateManifest: Sendable, Decodable, Equatable {
    /// Version of the release this package belongs to, matching the tag.
    public let version: String
    /// Lowercase hex SHA-256 of the package.
    public let sha256: String
    /// Size of the package in bytes.
    public let size: Int
    /// Oldest macOS the package may be installed on, when the release states one.
    public let minimumSystemVersion: String?
}

/// Verifies that a downloaded package is the one the release workflow built.
///
/// The PKG is neither signed nor notarized, and the app's own code signature
/// does not cover the `preinstall`/`postinstall` scripts the installer runs as
/// root. So nothing about the downloaded file is trustworthy on its own: the
/// release ships a manifest signed with a key only the workflow holds, and the
/// app installs only what that manifest describes.
///
/// Everything here is pure, so the rules that decide whether an update may be
/// installed are testable without touching the network or the installer.
public enum UpdateSignature {

    /// Ed25519 public key matching the `UPDATE_SIGNING_KEY` release secret, base64.
    ///
    /// The release workflow reads this line back out of the source and verifies
    /// the manifest it just signed against it, so a rotated secret cannot ship a
    /// release that installed copies are unable to verify.
    ///
    /// Empty means no key is configured: verification then fails closed and the
    /// app falls back to opening the release page.
    public static let releasePublicKeyBase64 = "Xx+iineUYQ8mt/WXZRH5FQpZtees1se6lq0aNKsB6nY="

    public enum Failure: Error, Equatable {
        /// No public key is compiled in, so nothing can be verified.
        case keyNotConfigured
        /// The signature file is not base64, or is not a valid signature.
        case badSignature
        /// The manifest is not the JSON this app understands.
        case malformedManifest
        /// The manifest describes a different release than the one being installed.
        case versionMismatch(manifest: String, expected: String)
        /// The downloaded package is not the one the manifest describes.
        case packageMismatch
        /// The release needs a newer macOS than this machine runs.
        case unsupportedSystem(required: String)
    }

    // MARK: - Signature

    /// Decodes a manifest after proving the signature over its exact bytes.
    ///
    /// - Parameters:
    ///   - manifest: the raw `update.json` bytes, exactly as downloaded.
    ///   - signatureText: contents of `update.json.sig` (base64, trailing newline allowed).
    ///   - publicKeyBase64: the key to verify against; the shipping key by default.
    public static func verifiedManifest(
        manifest: Data,
        signatureText: String,
        publicKeyBase64: String = releasePublicKeyBase64
    ) throws -> UpdateManifest {
        let trimmedKey = publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw Failure.keyNotConfigured }
        guard let keyBytes = Data(base64Encoded: trimmedKey),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else {
            throw Failure.keyNotConfigured
        }

        let trimmedSignature = signatureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: trimmedSignature) else {
            throw Failure.badSignature
        }
        guard publicKey.isValidSignature(signature, for: manifest) else {
            throw Failure.badSignature
        }
        guard let decoded = try? JSONDecoder().decode(UpdateManifest.self, from: manifest) else {
            throw Failure.malformedManifest
        }
        return decoded
    }

    // MARK: - Manifest Rules

    /// Whether a verified manifest actually describes the update being installed.
    ///
    /// A valid signature only proves the manifest came from the release
    /// workflow — an old release's manifest and package are signed just as
    /// validly as the newest one's. Pinning the version to the release being
    /// installed is what stops an older package from being replayed as a new
    /// one, and pinning the digest is what ties the manifest to the bytes on
    /// disk.
    public static func check(
        _ manifest: UpdateManifest,
        expectedVersion: String,
        packageDigest: String,
        packageSize: Int,
        systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) throws {
        let manifestVersion = UpdateChecker.normalizeVersion(manifest.version)
        let expected = UpdateChecker.normalizeVersion(expectedVersion)
        guard manifestVersion == expected else {
            throw Failure.versionMismatch(manifest: manifestVersion, expected: expected)
        }
        guard manifest.size == packageSize,
              manifest.sha256.lowercased() == packageDigest.lowercased() else {
            throw Failure.packageMismatch
        }
        if let required = manifest.minimumSystemVersion,
           !satisfies(systemVersion, minimum: required) {
            throw Failure.unsupportedSystem(required: required)
        }
    }

    /// Whether the running macOS is at least `minimum`.
    ///
    /// Missing trailing components count as zero, so "14" and "14.0.0" are the
    /// same requirement. An unparseable requirement degrades per component the
    /// same way version comparison elsewhere does, rather than rejecting the
    /// update outright.
    static func satisfies(_ system: OperatingSystemVersion, minimum: String) -> Bool {
        let required = UpdateChecker.versionComponents(minimum)
        let running = [system.majorVersion, system.minorVersion, system.patchVersion]
        for index in 0..<max(required.count, running.count) {
            let lhs = index < running.count ? running[index] : 0
            let rhs = index < required.count ? required[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return true
    }

    // MARK: - Digest

    /// Lowercase hex SHA-256 of a file, read in chunks so a package never has to
    /// be held in memory whole.
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
