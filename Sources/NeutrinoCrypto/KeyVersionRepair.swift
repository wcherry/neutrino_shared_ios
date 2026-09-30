import Foundation
import Sodium
import os.log
import NeutrinoCore

// MARK: - Why this file exists
//
// The key vault's `version` is the *envelope format* version (`user_key_vaults.version`, always 1),
// not the identity's key version. Every app that unlocked from the vault stored its key under that
// number, so on a rotated account the active v2 key was filed as "1" — and every file it then
// sealed was recorded on the server as v1. Nothing about those files is damaged: the DEK is sealed
// to a key the user holds, and the ref simply names the wrong one. The web client then reached for
// the retired v1 key and reported libsodium's "incorrect key pair for the given ciphertext".
//
// Two things follow, and both are here so the four vault apps cannot disagree about them:
//
//   * the version of a key is whatever the account's public-key directory says it is
//     (`PublishedKeyDirectory`) — never a number carried alongside some other payload;
//   * opening a sealed DEK tries every key this device holds when the named one will not open it
//     (`KeyImportService.openSealedDEK`), and reports which one did, so the caller can re-file the
//     ref and the next reader goes straight to the right key.

// MARK: - Opening a sealed DEK

/// Why a sealed DEK could not be opened. Mirrors `KeyLookup`'s split, plus the case it cannot see.
public enum SealedDEKError: Error, Equatable {
    /// This device holds no identity key at all.
    case noKey
    /// The ref names a version this device lacks, and nothing it does hold opens the seal either.
    case missingVersion(Int)
    /// The sealed key, or a stored key, is not valid base64.
    case malformed
    /// Every key this device holds was tried and none opens the seal.
    case notOpenable(namedVersion: Int)
}

/// A DEK, and the key version that actually opened it.
public struct OpenedDEK: Equatable {
    public let dek: Bytes
    /// The version whose key opened the seal.
    public let version: Int
    /// The version the key ref named.
    public let namedVersion: Int

    /// True when the ref names a version other than the one the DEK was sealed to — the ref should
    /// be re-filed under `version` (same sealed bytes, new number).
    public var isMisfiled: Bool { version != namedVersion }
}

extension KeyImportService {

    private static let sodium = Sodium()

    /// Every identity keypair this device holds — the active one and the retired ones beside it.
    public static func heldKeyPairs() -> [StoredKeyPair] {
        guard let active = storedKeys() else { return [] }
        let activeVersion = activeKeyVersion()
        let archived = KeyArchive.load().filter { $0.version != activeVersion }
        return [StoredKeyPair(version: activeVersion,
                              publicKey: active.publicKey,
                              privateKey: active.privateKey)] + archived
    }

    /// The order to try keys in for a ref naming `version`: that version first, then the rest
    /// newest first — a misfiled ref was sealed to whatever was active when it was written, which
    /// is far more often the current key than an old one.
    static func candidateOrder(_ keys: [StoredKeyPair], preferring version: Int) -> [StoredKeyPair] {
        keys.filter { $0.version == version }
            + keys.filter { $0.version != version }.sorted { $0.version > $1.version }
    }

    /// Opens a DEK sealed (`crypto_box_seal`) to one of this device's identity keys.
    ///
    /// Tries the version the ref names first, then every other key held. The result says which
    /// version opened it; when that is not the one named, the ref is misfiled and the caller should
    /// re-file it with `PUT /api/v1/drive/files/{id}/key`.
    public static func openSealedDEK(_ sealedBase64: String, keyVersion: Int) throws -> OpenedDEK {
        try openSealedDEK(sealedBase64, keyVersion: keyVersion, using: heldKeyPairs())
    }

    /// The same, over an explicit set of keys — the part worth testing without a Keychain.
    static func openSealedDEK(_ sealedBase64: String, keyVersion: Int,
                              using keys: [StoredKeyPair]) throws -> OpenedDEK {
        guard !keys.isEmpty else { throw SealedDEKError.noKey }
        guard let sealed = SealedKeyCoding.decode(sealedBase64) else { throw SealedDEKError.malformed }

        for key in candidateOrder(keys, preferring: keyVersion) {
            guard let publicKey = SealedKeyCoding.decode(key.publicKey),
                  let secretKey = SealedKeyCoding.decode(key.privateKey) else { continue }
            if let dek = sodium.box.open(anonymousCipherText: sealed,
                                         recipientPublicKey: publicKey,
                                         recipientSecretKey: secretKey) {
                return OpenedDEK(dek: dek, version: key.version, namedVersion: keyVersion)
            }
        }

        // Which failure to report depends on whether the named key was even here to try: "this
        // file needs key v2" is actionable, "nothing opens this" is not.
        if !keys.contains(where: { $0.version == keyVersion }) {
            throw SealedDEKError.missingVersion(keyVersion)
        }
        throw SealedDEKError.notOpenable(namedVersion: keyVersion)
    }

    /// Records `version` as the active key's version without touching the key itself.
    ///
    /// For repairing a device that stored its key under the vault's envelope version. Split-store
    /// only, like the rest of this type.
    public static func correctActiveKeyVersion(_ version: Int) {
        KeychainService.save(String(version), forKey: keyVersionKeychainKey)
    }
}

// MARK: - The directory's number for a key

/// Answers "which version is this public key?" from the account's published keyring
/// (`GET /api/v1/auth/users/{id}/public-keys`), the numbering `file_key_refs.key_version` uses.
///
/// Matched by key rather than by taking the active version, because the vault is not re-wrapped on
/// every rotation and can hold a key that has since been retired.
public enum PublishedKeyDirectory {

    private static var logger: Logger {
        Logger(subsystem: NeutrinoApp.current.logSubsystem, category: "PublishedKeyDirectory")
    }

    public struct Entry: Decodable, Equatable {
        public let version: Int
        public let publicKey: String

        public init(version: Int, publicKey: String) {
            self.version = version
            self.publicKey = publicKey
        }
    }

    private struct KeyRing: Decodable {
        let keys: [Entry]
    }

    /// The version `publicKey` is published under, or nil if the directory does not hold it.
    ///
    /// Compared as bytes: the vault serves base64url and a key file may carry standard base64.
    public static func version(of publicKey: String, in entries: [Entry]) -> Int? {
        guard let wanted = Data(base64URLEncoded: publicKey) else { return nil }
        return entries.first { Data(base64URLEncoded: $0.publicKey) == wanted }?.version
    }

    /// Fetches the caller's published keyring and looks `publicKey` up in it.
    public static func version(of publicKey: String, userID: String, baseURL: String,
                               token: String, session: URLSession = .shared) async throws -> Int? {
        guard let url = URL(string: baseURL + "/api/v1/auth/users/\(userID)/public-keys") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        // camelCase on the wire, like the other auth endpoints.
        let ring = try JSONDecoder().decode(KeyRing.self, from: data)
        let found = version(of: publicKey, in: ring.keys)
        if found == nil {
            logger.error("the account publishes no key matching this device's")
        }
        return found
    }
}
