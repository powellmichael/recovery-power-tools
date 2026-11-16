import CryptoKit
import Foundation

/// What a licence key says about its owner. Signed, so none of it can be
/// edited without the seller's private key.
public struct License: Codable, Equatable, Sendable {
    public var name: String
    public var email: String
    public var issued: Date

    public init(name: String, email: String, issued: Date = Date()) {
        self.name = name
        self.email = email
        self.issued = issued
    }
}

/// Licence keys are checked offline: an Ed25519 signature over the licence
/// details, verified against a public key built into the app. No server, no
/// activation limit, nothing to go down.
///
/// A key looks like `RPT1.<details>.<signature>`, both parts base64url.
///
/// ponytail: offline keys cannot be revoked, and a shared key works on any
/// number of Macs. Add a revocation list or online activation if refunded or
/// leaked keys become a real cost.
public enum LicenseCodec {
    public static let prefix = "RPT1"

    public static func issue(_ license: License, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let payload = try encoder.encode(license)
        let signature = try privateKey.signature(for: payload)
        return [prefix, base64URL(payload), base64URL(signature)].joined(separator: ".")
    }

    /// Returns the licence when `key` carries a valid signature for
    /// `publicKey`, otherwise nil. Whitespace is ignored, because keys get
    /// wrapped and padded when pasted out of an email.
    public static func verify(_ key: String, publicKey: Data) -> License? {
        let parts = key.filter { !$0.isWhitespace }.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == prefix,
              let payload = data(base64URL: String(parts[1])),
              let signature = data(base64URL: String(parts[2])),
              let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              verifier.isValidSignature(signature, for: payload) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(License.self, from: payload)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL text: String) -> Data? {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }
}
