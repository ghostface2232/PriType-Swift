// Sign a release package so the app can install it without asking the user to
// trust the download.
//
// The PKG this repo ships is neither signed nor notarized, and the app's own
// code signature does not cover the pre/postinstall scripts that run as root.
// So the update path carries its own proof: a small manifest describing the
// package, signed with an Ed25519 key that only the release workflow holds.
// The app verifies that signature with a public key compiled into it, and
// refuses to install anything it cannot verify.
//
// The manifest names the version, so a signed-but-older package cannot be
// replayed as a new one, and it names the minimum OS, so an update that needs a
// newer macOS is never installed on a machine that cannot run it.
//
// Usage:
//   swift Tools/sign_update.swift generate-key
//   UPDATE_SIGNING_KEY=<base64> swift Tools/sign_update.swift sign \
//       --pkg PriTypeV2_Release.pkg --version 2.8.1 [--minimum-system-version 14.0] \
//       [--output-dir .]
//   swift Tools/sign_update.swift verify --pkg PriTypeV2_Release.pkg \
//       --manifest update.json --signature update.json.sig --public-key <base64>

import CryptoKit
import Foundation

let manifestName = "update.json"
let signatureName = "update.json.sig"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func usage() -> Never {
    let text = """
    usage:
      sign_update.swift generate-key
      sign_update.swift sign --pkg <path> --version <version> \
    [--minimum-system-version <version>] [--output-dir <dir>]
      sign_update.swift verify --pkg <path> [--manifest <path>] [--signature <path>] \
    [--public-key <base64>]

    sign reads the private key from UPDATE_SIGNING_KEY.
    verify reads the public key from --public-key or UPDATE_PUBLIC_KEY.
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

/// Options given as `--name value` pairs, in any order.
func parseOptions(_ arguments: [String]) -> [String: String] {
    var options: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        guard argument.hasPrefix("--") else {
            fail("unexpected argument '\(argument)'")
        }
        guard index + 1 < arguments.count else {
            fail("'\(argument)' needs a value")
        }
        options[String(argument.dropFirst(2))] = arguments[index + 1]
        index += 2
    }
    return options
}

func requiredOption(_ options: [String: String], _ name: String) -> String {
    guard let value = options[name], !value.isEmpty else {
        fail("--\(name) is required")
    }
    return value
}

func readFile(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("cannot read \(path)")
    }
    return data
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func decodeKey(_ base64: String, expecting name: String) -> Data {
    guard let key = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("\(name) is not valid base64")
    }
    return key
}

// The manifest is signed as bytes, so what the app parses is exactly what was
// signed. Sorted keys keep the output stable, which makes a diff between two
// releases readable.
func encodeManifest(_ fields: [String: Any]) -> Data {
    guard let json = try? JSONSerialization.data(
        withJSONObject: fields,
        options: [.prettyPrinted, .sortedKeys]
    ) else {
        fail("cannot encode the manifest")
    }
    return json + Data("\n".utf8)
}

func generateKey() {
    let privateKey = Curve25519.Signing.PrivateKey()
    print("""
    Private key (keep secret, store as the UPDATE_SIGNING_KEY repository secret):
      \(privateKey.rawRepresentation.base64EncodedString())

    Public key (compile into the app as UpdateSignature.releasePublicKey):
      \(privateKey.publicKey.rawRepresentation.base64EncodedString())

    Back the private key up somewhere outside GitHub. Losing it means existing
    installs can no longer be handed a verifiable update.
    """)
}

func sign(_ options: [String: String]) {
    let pkgPath = requiredOption(options, "pkg")
    let version = requiredOption(options, "version")
    let outputDir = options["output-dir"] ?? FileManager.default.currentDirectoryPath

    guard let secret = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"],
          !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        fail("UPDATE_SIGNING_KEY is not set")
    }
    guard let privateKey = try? Curve25519.Signing.PrivateKey(
        rawRepresentation: decodeKey(secret, expecting: "UPDATE_SIGNING_KEY")
    ) else {
        fail("UPDATE_SIGNING_KEY is not a valid Ed25519 private key")
    }

    let pkg = readFile(pkgPath)
    var fields: [String: Any] = [
        "version": version,
        "sha256": sha256Hex(pkg),
        "size": pkg.count,
    ]
    if let minimumSystemVersion = options["minimum-system-version"], !minimumSystemVersion.isEmpty {
        fields["minimumSystemVersion"] = minimumSystemVersion
    }

    let manifest = encodeManifest(fields)
    guard let signature = try? privateKey.signature(for: manifest) else {
        fail("signing failed")
    }

    let manifestURL = URL(fileURLWithPath: outputDir).appendingPathComponent(manifestName)
    let signatureURL = URL(fileURLWithPath: outputDir).appendingPathComponent(signatureName)
    do {
        try manifest.write(to: manifestURL)
        try Data((signature.base64EncodedString() + "\n").utf8).write(to: signatureURL)
    } catch {
        fail("cannot write the manifest: \(error.localizedDescription)")
    }

    print("wrote \(manifestURL.path)")
    print("wrote \(signatureURL.path)")
    print(String(data: manifest, encoding: .utf8) ?? "")
}

// Verifying here is what keeps a release from shipping a manifest the app will
// reject: the workflow runs the same checks the app runs, against the files it
// is about to upload.
func verify(_ options: [String: String]) {
    let pkgPath = requiredOption(options, "pkg")
    let manifestPath = options["manifest"] ?? manifestName
    let signaturePath = options["signature"] ?? signatureName
    guard let publicKeyBase64 = options["public-key"]
        ?? ProcessInfo.processInfo.environment["UPDATE_PUBLIC_KEY"] else {
        fail("--public-key or UPDATE_PUBLIC_KEY is required")
    }

    guard let publicKey = try? Curve25519.Signing.PublicKey(
        rawRepresentation: decodeKey(publicKeyBase64, expecting: "public key")
    ) else {
        fail("the public key is not a valid Ed25519 public key")
    }

    let manifest = readFile(manifestPath)
    guard let signatureText = String(bytes: readFile(signaturePath), encoding: .utf8) else {
        fail("\(signaturePath) is not UTF-8")
    }
    let signature = decodeKey(signatureText, expecting: "signature")

    guard publicKey.isValidSignature(signature, for: manifest) else {
        fail("the signature does not match \(manifestPath)")
    }
    guard let fields = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any] else {
        fail("the manifest is not a JSON object")
    }

    let pkg = readFile(pkgPath)
    guard fields["sha256"] as? String == sha256Hex(pkg) else {
        fail("the manifest digest does not match \(pkgPath)")
    }
    guard fields["size"] as? Int == pkg.count else {
        fail("the manifest size does not match \(pkgPath)")
    }
    if let expectedVersion = options["version"], fields["version"] as? String != expectedVersion {
        fail("the manifest version is not \(expectedVersion)")
    }

    print("ok: \(manifestPath) is signed and matches \(pkgPath)")
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
let options = parseOptions(Array(arguments.dropFirst()))

switch command {
case "generate-key":
    generateKey()
case "sign":
    sign(options)
case "verify":
    verify(options)
default:
    usage()
}
