import Foundation
import Sodium
import os.log
import NeutrinoCore

// MARK: - StoredKeyPair

/// One identity keypair, base64url, as stored on this device.
public struct StoredKeyPair: Codable, Equatable, Sendable {
    /// Matches `user_public_keys.version` on the server.
    public let version: Int
    public let publicKey: String
    public let privateKey: String

    public init(version: Int, publicKey: String, privateKey: String) {
        self.version = version
        self.publicKey = publicKey
        self.privateKey = privateKey
    }
}

// MARK: - SealedKeyCoding

/// base64 helpers over `Bytes`, for the libsodium call sites that want arrays rather than `Data`.
///
/// Thin wrapper over `Data.base64URLEncoded` in `NeutrinoCore` — same tolerance on the way in,
/// same unpadded base64url on the way out.
public enum SealedKeyCoding {

    private static let sodium = Sodium()

    public static func decode(_ string: String) -> Bytes? {
        guard let data = Data(base64URLEncoded: string) else { return nil }
        return Array(data)
    }

    public static func encode(_ bytes: Bytes) -> String? {
        sodium.utils.bin2base64(bytes, variant: .URLSAFE_NO_PADDING)
    }
}

// MARK: - KeyArchive

/// The identity keys this device holds that are **not** the active one.
///
/// One keypair is enough for an account that has never rotated and wrong for one that has: a
/// file's key ref names the version its DEK was sealed to (`file_key_refs.key_version`), and a
/// device holding only the newest key cannot open anything written before the rotation. The files
/// are still there; they simply never open, which is the worst way for this to fail.
///
/// The retired keys come from the account's key file — see `KeyFileService` — and land here. The
/// active key stays in the three items `KeyImportService` writes, so no other read path moved.
///
/// ## On storing secret keys as one JSON blob
///
/// One Keychain item rather than three per version: the set is read together, on the same
/// access-control terms, and the alternative is inventing a naming scheme and a separate index to
/// enumerate it. `KeychainService` applies `AfterFirstUnlockThisDeviceOnly`, so this is out of
/// device backups like the active key beside it.
public enum KeyArchive {

    /// The retired keys, as a JSON array. Sits beside `KeyImportService`'s three items and is
    /// cleared with them.
    public static var keychainKey: String { NeutrinoApp.current.archivedKeysKey }

    private static var logger: Logger {
        Logger(subsystem: NeutrinoApp.current.logSubsystem, category: "KeyArchive")
    }

    // MARK: - Reading

    /// Every retired key this device holds, ascending by version.
    ///
    /// An unreadable archive reads as empty rather than throwing: the active key still works, so
    /// the app degrades to what it could do before this existed instead of failing to open
    /// anything at all.
    public static func load() -> [StoredKeyPair] {
        guard let json = KeychainService.load(forKey: keychainKey),
              let data = json.data(using: .utf8) else { return [] }
        do {
            return try JSONDecoder().decode([StoredKeyPair].self, from: data)
                .sorted { $0.version < $1.version }
        } catch {
            logger.error("load: archive is unreadable: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// The archived keypair for `version`, or nil when this device lacks it.
    public static func keyPair(forVersion version: Int) -> StoredKeyPair? {
        load().first { $0.version == version }
    }

    // MARK: - Writing

    /// Replace the archive with `keys`, dropping duplicate versions.
    ///
    /// Replace rather than merge: the caller has just rebuilt the set from the account's key file,
    /// which is authoritative, and merging would make a key dropped there impossible to drop here.
    @discardableResult
    public static func store(_ keys: [StoredKeyPair]) -> Bool {
        var seen = Set<Int>()
        let unique = keys
            .sorted { $0.version < $1.version }
            .filter { seen.insert($0.version).inserted }

        guard !unique.isEmpty else {
            clear()
            return true
        }
        do {
            let data = try JSONEncoder().encode(unique)
            guard let json = String(data: data, encoding: .utf8) else { return false }
            let ok = KeychainService.save(json, forKey: keychainKey)
            logger.info("store: archived \(unique.count, privacy: .public) retired key(s)")
            return ok
        } catch {
            logger.error("store: encode failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public static func clear() {
        _ = KeychainService.delete(forKey: keychainKey)
    }
}
