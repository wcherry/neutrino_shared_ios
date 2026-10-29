import Foundation
import os
import Security

// MARK: - Platform keychain

/// Every `SecItem` call `KeychainService` makes goes through here, and on iOS that is all this
/// does: the four wrappers call straight through, so the iOS apps run exactly the queries they did
/// before macOS was a platform.
///
/// macOS is different in one way that matters: it has **two** keychains. A query that does not ask
/// for the data-protection keychain gets the legacy file-based one, where access is keyed on a
/// per-item code-signing ACL rather than on the keychain-access-group entitlement. The Drive client
/// is three separately-signed binaries — the app, a `launchd` sync agent and a File Provider
/// extension — and on the legacy keychain the agent reading a session the app wrote is a different
/// binary that needs an interactive confirmation. A launchd agent cannot answer one, and `securityd`
/// does not fail that read, it *blocks* it: that hung the agent mid-startup and took the Finder
/// mount down with it. So on macOS every query asks for the data-protection keychain, which keys
/// access on the group all three binaries are signed into.
///
/// What happens to a process that is **not** entitled to it — an unsigned SwiftPM test host, or a
/// `make build` agent whose `keychain-access-groups` was stripped because nothing could embed the
/// profile that backs it: the data-protection keychain answers `errSecMissingEntitlement` (-34018)
/// to every call. A query naming an explicit group is handed back to `KeychainService`, which
/// already treats that as "this group is unusable" and falls back to the default group. A query
/// with no group means there is no data-protection keychain for this process at all, so the
/// process latches onto the legacy keychain for its lifetime — degraded (prompt-bound), but
/// working, which is the behaviour the macOS client had before it adopted this package.
///
/// This is the macOS client's own `KeychainService` (`neutrino_drive_mac_desktop`), folded in.
extension KeychainService {

    #if os(macOS)

    /// Latched once a group-less data-protection query reports a missing entitlement.
    /// `nonisolated(unsafe)` for the same reason as `backend`: a write-once process flag, guarded
    /// by `platformLock` for the read-modify-write.
    nonisolated(unsafe) private static var legacyOnly = false
    private static let platformLock = NSLock()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.getneutrino.shared",
        category: "Keychain"
    )

    /// True once this process has proved it cannot use the data-protection keychain.
    static var usesLegacyKeychain: Bool {
        platformLock.lock()
        defer { platformLock.unlock() }
        return legacyOnly
    }

    private static func withPlatformKeychain(_ query: [CFString: Any]) -> [CFString: Any] {
        guard !usesLegacyKeychain else { return query }
        var query = query
        query[kSecUseDataProtectionKeychain] = true
        return query
    }

    /// Runs `operation` against the data-protection keychain, falling back to the legacy one for
    /// the rest of the process when this binary has no data-protection keychain at all.
    private static func run(_ name: String,
                            _ query: [CFString: Any],
                            _ operation: ([CFString: Any]) -> OSStatus) -> OSStatus {
        let legacy = usesLegacyKeychain
        let status = operation(withPlatformKeychain(query))
        guard !legacy,
              status == errSecMissingEntitlement,
              query[kSecAttrAccessGroup] == nil
        else { return status }

        platformLock.lock()
        let firstTime = !legacyOnly
        legacyOnly = true
        platformLock.unlock()
        if firstTime {
            logger.error("""
                \(name, privacy: .public) returned errSecMissingEntitlement (-34018); this binary is \
                not signed with a keychain-access-group. Using the legacy keychain for this process.
                """)
        }
        return operation(query)
    }

    static func secItemAdd(_ query: [CFString: Any], _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        run("SecItemAdd", query) { SecItemAdd($0 as CFDictionary, result) }
    }

    static func secItemCopyMatching(_ query: [CFString: Any], _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let status = run("SecItemCopyMatching", query) { SecItemCopyMatching($0 as CFDictionary, result) }
        if status == errSecInteractionNotAllowed {
            // Only a process that refused keychain UI gets here — the sync agent (see
            // `refuseInteraction()`). The item exists in the legacy keychain and its ACL names a
            // different binary's signature. Logged loudly because the symptom otherwise looks like
            // a missing session, and the cause is signing configuration, not code.
            logger.error("""
                An item exists but this binary may not read it without a prompt \
                (errSecInteractionNotAllowed). Sharing between the app and the agent needs the \
                keychain-access-groups entitlement.
                """)
        }
        return status
    }

    static func secItemUpdate(_ query: [CFString: Any], _ attributes: [CFString: Any]) -> OSStatus {
        run("SecItemUpdate", query) { SecItemUpdate($0 as CFDictionary, attributes as CFDictionary) }
    }

    @discardableResult
    static func secItemDelete(_ query: [CFString: Any]) -> OSStatus {
        run("SecItemDelete", query) { SecItemDelete($0 as CFDictionary) }
    }

    // MARK: Legacy copies

    /// Carries an `.app` item written to the legacy keychain across into the data-protection one.
    ///
    /// A process that latched onto the legacy keychain (see above) wrote its items there; the next
    /// properly-signed build would otherwise find nothing and sign the user out. Best-effort: when
    /// the rewrite fails the legacy value is still returned, and the legacy copy is removed only
    /// once the new one is written.
    static func migrateLegacyItem(forKey key: String) -> String? {
        guard !usesLegacyKeychain else { return nil }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }

        if save(value, forKey: key) {
            deleteLegacyItem(forKey: key)
            logger.notice("Migrated \(key, privacy: .public) into the data-protection keychain")
        }
        return value
    }

    /// Removes the legacy-keychain copy of an `.app` item, if any. A secret deleted from one
    /// keychain and left in the other is worse than one never deleted at all.
    static func deleteLegacyItem(forKey key: String) {
        guard !usesLegacyKeychain else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Process policy

    /// Refuses keychain dialogs for the rest of this process's life.
    ///
    /// Call it once, first thing, in any process that has no way to show one — the sync agent; any
    /// future headless helper that reads a secret belongs here too. Not an app, which can and
    /// should prompt.
    ///
    /// Without it a legacy-keychain read does not fail, it **blocks**: `SecItemCopyMatching` sits
    /// in `securityd` waiting for a confirmation dialog nobody will see. With interaction refused
    /// the same read returns `errSecInteractionNotAllowed` at once and the caller degrades honestly.
    ///
    /// `SecKeychainSetUserInteractionAllowed` is deprecated along with the rest of the legacy
    /// keychain API, and has no data-protection replacement: `kSecUseAuthenticationUI` is per-query
    /// and does not govern legacy ACL prompts, which are exactly what block.
    public static func refuseInteraction() {
        let status = SecKeychainSetUserInteractionAllowed(false)
        if status == errSecSuccess {
            logger.notice("Keychain dialogs refused for this process")
        } else {
            logger.error("Could not refuse keychain dialogs for this process (code \(status))")
        }
    }

    #else

    static func secItemAdd(_ query: [CFString: Any], _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemAdd(query as CFDictionary, result)
    }

    static func secItemCopyMatching(_ query: [CFString: Any], _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, result)
    }

    static func secItemUpdate(_ query: [CFString: Any], _ attributes: [CFString: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    @discardableResult
    static func secItemDelete(_ query: [CFString: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }

    #endif
}
