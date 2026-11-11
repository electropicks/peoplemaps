import Foundation
#if canImport(CryptoKit)
import CryptoKit

/// Encrypts bytes on the phone so only the holder of a private key can read them (Docs/REPORTS.md 4.8): HPKE (RFC 9180),
/// X25519, HKDF-SHA256, ChaCha20-Poly1305, one message per box. The sender needs only the recipient's public key, so the app
/// ships no secret. Not tied to logs: `info` names the use, and anything else sent to the owner can be sealed the same way.
///
/// A box is `PMBOX1\n`, the 32-byte encapsulated key, then the ciphertext with its tag. `context` is authenticated but not
/// stored (a file's name), so a box opened under another name fails.
public enum SealedBox {
    public static let magic = Data("PMBOX1\n".utf8)
    private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    public enum Failure: Error, Equatable { case notABox, badKey }

    public static func seal(_ plain: Data, to publicKey: Data, info: String, context: String) throws -> Data {
        guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey) else { throw Failure.badKey }
        var sender = try HPKE.Sender(recipientKey: key, ciphersuite: suite, info: Data(info.utf8))
        let sealed = try sender.seal(plain, authenticating: Data(context.utf8))
        return magic + sender.encapsulatedKey + sealed
    }

    public static func open(_ box: Data, with privateKey: Data, info: String, context: String) throws -> Data {
        guard box.count > magic.count + 32, box.prefix(magic.count) == magic else { throw Failure.notABox }
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey) else { throw Failure.badKey }
        let body = box.dropFirst(magic.count)
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: Data(info.utf8), encapsulatedKey: Data(body.prefix(32)))
        return try recipient.open(Data(body.dropFirst(32)), authenticating: Data(context.utf8))
    }

    /// A new key pair, raw bytes: the private half stays with the owner, the public half ships in the app.
    public static func newKey() -> (privateKey: Data, publicKey: Data) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return (key.rawRepresentation, key.publicKey.rawRepresentation)
    }
    public static func publicKey(of privateKey: Data) throws -> Data {
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey) else { throw Failure.badKey }
        return key.publicKey.rawRepresentation
    }
}
#endif
