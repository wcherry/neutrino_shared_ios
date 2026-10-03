import Foundation

// MARK: - PlaceEnvelope

/// The field-level envelope a saved place travels in: `task_places.encrypted_payload` on the
/// server, which can't read it. Built only from primitives every client already shares with Drive
/// files, so no client needs new cryptography to read it:
///
/// ```
/// encryptedPayload = JSON { "v": 1, "keyVersion": <int>, "key": <sealed DEK>, "data": <ciphertext> }
///   key  = crypto_box_seal(DEK, account public key), base64url without padding
///          (web: encryptFileKey · Swift: DriveFileCrypto.seal)
///   data = one secretstream push of the JSON payload with the DEK, base64url without padding
///          (web: encryptMetadata · Swift: DriveFileCrypto.encrypt)
/// payload        = JSON { "name": String, "lat": Double, "lng": Double, "radiusM": Int }
/// ```
///
/// A fresh 32-byte DEK per write, sealed to the active keyring version, which the envelope names
/// so a place saved before a key rotation still opens. Fields a later version adds to the payload
/// are ignored, not rejected; a different `v` is.
///
/// The web's implementation is `sealPlace` / `openPlace` in `neutrino/web/packages/e2e-crypto`,
/// and the spec is in `neutrino/agent_docs/end-to-end-encryption.md`. Both sides open the same
/// vectors (`place_envelope_vectors.json`, generated from the web's crypto by the calendar app's
/// `scripts/generate_place_envelope_vectors.mjs`). Changing this is a wire-format change across
/// the web, every iOS app and the server.
public enum PlaceEnvelope {
    public static let version = 1

    /// What a saved place holds. Everything here is encrypted.
    public struct Payload: Codable, Equatable, Sendable {
        public var name: String
        public var lat: Double
        public var lng: Double
        /// The arrival radius in metres.
        public var radiusM: Int

        public init(name: String, lat: Double, lng: Double, radiusM: Int) {
            self.name = name
            self.lat = lat
            self.lng = lng
            self.radiusM = radiusM
        }
    }

    private struct Envelope: Codable {
        let v: Int
        let keyVersion: Int
        let key: String
        let data: String
    }

    public enum Failure: LocalizedError, Equatable {
        case malformed
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .malformed:
                return "A saved place is damaged and can't be read."
            case .unsupportedVersion:
                return "A saved place was written by a newer version of Neutrino. Update the app to read it."
            }
        }
    }

    /// Seals `payload` to `publicKey`, the active keypair's, recording `keyVersion` for the reader.
    public static func seal(_ payload: Payload, publicKey: [UInt8], keyVersion: Int) throws -> String {
        let dek = DriveFileCrypto.newDEK()
        let json = try JSONEncoder.sortedKeys.encode(payload)
        let envelope = Envelope(v: version, keyVersion: keyVersion,
                                key: try DriveFileCrypto.seal(dek: dek, toPublicKey: publicKey),
                                data: Base64URL.encode([UInt8](try DriveFileCrypto.encrypt(json, dek: dek))))
        return String(decoding: try JSONEncoder.sortedKeys.encode(envelope), as: UTF8.self)
    }

    /// The key version `encrypted` was sealed to, so the caller can find that keypair.
    public static func keyVersion(of encrypted: String) throws -> Int {
        try envelope(encrypted).keyVersion
    }

    /// Opens `encrypted` with the keypair for its `keyVersion`. Throws `Failure` for a format it
    /// can't read, and `DriveFileCryptoError` for the wrong key or altered data.
    public static func open(_ encrypted: String, publicKey: [UInt8], secretKey: [UInt8]) throws -> Payload {
        let envelope = try envelope(encrypted)
        let dek = try DriveFileCrypto.openDEK(envelope.key, publicKey: publicKey, secretKey: secretKey)
        guard let data = Base64URL.decode(envelope.data) else { throw Failure.malformed }
        let json = try DriveFileCrypto.decrypt(Data(data), dek: dek)
        guard let payload = try? JSONDecoder().decode(Payload.self, from: json) else { throw Failure.malformed }
        return payload
    }

    private static func envelope(_ encrypted: String) throws -> Envelope {
        guard let data = encrypted.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformed
        }
        // Checked before decoding the rest: a later version may change the other fields.
        guard let v = object["v"] as? Int else { throw Failure.malformed }
        guard v == version else { throw Failure.unsupportedVersion(v) }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { throw Failure.malformed }
        return envelope
    }
}

private extension JSONEncoder {
    /// Sorted keys, so the same value always encodes the same way; the tests compare bytes.
    static var sortedKeys: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
