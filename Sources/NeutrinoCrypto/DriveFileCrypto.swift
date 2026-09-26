import Foundation
import Sodium

// MARK: - DriveFileCryptoError

public enum DriveFileCryptoError: LocalizedError, Equatable {
    case encryptionFailed
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .encryptionFailed: return "The file could not be encrypted."
        case .decryptionFailed: return "The file could not be decrypted. It may be damaged, or sealed to a key this device doesn't have."
        }
    }
}

// MARK: - DriveFileCrypto

/// The primitives an encrypted Drive file goes through: its data encryption key (DEK), its
/// content, and its metadata. No networking and no actor, so any app can call them from any
/// context and tests can assert them directly.
///
/// ## Wire format
///
/// - **DEK:** 32 random bytes, generated per file, sealed to the account's Curve25519 identity
///   key with `crypto_box_seal`, base64url without padding. Stored server-side with the keyring
///   version it was sealed to (`PUT /drive/files/{id}/key`).
/// - **Content:** `[24-byte secretstream header][chunk 0]…[chunk n, tagged FINAL]`, each chunk a
///   `crypto_secretstream_xchacha20poly1305` push. The web client writes one push for the whole
///   file; a chunked file records its plaintext `chunkSize` in its encrypted metadata, and one
///   without that field is a single push.
/// - **Metadata:** `{ name, mimeType[, chunkSize] }` as JSON, encrypted as one push with the DEK,
///   base64url without padding.
///
/// These are the web's `encryptFileKey` / `decryptFileKey` / `encryptFile` / `decryptFile` /
/// `encryptMetadata` / `decryptMetadata` (`packages/e2e-crypto/src/crypto.ts`), and match the
/// copies inside the Drive (`SealedKeyCrypto`) and Photos (`MediaCrypto`) apps, so a file written
/// by any of them opens in the others. Changing anything here is a wire-format change across the
/// web, every iOS app, the macOS client and the server.
public enum DriveFileCrypto {

    private static let sodium = Sodium()

    /// The secretstream header, which prefixes every ciphertext.
    public static let headerBytes = SecretStream.XChaCha20Poly1305.HeaderBytes
    /// The per-chunk overhead: a tag byte plus a 16-byte Poly1305 MAC.
    public static let chunkOverheadBytes = SecretStream.XChaCha20Poly1305.ABytes

    // MARK: - Keys

    /// A fresh 32-byte DEK.
    public static func newDEK() -> Bytes {
        sodium.secretStream.xchacha20poly1305.key()
    }

    /// Seals `dek` to a Curve25519 public key, returning base64url.
    public static func seal(dek: Bytes, toPublicKey publicKey: Bytes) throws -> String {
        guard let sealed = sodium.box.seal(message: dek, recipientPublicKey: publicKey),
              let encoded = sodium.utils.bin2base64(sealed, variant: .URLSAFE_NO_PADDING) else {
            throw DriveFileCryptoError.encryptionFailed
        }
        return encoded
    }

    /// Opens a DEK sealed by ``seal(dek:toPublicKey:)``.
    public static func openDEK(_ sealedBase64URL: String, publicKey: Bytes, secretKey: Bytes) throws -> Bytes {
        guard let sealed = sodium.utils.base642bin(sealedBase64URL, variant: .URLSAFE_NO_PADDING),
              let dek: Bytes = sodium.box.open(anonymousCipherText: sealed,
                                               recipientPublicKey: publicKey,
                                               recipientSecretKey: secretKey) else {
            throw DriveFileCryptoError.decryptionFailed
        }
        return dek
    }

    // MARK: - Content

    /// Encrypts `plaintext` as a single push, the format every client reads.
    public static func encrypt(_ plaintext: Data, dek: Bytes) throws -> Data {
        guard let stream = sodium.secretStream.xchacha20poly1305.initPush(secretKey: dek),
              let ciphertext = stream.push(message: Bytes(plaintext), tag: .FINAL) else {
            throw DriveFileCryptoError.encryptionFailed
        }
        return Data(stream.header() + ciphertext)
    }

    /// Decrypts content written by ``encrypt(_:dek:)``, by the web, or chunked by Photos.
    ///
    /// - Parameter chunkSize: the framing from the file's metadata; nil for a single push.
    public static func decrypt(_ data: Data, dek: Bytes, chunkSize: Int? = nil) throws -> Data {
        guard data.count > headerBytes else { throw DriveFileCryptoError.decryptionFailed }
        let header = Bytes(data.prefix(headerBytes))
        let body = data.dropFirst(headerBytes)
        guard let pull = sodium.secretStream.xchacha20poly1305.initPull(secretKey: dek, header: header) else {
            throw DriveFileCryptoError.decryptionFailed
        }
        guard let chunkSize, chunkSize > 0 else {
            guard let (plaintext, tag) = pull.pull(cipherText: Bytes(body)), tag == .FINAL else {
                throw DriveFileCryptoError.decryptionFailed
            }
            return Data(plaintext)
        }
        var plaintext = Data()
        plaintext.reserveCapacity(body.count)
        var offset = body.startIndex
        var sawFinal = false
        while offset < body.endIndex {
            let end = body.index(offset, offsetBy: chunkSize + chunkOverheadBytes,
                                 limitedBy: body.endIndex) ?? body.endIndex
            guard let (chunk, tag) = pull.pull(cipherText: Bytes(body[offset..<end])) else {
                throw DriveFileCryptoError.decryptionFailed
            }
            plaintext.append(contentsOf: chunk)
            offset = end
            if tag == .FINAL { sawFinal = true; break }
        }
        // Every chunk authenticates itself, so only this catches a stream cut short.
        guard sawFinal, offset == body.endIndex else { throw DriveFileCryptoError.decryptionFailed }
        return plaintext
    }

    // MARK: - Metadata

    /// The plaintext of a file's `encryptedMetadata`.
    public struct Metadata: Equatable, Sendable {
        public let name: String
        public let mimeType: String
        /// The content's framing; nil for a single push.
        public let chunkSize: Int?

        public init(name: String, mimeType: String, chunkSize: Int? = nil) {
            self.name = name
            self.mimeType = mimeType
            self.chunkSize = chunkSize
        }
    }

    /// Encrypts `{ name, mimeType }` (and `chunkSize` only when the content is chunked, so an
    /// ordinary file's blob is exactly the web's shape).
    public static func encryptMetadata(_ metadata: Metadata, dek: Bytes) throws -> String {
        var fields: [String: Any] = ["name": metadata.name, "mimeType": metadata.mimeType]
        if let chunkSize = metadata.chunkSize { fields["chunkSize"] = chunkSize }
        guard let json = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let encoded = sodium.utils.bin2base64(Bytes(try encrypt(json, dek: dek)),
                                                    variant: .URLSAFE_NO_PADDING) else {
            throw DriveFileCryptoError.encryptionFailed
        }
        return encoded
    }

    public static func decryptMetadata(_ encoded: String, dek: Bytes) throws -> Metadata {
        guard let raw = sodium.utils.base642bin(encoded, variant: .URLSAFE_NO_PADDING) else {
            throw DriveFileCryptoError.decryptionFailed
        }
        let json = try decrypt(Data(raw), dek: dek)
        guard let fields = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw DriveFileCryptoError.decryptionFailed
        }
        return Metadata(name: fields["name"] as? String ?? "",
                        mimeType: fields["mimeType"] as? String ?? "application/octet-stream",
                        chunkSize: fields["chunkSize"] as? Int)
    }
}
