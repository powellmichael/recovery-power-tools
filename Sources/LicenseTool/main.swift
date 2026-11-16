import CryptoKit
import Foundation
import LicenseKit

// The seller's side of licensing. Not part of the app.
//
//   LicenseTool keygen                   create the signing key (once)
//   LicenseTool public                   print the public key again
//   LicenseTool issue "Name" email       print a licence key for a customer
//
// The private key is the whole business: anyone holding it can mint valid
// licences, and losing it means no new licence works with shipped builds.
// Keep it out of the repository and back it up somewhere safe.

let keyURL: URL = {
    if let override = ProcessInfo.processInfo.environment["RPT_LICENSE_KEY"] {
        return URL(fileURLWithPath: override)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".recovery-power-tools/license-signing.key")
}()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyURL, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("No signing key at \(keyURL.path). Run `LicenseTool keygen` first.")
    }
    return key
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "keygen":
    // Refuse to replace a key: every licence already sold would stop working.
    guard !FileManager.default.fileExists(atPath: keyURL.path) else {
        fail("A signing key already exists at \(keyURL.path). Not overwriting it.")
    }
    let key = Curve25519.Signing.PrivateKey()
    do {
        try FileManager.default.createDirectory(
            at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard FileManager.default.createFile(
            atPath: keyURL.path,
            contents: Data(key.rawRepresentation.base64EncodedString().utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { fail("Could not write \(keyURL.path).") }
    } catch {
        fail("Could not create \(keyURL.deletingLastPathComponent().path): \(error.localizedDescription)")
    }
    FileHandle.standardError.write(Data("Private key written to \(keyURL.path). Back it up.\nPublic key:\n".utf8))
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "public":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())

case "issue":
    guard arguments.count == 3 else { fail("Usage: LicenseTool issue \"Customer Name\" customer@example.com") }
    do {
        print(try LicenseCodec.issue(License(name: arguments[1], email: arguments[2]), privateKey: loadKey()))
    } catch {
        fail("Could not issue licence: \(error.localizedDescription)")
    }

default:
    fail("Usage: LicenseTool keygen | public | issue \"Customer Name\" customer@example.com")
}
