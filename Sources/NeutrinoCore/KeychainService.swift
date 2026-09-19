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
///
/// ## Two namespaces
///
/// Items are written in one of two `Scope`s, and the difference is not cosmetic:
///
///   `.app`     `<prefix>.<name>` in this app's own group. Sessions live here, and they stay
///              apart — signing into Docs must not sign anyone out of Drive.
///   `.shared`  the identity keyring, in a group every Neutrino app declares. The keypair belongs
///              to the *account*, not to the app, so six private copies of it on one device is six
///              chances to end up holding five.
///
/// Reads of `.app` items are unqualified by group on purpose (see `load`), which is what let the
/// extension group ship without a read-path migration and is what lets `.shared` work the same way.
public enum KeychainService {

    // MARK: - Scope

    /// Which namespace an item belongs to.
    ///
    /// `.app` is everything that existed before sharing: a `keychainPrefix`-qualified account name
    /// in the app's own group (or Drive's extension group), protected with that app's configured
    /// accessibility.
    ///
    /// `.shared` is the cross-app identity keyring — one account name, one group, one
    /// accessibility, visible to every Neutrino app on the device. It is a separate case rather
    /// than a different key string because the two differ in more than naming: a shared write must
    /// not fall back to the default group, and a shared delete reaches other apps.
    public enum Scope: Sendable {
        case app
        case shared
    }

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
    nonisolated(unsafe) private static var resolvedSharedGroup: String? = resolveSharedGroup()
    private static let lock = NSLock()

    /// The team prefix the Keychain expects in front of an access group, e.g. `"46KWJJ63FU"`.
    ///
    /// No API reports it, so it is read back off an item we write ourselves: an item added with no
    /// `kSecAttrAccessGroup` lands in the default group, and the default group's name is
    /// `<TeamID>.<bundle id>`. Everything before the first dot is the prefix.
    ///
    /// This is why the group strings in `NeutrinoAppConfig` are written bare. The entitlement
    /// spells them `$(AppIdentifierPrefix)com.neutrino.shared`; `SecItem` wants the expansion, and
    /// hardcoding a team id in source is how a repo stops building under a different account.
    private static func bundleSeedPrefix() -> String? {
        let identify: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: "app.getneutrino.keychain.seed-probe"
        ]

        var attributes = identify
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData] = Data([0])
        attributes[kSecReturnAttributes] = true

        var result: AnyObject?
        var status = SecItemAdd(attributes as CFDictionary, &result)
        if status == errSecDuplicateItem {
            var read = identify
            read[kSecReturnAttributes] = true
            read[kSecMatchLimit] = kSecMatchLimitOne
            status = SecItemCopyMatching(read as CFDictionary, &result)
        }
        SecItemDelete(identify as CFDictionary)

        guard status == errSecSuccess,
              let group = (result as? [CFString: Any])?[kSecAttrAccessGroup] as? String,
              let dot = group.firstIndex(of: ".")
        else { return nil }
        return String(group[..<dot])
    }

    /// Whether this binary can really write to `group`.
    ///
    /// A round trip rather than an inspection, because an entitlement can be present and still
    /// unusable — a provisioning profile that does not carry the group, a group registered for a
    /// different team. Finding that out lazily means finding it out on the one write that
    /// mattered, which for the keyring is the write that follows an import the user cannot repeat.
    private static func canWrite(to group: String) -> Bool {
        let identify: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: "app.getneutrino.keychain.group-probe",
            kSecAttrAccessGroup: group
        ]
        SecItemDelete(identify as CFDictionary)

        var add = identify
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData] = Data([0])

        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        SecItemDelete(identify as CFDictionary)
        return true
    }

    private static func resolveAccessGroup() -> String? {
        guard NeutrinoApp.isConfigured,
              let appGroup = NeutrinoApp.current.appGroupIdentifier,
              let keychainGroup = NeutrinoApp.current.keychainAccessGroup,
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil,
              let prefix = bundleSeedPrefix()
        else { return nil }

        // Previously returned unqualified. That worked only because Drive lists exactly one group,
        // which makes it Drive's *default* group — so even the entitlement-failure fallback landed
        // in the right place by accident. With a second group declared that coincidence is gone.
        let qualified = "\(prefix).\(keychainGroup)"
        return canWrite(to: qualified) ? qualified : nil
    }

    /// The cross-app group, or nil when this app has opted out or cannot use it.
    ///
    /// Deliberately independent of `appGroupIdentifier`: keychain sharing needs no App Group, and
    /// requiring one would mean registering a container that five of the six apps never open.
    private static func resolveSharedGroup() -> String? {
        guard NeutrinoApp.isConfigured,
              let sharedGroup = NeutrinoApp.current.sharedKeychainAccessGroup,
              let prefix = bundleSeedPrefix()
        else { return nil }
        let qualified = "\(prefix).\(sharedGroup)"
        return canWrite(to: qualified) ? qualified : nil
    }

    /// Exposed for diagnostics and tests. `nil` means "default group".
    public static var accessGroup: String? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedAccessGroup
    }

    /// The cross-app group, or nil when this app opted out or the entitlement is unusable.
    /// Exposed for diagnostics and tests.
    public static var sharedAccessGroup: String? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedSharedGroup
    }

    /// Whether the identity keyring can be shared with the other Neutrino apps on this device.
    ///
    /// The UI asks this before offering to adopt or publish a key, so a build whose entitlement is
    /// missing shows nothing rather than a button that fails.
    public static var sharesIdentityAcrossApps: Bool { sharedAccessGroup != nil }

    /// Re-probes the entitlements. Call after `NeutrinoApp.configure(_:)` if anything may have
    /// touched the Keychain first; the app's `init()` ordering normally makes this unnecessary.
    public static func reloadAccessGroup() {
        lock.lock()
        defer { lock.unlock() }
        resolvedAccessGroup = resolveAccessGroup()
        resolvedSharedGroup = resolveSharedGroup()
    }

    /// Give up on the app-to-extension group. Items fall back to the default group from here on —
    /// losing extension visibility, never losing the user's keys.
    ///
    /// Named for the group it disables: since the cross-app group arrived there are two, and they
    /// fail independently. This one does not touch `resolvedSharedGroup`.
    private static func disableExtensionAccessGroup() {
        lock.lock()
        defer { lock.unlock() }
        resolvedAccessGroup = nil
    }

    /// Give up on the cross-app group.
    ///
    /// Unlike the extension group there is no fallback, so this makes `sharesIdentityAcrossApps`
    /// report false and the sharing UI disappear — which is the honest answer for a build whose
    /// entitlement turns out to be unusable, and better than a button that fails every time.
    private static func disableSharedIdentityGroup() {
        lock.lock()
        defer { lock.unlock() }
        resolvedSharedGroup = nil
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
    /// With a group in effect the item is first deleted and then added, rather than updated in
    /// place: an item already in the default group would otherwise coexist with a group item under
    /// the same account, and `load` — which searches all groups — could return either.
    @discardableResult
    public static func save(_ value: String, forKey key: String, scope: Scope = .app) -> Bool {
        if let backend = activeBackend {
            return backend.save(value, forKey: backendKey(key, scope))
        }
        guard let data = value.data(using: .utf8) else { return false }

        switch scope {
        case .app:
            guard let group = accessGroup else {
                return saveInDefaultGroup(data, forKey: key)
            }
            // Sweep the unqualified account too: for a per-app key the account string is
            // prefix-namespaced, so this can only reach this app's own stale copy.
            var deleteQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: key
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            deleteQuery[kSecAttrAccessGroup] = group
            SecItemDelete(deleteQuery as CFDictionary)

            let status = addItem(data, forKey: key, group: group, accessible: accessible)
            if status == errSecSuccess { return true }

            if isEntitlementFailure(status) {
                disableExtensionAccessGroup()
                return saveInDefaultGroup(data, forKey: key)
            }
            return false

        case .shared:
            // No fallback to the default group, unlike `.app`. A keyring that quietly lands in one
            // app's private namespace is indistinguishable from a shared one when read back by the
            // app that wrote it; the breakage surfaces later, in a *different* app, as "my key
            // disappeared". Failing the write lets the caller say so while the user is still here.
            guard let group = sharedAccessGroup else { return false }

            // Only the qualified delete. The shared account name is identical in every app, so an
            // unqualified `SecItemDelete` from Notes would reach into the shared group and remove
            // Drive's item before adding its own.
            let deleteQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: NeutrinoAppConfig.sharedKeychainService,
                kSecAttrAccount: key,
                kSecAttrAccessGroup: group
            ]
            SecItemDelete(deleteQuery as CFDictionary)

            let status = addItem(data,
                                 forKey: key,
                                 group: group,
                                 accessible: NeutrinoAppConfig.sharedKeyringAccessibility,
                                 service: NeutrinoAppConfig.sharedKeychainService)
            if isEntitlementFailure(status) { disableSharedIdentityGroup() }
            return status == errSecSuccess
        }
    }

    private static func addItem(_ data: Data,
                                forKey key: String,
                                group: String,
                                accessible: CFString,
                                service: String? = nil) -> OSStatus {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrAccessGroup: group,
            kSecAttrAccessible: accessible,
            kSecValueData: data
        ]
        if let service { query[kSecAttrService] = service }
        return SecItemAdd(query as CFDictionary, nil)
    }

    /// Test backends are a flat dictionary with no notion of a group, so the scope has to travel
    /// in the key or a shared and a per-app item under the same name would alias.
    private static func backendKey(_ key: String, _ scope: Scope) -> String {
        switch scope {
        case .app: return key
        case .shared: return "\(NeutrinoAppConfig.sharedKeychainService)/\(key)"
        }
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
    public static func load(forKey key: String, scope: Scope = .app) -> String? {
        if let backend = activeBackend { return backend.load(forKey: backendKey(key, scope)) }
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        // `.shared` is still an unqualified-by-group search — the entitlement bounds it — but it is
        // qualified by service, so a per-app item can never answer a shared read.
        if case .shared = scope {
            query[kSecAttrService] = NeutrinoAppConfig.sharedKeychainService
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Every shared-keyring account name present on this device.
    ///
    /// Exists so an app can discover that a sibling already holds a key *before* it knows which
    /// account that key belongs to — on a cold launch there is no profile fetched yet, and asking
    /// the user to sign in to find out whether they need to sign in is the wrong order.
    ///
    /// Returns account strings, not user ids: the caller matches them against
    /// `NeutrinoAppConfig.sharedKeyringAccount(forUserID:)` rather than parsing them apart.
    public static func sharedAccounts() -> [String] {
        if activeBackend != nil { return [] }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: NeutrinoAppConfig.sharedKeychainService,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[CFString: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount] as? String }
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
    public static func accessibility(forKey key: String, scope: Scope = .app) -> String? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        if case .shared = scope {
            query[kSecAttrService] = NeutrinoAppConfig.sharedKeychainService
        }

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [CFString: Any] else { return nil }
        return attributes[kSecAttrAccessible] as? String
    }

    // MARK: - Delete

    /// Deletes the item from every accessible group. True if at least one was found.
    ///
    /// - Important: `.shared` removes the identity keyring for **every** Neutrino app on the
    ///   device, not just this one. Sign-out must pass `.app`; only an explicit "remove this
    ///   device's encryption key" belongs on the shared scope. The default is `.app` for exactly
    ///   this reason — the dangerous case is the one you have to name.
    @discardableResult
    public static func delete(forKey key: String, scope: Scope = .app) -> Bool {
        if let backend = activeBackend { return backend.delete(forKey: backendKey(key, scope)) }

        if case .shared = scope {
            guard let group = sharedAccessGroup else { return false }
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: NeutrinoAppConfig.sharedKeychainService,
                kSecAttrAccount: key,
                kSecAttrAccessGroup: group
            ]
            return SecItemDelete(query as CFDictionary) == errSecSuccess
        }

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
