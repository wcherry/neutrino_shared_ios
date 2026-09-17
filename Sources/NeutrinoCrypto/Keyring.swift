import Foundation
import CryptoKit
import NeutrinoCore

// MARK: - Keyring
//
// Every Curve25519 identity keypair this account has held, numbered.
//
// A single identity cannot be rotated: the moment it changes, every DEK on the server is sealed to
// a key nobody holds any more, and nothing on the key ref says which key it wanted. So the identity
// is a list, and `file_key_refs.key_version` names the entry a given DEK needs.
//
//   read   resolve the file's keyVersion against this keyring, open with that entry's secret key
//   write  seal to the *active* entry and record its version
//
// Content is never re-encrypted by a rotation — only the sealed DEK moves.
//
// ── Why this sits beside `KeyArchive` rather than replacing it ────────────────
//
// Two storage models for the same key material live in this package, because the apps are mid-
// migration and a package six of them rebuild against cannot flip underneath the five that have
// not moved:
//
//   split    `KeyImportService` holds the active keypair in three Keychain items and `KeyArchive`
//            holds the retired ones in a fourth. Drive is here.
//   keyring  this file: one item, every version, bound to an account. Notes is here.
//
// An app picks one. `KeyringStore.purgeLegacyItems()` is the one-way door between them, and it is
// opt-in for exactly that reason — see the warning on it.
//
// The wire format is shared with the web client, byte for byte: see
// `web/packages/e2e-crypto/src/keyring.ts`. Two properties are load-bearing and silently break
// cross-device transfer if they drift:
//
//   * entries carry the secret key only. The public half is *derived* on read, so a damaged payload
//     cannot produce a pair whose halves disagree and whose seals are quietly unopenable.
//   * `retiredAt` is null on exactly one entry. Deserialisation rejects anything else rather than
//     guessing which key is current.
//
// Nothing here is ever transmitted to the server. See
// `agent_docs/client-only-key-architecture.md` in the backend repo.

public struct KeyringEntry: Equatable, Sendable {
    /// 1-based, matching `user_public_keys.version` on the server.
    public let version: Int
    public let publicKey: [UInt8]
    public let secretKey: [UInt8]
    public let createdAt: String
    /// nil while this is the active entry.
    public let retiredAt: String?

    public var isActive: Bool { retiredAt == nil }

    public init(version: Int,
                publicKey: [UInt8],
                secretKey: [UInt8],
                createdAt: String,
                retiredAt: String?) {
        self.version = version
        self.publicKey = publicKey
        self.secretKey = secretKey
        self.createdAt = createdAt
        self.retiredAt = retiredAt
    }
}

public struct Keyring: Equatable, Sendable {
    public let userId: String
    /// Ascending by version. Exactly one entry has `retiredAt == nil`.
    public let entries: [KeyringEntry]

    public init(userId: String, entries: [KeyringEntry]) {
        self.userId = userId
        self.entries = entries
    }

    /// The entry new work is sealed to.
    public var active: KeyringEntry? {
        entries.first(where: { $0.isActive })
    }

    /// The entry a file's DEK was sealed to, or nil if this device lacks it.
    public func entry(forVersion version: Int) -> KeyringEntry? {
        entries.first(where: { $0.version == version })
    }
}

// MARK: - Errors

public enum KeyringError: LocalizedError, Equatable {
    case unrecognisedFormat
    case empty
    case badSecretKeyLength(version: Int)
    case duplicateVersions
    case notExactlyOneActive(count: Int)
    case wrongAccount
    case noKeyring
    case missingVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unrecognisedFormat:
            return "This is not a Neutrino key."
        case .empty:
            return "That key is empty."
        case .badSecretKeyLength(let version):
            return "Key version \(version) is damaged."
        case .duplicateVersions:
            return "That key has duplicate versions and cannot be used."
        case .notExactlyOneActive(let count):
            return count == 0
                ? "That key names no current version."
                : "That key names \(count) current versions; it should name exactly one."
        case .wrongAccount:
            return "That key belongs to a different account."
        case .noKeyring:
            return "This device has no encryption key. Restore your recovery kit or pair with a "
                 + "device that has it."
        case .missingVersion(let version):
            return "This file needs encryption key version \(version), which this device does not "
                 + "have. Restore your recovery kit or pair with a device that has it."
        }
    }
}

// MARK: - Wire format

/// What the recovery kit and the pairing QR carry. Field names are fixed by the web
/// implementation; do not rename them.
public struct SerializedKeyring: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let version: Int
        /// base64url secret key. No public half — it is derived on read.
        public let sk: String
        public let createdAt: String
        public let retiredAt: String?

        public init(version: Int, sk: String, createdAt: String, retiredAt: String?) {
            self.version = version
            self.sk = sk
            self.createdAt = createdAt
            self.retiredAt = retiredAt
        }
    }
    public let v: Int
    public let userId: String
    public let entries: [Entry]

    public init(v: Int, userId: String, entries: [Entry]) {
        self.v = v
        self.userId = userId
        self.entries = entries
    }
}

// MARK: - Coding

public enum KeyringCoder {

    public static let secretKeyBytes = 32
    private static let formatVersion = 1

    /// Derive the Curve25519 public key from a secret key.
    ///
    /// swift-sodium exposes no `scalarmult_base` wrapper and the apps depend on the `Sodium`
    /// product only, not `Clibsodium`. CryptoKit's X25519 performs the same multiplication.
    public static func publicKey(fromSecret secretKey: [UInt8]) -> [UInt8]? {
        guard let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(secretKey))
        else { return nil }
        return [UInt8](priv.publicKey.rawRepresentation)
    }

    public static func serialize(_ keyring: Keyring) -> SerializedKeyring {
        SerializedKeyring(
            v: formatVersion,
            userId: keyring.userId,
            entries: keyring.entries.map {
                SerializedKeyring.Entry(
                    version: $0.version,
                    sk: Base64URL.encode($0.secretKey),
                    createdAt: $0.createdAt,
                    retiredAt: $0.retiredAt
                )
            }
        )
    }

    /// Rebuild a keyring, validating as it goes.
    ///
    /// Everything this parses arrived off paper, a QR code or disk, so none of it is trusted: a
    /// wrong secret-key length, a duplicate version or a keyring with no current entry are rejected
    /// here rather than surfacing later as files that mysteriously will not open.
    public static func deserialize(_ payload: SerializedKeyring) throws -> Keyring {
        guard payload.v == formatVersion else { throw KeyringError.unrecognisedFormat }
        guard !payload.entries.isEmpty else { throw KeyringError.empty }

        var entries: [KeyringEntry] = []
        for entry in payload.entries {
            guard let secretKey = Base64URL.decode(entry.sk),
                  secretKey.count == secretKeyBytes,
                  let publicKey = publicKey(fromSecret: secretKey)
            else {
                throw KeyringError.badSecretKeyLength(version: entry.version)
            }
            entries.append(KeyringEntry(
                version: entry.version,
                publicKey: publicKey,
                secretKey: secretKey,
                createdAt: entry.createdAt,
                retiredAt: entry.retiredAt
            ))
        }

        entries.sort { $0.version < $1.version }

        guard Set(entries.map(\.version)).count == entries.count else {
            throw KeyringError.duplicateVersions
        }
        let activeCount = entries.filter(\.isActive).count
        guard activeCount == 1 else {
            throw KeyringError.notExactlyOneActive(count: activeCount)
        }

        return Keyring(userId: payload.userId, entries: entries)
    }

    /// JSON, as carried by the pairing QR. A plain coder on purpose — a snake-case-converting one
    /// would rewrite `userId` and `createdAt`.
    public static func encodeJSON(_ keyring: Keyring) throws -> Data {
        try JSONEncoder().encode(serialize(keyring))
    }

    public static func decodeJSON(_ data: Data) throws -> Keyring {
        let payload: SerializedKeyring
        do {
            payload = try JSONDecoder().decode(SerializedKeyring.self, from: data)
        } catch {
            throw KeyringError.unrecognisedFormat
        }
        return try deserialize(payload)
    }

    /// Adopt a bare keypair as a single-entry keyring.
    ///
    /// For the web app's mobile key code and for key files exported by a build that predates
    /// versioning. Minting a fresh identity instead would orphan everything already sealed to this
    /// one.
    ///
    /// `version` is the keyring version the key actually is, which the key code carries as
    /// `key_version` — **not** always 1. Pinning it to 1 would file a rotated account's v3 key
    /// under v1, and then every file written since the rotation would fail to open with "this file
    /// needs key version 3", while the key that opens it sat right there under the wrong number.
    /// The caller defaults to 1 only when nothing said otherwise.
    ///
    /// Retired versions do not arrive this way at all: they come from the account's key file, which
    /// `KeyFileService` merges in afterwards.
    public static func fromKeyPair(userId: String,
                                   publicKey: [UInt8],
                                   secretKey: [UInt8],
                                   version: Int = 1) -> Keyring {
        Keyring(userId: userId, entries: [
            KeyringEntry(
                version: max(1, version),
                publicKey: publicKey,
                secretKey: secretKey,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                retiredAt: nil
            )
        ])
    }
}

// MARK: - Base64URL

/// `[UInt8]`-shaped base64url, over `NeutrinoCore`'s `Data` conversions.
///
/// Reach for this one. `SealedKeyCoding` next door does the same job but returns an optional on the
/// way out, because it encodes through libsodium; that signature is load-bearing for its existing
/// callers in `KeyArchive` and `KeyFileService`, which thread the nil through, so it stays as it
/// is. The keyring's serialiser has no sensible answer for that nil — a keyring it cannot encode is
/// a keyring it cannot store — so it takes the `Data` path, which cannot fail.
public enum Base64URL {
    public static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64URLEncodedString
    }

    /// Accepts base64url and standard base64, padded or not — the server writes base64url, but
    /// exported key bundles use standard base64.
    public static func decode(_ string: String) -> [UInt8]? {
        guard let data = Data(base64URLEncoded: string) else { return nil }
        return [UInt8](data)
    }
}
