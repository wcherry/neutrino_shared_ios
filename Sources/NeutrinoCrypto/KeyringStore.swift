import Foundation
import os
import NeutrinoCore

// MARK: - KeyringStore
//
// This device's copy of the identity keyring, in the Keychain.
//
// Replaces `KeyVaultService`, which fetched a wrapped identity from the server and opened it with a
// password. There is no server copy any more — the key is created on a client and never transmitted
// — so the only ways a keyring arrives here are the recovery kit and the pairing handshake, and
// this is where it lands afterwards.
//
// One Keychain item holds the whole serialised keyring, under `<prefix>.encryption.keyring`. The
// prefix is the app's own (`nn`, `nd`, `ndoc`, …), so co-installed apps keep separate keyrings
// exactly as they keep separate sessions.
//
// Protection is the Keychain's own: `KeychainService` applies the app's configured accessibility,
// so the keyring is readable on the same terms as the access token beside it and is excluded from
// backups. An app's separate passcode/biometric gate guards the UI, not this.

@MainActor
public final class KeyringStore {

    public static let shared = KeyringStore()

    private let logger: Logger

    /// The serialised keyring. One item, not one per key version.
    public static var keyringKeychainKey: String { NeutrinoApp.current.keyringKey }

    /// The three items the split-store model writes (`KeyImportService` plus `KeyArchive`).
    private static var splitStoreKeys: [String] {
        [NeutrinoApp.current.publicKeyKey,
         NeutrinoApp.current.privateKeyKey,
         NeutrinoApp.current.keyVersionKey]
    }

    private static var purgeFlagKey: String { NeutrinoApp.current.key("encryption.legacyPurged.v1") }

    /// Cached so the common read path — every file decrypt — does not hit the Keychain and
    /// re-derive public keys each time.
    private var cached: Keyring?

    private init() {
        self.logger = Logger(subsystem: NeutrinoApp.current.logSubsystem, category: "KeyringStore")
    }

    // MARK: - Legacy purge

    /// Remove the split-store Keychain items. Idempotent; runs once per install.
    ///
    /// **Opt-in, and a one-way door.** These are the items `KeyImportService.storeKeys(_:)` and
    /// every split-store read path use, so an app that has not moved to the keyring model must
    /// never call this — it would delete its working key. Call it only from an app whose reads all
    /// go through this store.
    ///
    /// Notes calls it because the keys those items held open files that no longer exist after the
    /// server-side wipe, and a stale private key surviving into the new scheme is worse than an
    /// empty Keychain, which at least routes the user through enrolment.
    public func purgeLegacyItems() {
        guard !UserDefaults.standard.bool(forKey: Self.purgeFlagKey) else { return }
        for key in Self.splitStoreKeys {
            KeychainService.delete(forKey: key)
        }
        UserDefaults.standard.set(true, forKey: Self.purgeFlagKey)
        logger.info("purgeLegacyItems: removed pre-keyring Keychain entries")
    }

    // MARK: - Reading

    /// The stored keyring, or nil when this device holds none.
    public func load() -> Keyring? {
        if let cached { return cached }
        guard let json = KeychainService.load(forKey: Self.keyringKeychainKey),
              let data = json.data(using: .utf8)
        else { return nil }
        do {
            let keyring = try KeyringCoder.decodeJSON(data)
            cached = keyring
            return keyring
        } catch {
            // A keyring that will not parse is not recoverable by retrying, and treating it as
            // absent is what routes the user to restore it.
            logger.error("load: stored keyring is unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public var hasKeyring: Bool { load() != nil }

    /// The keypair new work is sealed to.
    public func activeKeyPair() -> (publicKey: [UInt8], secretKey: [UInt8], version: Int)? {
        guard let entry = load()?.active else { return nil }
        return (entry.publicKey, entry.secretKey, entry.version)
    }

    /// The keypair that opens a DEK sealed to `version`.
    ///
    /// Throws rather than returning nil so the caller reports which key is missing — "this file
    /// needs version 2" is actionable, an unexplained decrypt failure is not.
    public func keyPair(forVersion version: Int) throws -> (publicKey: [UInt8], secretKey: [UInt8]) {
        guard let keyring = load() else { throw KeyringError.noKeyring }
        guard let entry = keyring.entry(forVersion: version) else {
            throw KeyringError.missingVersion(version)
        }
        return (entry.publicKey, entry.secretKey)
    }

    // MARK: - Writing

    /// Store `keyring`, replacing whatever this device held.
    @discardableResult
    public func store(_ keyring: Keyring) -> Bool {
        do {
            let data = try KeyringCoder.encodeJSON(keyring)
            guard let json = String(data: data, encoding: .utf8) else { return false }
            let ok = KeychainService.save(json, forKey: Self.keyringKeychainKey)
            if ok { cached = keyring }
            logger.info("store: keyring saved, versions=\(keyring.entries.count, privacy: .public)")
            return ok
        } catch {
            logger.error("store: encode failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Forget this device's copy.
    ///
    /// The keyring survives only where else it is held — another paired device, or the printed
    /// recovery kit. There is no server copy to fall back on.
    public func clear() {
        KeychainService.delete(forKey: Self.keyringKeychainKey)
        cached = nil
        logger.info("clear: keyring removed from this device")
    }
}
