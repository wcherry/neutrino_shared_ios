import Foundation
import Security

// MARK: - KeychainService

/// Thin wrapper over the generic-password Keychain, used for auth tokens and the E2EE identity.
///
/// This is Drive's implementation — the only one of the five that had grown App Group support —
/// generalized so the group comes from `NeutrinoApp.current` rather than from a Drive constant.
/// For the four apps that declare no App Group it behaves exactly like the simpler copies they
/// were running: `resolvedAccessGroup` is `nil` and every path falls through to the default group.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` on every item, deliberately:
/// *AfterFirstUnlock* so a background upload can still read a token on a locked device, and
/// *ThisDeviceOnly* so neither the refresh token nor the identity secret key is ever carried off
/// in an iCloud Keychain or encrypted-backup copy — an identity that rides along in a backup is an
/// identity whose safety rests on the backup's, which is the property E2EE exists to remove.
public enum KeychainService {

    // MARK: - Backend

    /// Where items actually go.
    ///
    /// Exists for one reason: a SwiftPM test bundle has no host app, so it carries no
    /// `application-identifier` entitlement and every `SecItemAdd` fails with
    /// `errSecMissingEntitlement`. The app targets that used to own this code ran their tests in an
    /// app host and never hit it.
    ///
    /// Rather than weaken the real path — a silent in-memory fallback in production would mean an
    /// access token that looked saved and vanished on relaunch — the substitution is explicit and
    /// only a test can ask for it.
    public protocol Backend: AnyObject {
        func save(_ value: String, forKey key: String) -> Bool
        func load(forKey key: String) -> String?
        func delete(forKey key: String) -> Bool
    }

    nonisolated(unsafe) private static var backend: Backend?

    /// Routes every operation to an in-memory store. Tests only.
    ///
    /// Returns the store so a test can inspect or seed it directly.
    @discardableResult
    public static func installInMemoryBackendForTesting() -> Backend {
        let store = InMemoryBackend()
        lock.lock()
        backend = store
        lock.unlock()
        return store
    }

    /// Restores the real Keychain.
    public static func removeTestingBackend() {
        lock.lock()
        backend = nil
        lock.unlock()
    }

    private static var activeBackend: Backend? {
        lock.lock()
        defer { lock.unlock() }
        return backend
    }

    /// A dictionary with the Keychain's interface. Not thread-hostile, but not concurrent either —
    /// which matches how tests drive it.
    private final class InMemoryBackend: Backend {
        private var items: [String: String] = [:]
        private let itemsLock = NSLock()

        func save(_ value: String, forKey key: String) -> Bool {
            itemsLock.lock()
            defer { itemsLock.unlock() }
            items[key] = value
            return true
        }

        func load(forKey key: String) -> String? {
            itemsLock.lock()
            defer { itemsLock.unlock() }
            return items[key]
        }

        func delete(forKey key: String) -> Bool {
            itemsLock.lock()
            defer { itemsLock.unlock() }
            return items.removeValue(forKey: key) != nil
        }
    }

    // MARK: - Shared access group

    /// The access group to write new items into, or `nil` for the app's default group.
    ///
    /// Resolved from a real entitlement probe rather than from the config alone:
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns `nil` unless the running
    /// bundle actually carries the App Group entitlement. The app and its extension both declare
    /// it; a unit-test bundle does not. So tests use the default group and behave as though the
    /// sharing code were not there, while app and extension share one group and can read each
    /// other's items.
    ///
    /// A `var`, not a `let`, because a call may still be refused with `errSecMissingEntitlement`
    /// (App Group present, `keychain-access-groups` missing or mismatched). It is then cleared
    /// permanently and every later call falls back to the default group — losing extension
    /// visibility, never losing the user's keys.
    nonisolated(unsafe) private static var resolvedAccessGroup: String? = resolveAccessGroup()
    private static let lock = NSLock()

    private static func resolveAccessGroup() -> String? {
        guard NeutrinoApp.isConfigured,
              let appGroup = NeutrinoApp.current.appGroupIdentifier,
              let keychainGroup = NeutrinoApp.current.keychainAccessGroup,
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil
        else { return nil }
        return keychainGroup
    }

    /// Exposed for diagnostics and tests. `nil` means "default group".
    public static var accessGroup: String? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedAccessGroup
    }

    /// Re-probes the entitlement. Call after `NeutrinoApp.configure(_:)` if anything may have
    /// touched the Keychain first; the app's `init()` ordering normally makes this unnecessary.
    public static func reloadAccessGroup() {
        lock.lock()
        defer { lock.unlock() }
        resolvedAccessGroup = resolveAccessGroup()
    }

    private static func disableSharedAccessGroup() {
        lock.lock()
        defer { lock.unlock() }
        resolvedAccessGroup = nil
    }

    /// `errSecMissingEntitlement` / `errSecNoAccessForItem` mean the group is not usable by this
    /// binary. Anything else is a real failure and must not silently widen access.
    private static func isEntitlementFailure(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement || status == errSecNoAccessForItem
    }

    // MARK: - Accessibility

    /// How every item this service writes is protected, for the running app.
    ///
    /// Public so a test can assert the promise rather than restating the constant, which would
    /// pass just as happily against the wrong one. See `NeutrinoAppConfig.keychainAccessibility`
    /// for why it is per-app.
    public static var accessibility: CFString { NeutrinoApp.current.keychainAccessibility }

    private static var accessible: CFString { accessibility }

    // MARK: - Save

    /// Saves or updates a string value. Returns true on success.
    ///
    /// With a shared group in effect the item is first deleted from *every* accessible group and
    /// then added into the shared one. Without that, an item already in the default group would
    /// coexist with a shared-group item under the same account, and `load` — which searches all
    /// groups — could return either.
    @discardableResult
    public static func save(_ value: String, forKey key: String) -> Bool {
        if let backend = activeBackend { return backend.save(value, forKey: key) }
        guard let data = value.data(using: .utf8) else { return false }

        guard let group = accessGroup else {
            return saveInDefaultGroup(data, forKey: key)
        }

        var deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        deleteQuery[kSecAttrAccessGroup] = group
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrAccessGroup: group,
            kSecAttrAccessible: accessible,
            kSecValueData: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess { return true }

        if isEntitlementFailure(status) {
            disableSharedAccessGroup()
            return saveInDefaultGroup(data, forKey: key)
        }
        return false
    }

    private static func saveInDefaultGroup(_ data: Data, forKey key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrAccessible: accessible,
            kSecValueData: data
        ]

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }

        if addStatus == errSecDuplicateItem {
            let searchQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: key
            ]
            // Accessibility is re-stated on update, not just the value: an item written by a
            // build that predates this would otherwise keep its old, backed-up protection.
            let updateAttributes: [CFString: Any] = [
                kSecAttrAccessible: accessible,
                kSecValueData: data
            ]
            return SecItemUpdate(searchQuery as CFDictionary,
                                 updateAttributes as CFDictionary) == errSecSuccess
        }

        return false
    }

    // MARK: - Load

    /// Loads a string value, or `nil` when absent.
    ///
    /// Deliberately queried **without** `kSecAttrAccessGroup`: an unqualified search spans every
    /// group in the caller's entitlement, so it finds items written before the shared group
    /// existed as well as after. That is why no read-path migration is needed.
    public static func load(forKey key: String) -> String? {
        if let backend = activeBackend { return backend.load(forKey: key) }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The accessibility attribute an item was actually stored with, or nil when there is no such
    /// item.
    ///
    /// Exists so a test can assert the promise this type makes — that nothing it writes leaves the
    /// device in a backup — rather than trusting that every write site remembered to pass it.
    /// Photos was the only app with this; the guarantee is the same in all five.
    ///
    /// Reads the real Keychain even when a testing backend is installed, since an in-memory store
    /// has no accessibility to report. It answers nil there rather than a misleading value.
    public static func accessibility(forKey key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [CFString: Any] else { return nil }
        return attributes[kSecAttrAccessible] as? String
    }

    // MARK: - Delete

    /// Deletes the item from every accessible group. True if at least one was found.
    @discardableResult
    public static func delete(forKey key: String) -> Bool {
        if let backend = activeBackend { return backend.delete(forKey: key) }
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key
        ]

        let status = SecItemDelete(query as CFDictionary)

        // An unqualified delete does not always reach items in a non-default group, so make a
        // second explicit pass when one is in effect.
        var deletedFromGroup = false
        if let group = accessGroup {
            query[kSecAttrAccessGroup] = group
            deletedFromGroup = SecItemDelete(query as CFDictionary) == errSecSuccess
        }

        return status == errSecSuccess || deletedFromGroup
    }

    // MARK: - Migration

    /// Relocates this app's known items into the shared access group, so a user who imported a
    /// key before the extension shipped does not have to re-import it.
    ///
    /// Idempotent and safe on every launch; a no-op when no shared group is in effect. Values
    /// that fail to reload are **not** deleted — `save` only removes the old copy once it holds
    /// the value in memory, so a failed add leaves the caller able to retry next launch.
    public static func migrateToSharedAccessGroupIfNeeded() {
        guard accessGroup != nil else { return }
        let config = NeutrinoApp.current
        let keys = [
            config.accessTokenKey,
            config.refreshTokenKey,
            config.publicKeyKey,
            config.privateKeyKey,
            config.keyVersionKey,
            config.archivedKeysKey,
        ]
        for key in keys {
            guard let value = load(forKey: key) else { continue }
            save(value, forKey: key)
        }
    }
}
