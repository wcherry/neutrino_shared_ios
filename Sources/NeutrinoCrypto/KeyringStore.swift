import Foundation
import os
import NeutrinoCore
import NeutrinoAuth

// MARK: - KeyringStore
//
// This device's copy of the identity keyring, in the Keychain.
//
// Replaces `KeyVaultService`, which fetched a wrapped identity from the server and opened it with a
// password. There is no server copy any more — the key is created on a client and never transmitted
// — so the only ways a keyring arrives here are the recovery kit and the pairing handshake, and
// this is where it lands afterwards.
//
// One Keychain item holds the whole serialised keyring. Where that item lives depends on whether
// the app opted into `sharedKeychainAccessGroup`:
//
//   shared   `encryption.keyring.<userId>` in the cross-app group, under the shared service. Every
//            Neutrino app on the device reads the same item, so a key imported in Drive is a key
//            Notes already has. This is the path all six apps are on.
//   private  `<prefix>.encryption.keyring` in the app's own group, as before. An app that declines
//            the shared group's accessibility (see `NeutrinoAppConfig.sharedIdentityGroup`) lands
//            here, as does any build whose entitlement is missing.
//
// Sessions are *not* shared: the access token beside this is still `<prefix>.access_token`. Being
// signed into Drive has never meant being signed into Notes and this does not change that. What is
// shared is the account's identity keypair, which is not a property of any one app.
//
// Protection is the Keychain's own: `KeychainService` applies the app's configured accessibility,
// so the keyring is readable on the same terms as the access token beside it and is excluded from
// backups. An app's separate passcode/biometric gate guards the UI, not this.

@MainActor
public final class KeyringStore {

    public static let shared = KeyringStore()

    private let logger: Logger

    /// The private, per-app item. Still the fallback, and still what an app that declined the
    /// shared group writes.
    public static var keyringKeychainKey: String { NeutrinoApp.current.keyringKey }

    /// Whether this build writes the shared item.
    public static var isShared: Bool { KeychainService.sharesIdentityAcrossApps }

    /// The account whose keyring this store reads and writes.
    ///
    /// Nil until the app knows who is signed in. The shared item is keyed by user id because
    /// co-installed apps can be signed into different accounts, and an unbound store must not
    /// guess — see `load()` for the one case where it is allowed to.
    public private(set) var boundUserID: String?

    /// Point the store at an account explicitly.
    ///
    /// Rarely needed — `effectiveUserID` reads the signed-in account off the access token — but a
    /// caller holding a keyring before its session exists needs to say which account it is for.
    ///
    /// Drops the cache: the bound account is what the cached keyring was read for, so keeping it
    /// across a change would serve the previous user's key to the next one.
    public func bind(userID: String?) {
        guard userID != boundUserID else { return }
        boundUserID = userID
        cached = nil
    }

    /// The account this store acts on: whatever was bound, else whoever is signed in.
    ///
    /// The token fallback is what keeps binding from being a correctness requirement. An unbound
    /// store that silently addressed no account would make every shared read miss and every
    /// removal a no-op — failures that look like "the key vanished" rather than like a missing
    /// call, and that is too sharp an edge for something six apps call.
    private var effectiveUserID: String? { boundUserID ?? AccessToken.currentUserID() }

    private var sharedAccount: String? {
        guard Self.isShared, let id = effectiveUserID else { return nil }
        return NeutrinoAppConfig.sharedKeyringAccount(forUserID: id)
    }

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
    ///
    /// Reads the shared item first and the private one second. Both can exist — an app that held a
    /// private keyring before this shipped still has it — and the shared one wins because that is
    /// the copy the other apps are also reading.
    public func load() -> Keyring? {
        if let cached { return cached }

        if let account = sharedAccount,
           let keyring = decode(KeychainService.load(forKey: account, scope: .shared),
                                source: "shared") {
            // The account name carries the user id, but the payload carries it too, and only the
            // payload is the thing the key was actually sealed for. Checking both is what stops a
            // renamed or hand-edited item handing this app someone else's identity.
            //
            // A mismatch falls through to the private item rather than answering nil: this app's
            // own keyring is unambiguously this app's, and refusing to read it because a shared
            // item is wrong would turn one bad item into an app that cannot open anything.
            if keyring.userId == effectiveUserID {
                cached = keyring
                return keyring
            }
            logger.error("load: shared keyring is for another account; ignoring it")
        }

        if let keyring = decode(KeychainService.load(forKey: Self.keyringKeychainKey),
                                source: "private") {
            cached = keyring
            return keyring
        }
        return nil
    }

    private func decode(_ json: String?, source: String) -> Keyring? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        do {
            return try KeyringCoder.decodeJSON(data)
        } catch {
            // A keyring that will not parse is not recoverable by retrying, and treating it as
            // absent is what routes the user to restore it.
            logger.error("load: \(source, privacy: .public) keyring is unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Whether another Neutrino app on this device already holds a key for `userID`.
    ///
    /// Answers without unlocking or decoding anything, so a sign-in screen can offer "use the key
    /// already on this device" before it has a keyring to show.
    public static func sharedKeyringExists(forUserID userID: String) -> Bool {
        guard isShared else { return false }
        return KeychainService.sharedAccounts()
            .contains(NeutrinoAppConfig.sharedKeyringAccount(forUserID: userID))
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

    /// Store `keyring`, merging it with whatever this device already held for that account.
    ///
    /// Merging rather than replacing, because the shared item is written by six apps: Docs
    /// importing a recovery kit that carries versions 1-2 must not discard the version 3 Drive
    /// obtained by pairing an hour earlier. See `merge(_:with:)` for the rules.
    ///
    /// Binds the store to the keyring's account if nothing has yet, so the common path —
    /// restore a kit, then use the key — needs no separate `bind(userID:)` call.
    @discardableResult
    public func store(_ keyring: Keyring) -> Bool {
        if effectiveUserID == nil { bind(userID: keyring.userId) }
        guard keyring.userId == effectiveUserID else {
            logger.error("store: refusing a keyring for a different account")
            return false
        }

        let merged: Keyring
        if let existing = load(), existing.userId == keyring.userId {
            guard let result = Self.merge(existing, with: keyring) else {
                logger.error("store: keyrings disagree on a key version; refusing to merge")
                return false
            }
            merged = result
        } else {
            merged = keyring
        }

        do {
            let data = try KeyringCoder.encodeJSON(merged)
            guard let json = String(data: data, encoding: .utf8) else { return false }

            let ok: Bool
            if let account = sharedAccount {
                ok = KeychainService.save(json, forKey: account, scope: .shared)
                if !ok {
                    // Deliberately not falling back to the private item. It would look identical
                    // from inside this app and leave the other five without the key, which is the
                    // failure this whole change exists to remove — better a visible error now.
                    logger.error("store: shared keyring write failed")
                }
            } else {
                ok = KeychainService.save(json, forKey: Self.keyringKeychainKey)
            }

            if ok { cached = merged }
            logger.info("store: keyring saved, shared=\(self.sharedAccount != nil, privacy: .public), versions=\(merged.entries.count, privacy: .public)")
            return ok
        } catch {
            logger.error("store: encode failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Union two copies of one account's keyring.
    ///
    /// Returns nil when they disagree — same version, different secret key. That is two different
    /// identities claiming one version number, and there is no safe automatic answer: picking
    /// either silently orphans every file sealed to the other. The caller surfaces it.
    ///
    /// The active entry is the highest version present; everything below it is retired. This is
    /// what keeps the result decodable, since `KeyringCoder` rejects a keyring that does not name
    /// exactly one current version, and a plain concatenation of two keyrings usually names two.
    nonisolated static func merge(_ a: Keyring, with b: Keyring) -> Keyring? {
        var byVersion: [Int: KeyringEntry] = [:]
        for entry in a.entries + b.entries {
            if let existing = byVersion[entry.version] {
                guard existing.secretKey == entry.secretKey else { return nil }
                // Keep the earlier `createdAt`; the copies are the same key either way.
                byVersion[entry.version] = existing.createdAt <= entry.createdAt ? existing : entry
            } else {
                byVersion[entry.version] = entry
            }
        }

        let ordered = byVersion.values.sorted { $0.version < $1.version }
        guard let newest = ordered.last else { return nil }
        let retiredAt = ISO8601DateFormatter().string(from: Date())

        let entries = ordered.map { entry -> KeyringEntry in
            let isNewest = entry.version == newest.version
            // A version that was retired in either copy stays retired, and keeps the timestamp it
            // came with rather than being restamped as if it had just happened.
            let retirement = isNewest ? nil : (entry.retiredAt ?? retiredAt)
            guard entry.retiredAt != retirement else { return entry }
            return KeyringEntry(version: entry.version,
                                publicKey: entry.publicKey,
                                secretKey: entry.secretKey,
                                createdAt: entry.createdAt,
                                retiredAt: retirement)
        }
        return Keyring(userId: a.userId, entries: entries)
    }

    // MARK: - Adoption

    public enum Adoption: Equatable {
        /// A sibling app's key is now this app's key too.
        case adopted(versions: Int)
        /// Nothing to adopt: no shared keyring for this account on this device.
        case noneAvailable
        /// This app holds a private keyring and a shared one exists that contradicts it.
        case conflict
        /// This build does not share (opted out, or the entitlement is unusable).
        case unsupported
    }

    /// Take up the key a sibling app already holds, folding in anything private this app had.
    ///
    /// Idempotent, and cheap when there is nothing to do, so it is safe on every launch after
    /// sign-in. It does not prompt — the calling app decides whether adopting silently is right for
    /// it, and the shipped screens ask first.
    @discardableResult
    public func adoptSharedKeyring(forUserID userID: String) -> Adoption {
        guard Self.isShared else { return .unsupported }
        bind(userID: userID)

        let privateKeyring = decode(KeychainService.load(forKey: Self.keyringKeychainKey),
                                    source: "private")
        guard let account = sharedAccount,
              let shared = decode(KeychainService.load(forKey: account, scope: .shared),
                                  source: "shared"),
              shared.userId == userID
        else {
            // Nothing shared yet. If this app has a key, it becomes the one the others adopt.
            if let privateKeyring, privateKeyring.userId == userID {
                cached = nil
                return store(privateKeyring) ? .adopted(versions: privateKeyring.entries.count)
                                             : .noneAvailable
            }
            return .noneAvailable
        }

        guard let privateKeyring, privateKeyring.userId == userID else {
            cached = shared
            return .adopted(versions: shared.entries.count)
        }

        guard let merged = Self.merge(shared, with: privateKeyring) else { return .conflict }
        cached = nil
        return store(merged) ? .adopted(versions: merged.entries.count) : .conflict
    }

    // MARK: - Clearing

    /// Forget only this app's private copy, leaving the shared keyring in place.
    ///
    /// Narrow on purpose, and almost never what a caller wants: the remaining shared item means
    /// `load()` still answers, so this does not make the app keyless. It exists for clearing the
    /// pre-sharing item specifically. "Remove this device's encryption key" is
    /// `removeKeyringEverywhere()`.
    ///
    /// Note that signing out does not call either one — `AuthService.logout()` deletes tokens and
    /// nothing else, deliberately, so that signing back in does not require the recovery kit.
    public func clear() {
        KeychainService.delete(forKey: Self.keyringKeychainKey)
        cached = nil
        boundUserID = nil
        logger.info("clear: private keyring removed from this app")
    }

    /// Remove the account's key from **every** Neutrino app on this device.
    ///
    /// What the "Remove Keys" button means. The keyring then survives only where else it is held —
    /// another paired device, or the printed recovery kit. There is no server copy to fall back on,
    /// so only an explicit user action should reach this.
    ///
    /// Removes the private item whether or not the shared one could be addressed: a partial
    /// removal that leaves a key behind is the one outcome this must not produce, since the user
    /// was told the key is gone.
    @discardableResult
    public func removeKeyringEverywhere() -> Bool {
        var removed = false
        if let account = sharedAccount {
            removed = KeychainService.delete(forKey: account, scope: .shared)
        }
        removed = KeychainService.delete(forKey: Self.keyringKeychainKey) || removed
        cached = nil
        boundUserID = nil
        logger.info("removeKeyringEverywhere: removed=\(removed, privacy: .public)")
        return removed
    }
}
