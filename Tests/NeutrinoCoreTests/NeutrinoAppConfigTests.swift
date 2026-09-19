import XCTest
import Security
@testable import NeutrinoCore

// MARK: - NeutrinoAppConfigTests

/// The namespacing contract, which is the whole reason this config exists.
///
/// A device can have all five apps installed. If two of them derive the same Keychain account
/// string, signing into one signs the other out — and the symptom is "the app randomly logs me
/// out", which is nearly impossible to trace back to a shared constant. These tests pin the key
/// shapes against the strings the shipped apps already wrote, so a migrated app reads its own
/// existing session rather than starting cold.
final class NeutrinoAppConfigTests: XCTestCase {

    // MARK: - Key derivation

    func testKeysUsePrefixAndMatchTheShippedStrings() {
        let drive = NeutrinoAppConfig.drive
        XCTAssertEqual(drive.accessTokenKey,  "nd.access_token")
        XCTAssertEqual(drive.refreshTokenKey, "nd.refresh_token")
        XCTAssertEqual(drive.tokenExpiryKey,  "nd.token_expiry")
        XCTAssertEqual(drive.serverHostKey,   "nd.server_host")
        XCTAssertEqual(drive.publicKeyKey,    "nd.encryption.public_key")
        XCTAssertEqual(drive.privateKeyKey,   "nd.encryption.private_key")
        XCTAssertEqual(drive.keyVersionKey,   "nd.encryption.key_version")
        XCTAssertEqual(drive.archivedKeysKey, "nd.encryption.archived_keys")

        // Docs shipped `ndoc.*`; the migration must not silently renamespace it.
        XCTAssertEqual(NeutrinoAppConfig.docs.accessTokenKey, "ndoc.access_token")
        XCTAssertEqual(NeutrinoAppConfig.docs.deviceNameKey,  "ndoc.device_name")
    }

    /// The property this whole design is for: no two apps may collide on any key.
    func testNoTwoAppsShareAKey() {
        let configs = NeutrinoAppConfig.allApps
        var seen: [String: String] = [:]

        for config in configs {
            let keys = [
                config.accessTokenKey, config.refreshTokenKey, config.tokenExpiryKey,
                config.serverHostKey, config.deviceNameKey, config.publicKeyKey,
                config.privateKeyKey, config.keyVersionKey, config.archivedKeysKey,
            ]
            for key in keys {
                if let owner = seen[key] {
                    XCTFail("\(config.slug) and \(owner) both write Keychain key \(key)")
                }
                seen[key] = config.slug
            }
        }
    }

    func testPrefixesAreDistinct() {
        let prefixes = NeutrinoAppConfig.allApps.map(\.keychainPrefix)
        XCTAssertEqual(Set(prefixes).count, prefixes.count, "two apps share a Keychain prefix")
    }

    func testClientIDsAreDistinct() {
        let ids = NeutrinoAppConfig.allApps.map(\.oauthClientID)
        XCTAssertEqual(Set(ids).count, ids.count, "two apps share an OAuth client id")
    }

    // MARK: - Installation

    func testCurrentReturnsTheInstalledConfig() {
        NeutrinoApp.configure(NeutrinoAppConfig.sheets)
        XCTAssertEqual(NeutrinoApp.current.slug, "sheets")
        XCTAssertTrue(NeutrinoApp.isConfigured)

        NeutrinoApp.configure(NeutrinoAppConfig.photos)
        XCTAssertEqual(NeutrinoApp.current.slug, "photos")
    }

    // MARK: - Shared identity group

    /// The point of the group: all six name it identically. Two apps naming *almost* the same
    /// group is a device where four apps share a key and two silently do not, which reads as a bug
    /// in the two rather than in the constant.
    func testEveryAppDeclaresTheSameSharedIdentityGroup() {
        let groups = NeutrinoAppConfig.allApps.map(\.sharedKeychainAccessGroup)
        XCTAssertEqual(Set(groups.compactMap { $0 }).count, 1,
                       "the apps disagree about the shared identity group")
        XCTAssertEqual(groups.compactMap { $0 }.count, NeutrinoAppConfig.allApps.count,
                       "an app is missing the shared identity group")
    }

    /// Drive is in two groups, and they must stay two: the extension group carries its tokens, the
    /// shared group carries the keyring. Collapsing them would put five apps' tokens in a container
    /// only Drive's extension should read.
    func testDriveKeepsItsExtensionGroupSeparateFromTheSharedOne() {
        XCTAssertNotEqual(NeutrinoAppConfig.drive.keychainAccessGroup,
                          NeutrinoAppConfig.drive.sharedKeychainAccessGroup)
    }

    /// The shared item is per-account, which is what keeps two co-installed apps signed into
    /// different accounts from reading each other's identity.
    func testSharedKeyringAccountIsPerUser() {
        XCTAssertNotEqual(NeutrinoAppConfig.sharedKeyringAccount(forUserID: "user-1"),
                          NeutrinoAppConfig.sharedKeyringAccount(forUserID: "user-2"))
    }

    /// Sharing the keyring must not share sessions. The per-app prefix is what keeps them apart,
    /// and the shared account name must not carry one.
    func testSharedKeyringAccountIsNotAppNamespaced() {
        let account = NeutrinoAppConfig.sharedKeyringAccount(forUserID: "user-1")
        for config in NeutrinoAppConfig.allApps {
            XCTAssertFalse(account.hasPrefix("\(config.keychainPrefix)."),
                           "the shared account carries \(config.slug)'s prefix")
        }
    }

    /// `AfterFirstUnlock`, not Notes' stricter `WhenUnlocked` — one item has one accessibility and
    /// Drive's share extension reads it on a locked device. `ThisDeviceOnly` is the half that is
    /// never negotiable, so pin that explicitly.
    func testSharedKeyringStaysOutOfBackups() {
        XCTAssertEqual(NeutrinoAppConfig.sharedKeyringAccessibility,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    // MARK: - App Group

    /// Only Drive declares one. The other four must resolve to no group at all rather than to a
    /// shared default, which would put five apps' tokens in one container.
    func testOnlyDriveDeclaresAnAppGroup() {
        XCTAssertNotNil(NeutrinoAppConfig.drive.appGroupIdentifier)
        XCTAssertNotNil(NeutrinoAppConfig.drive.keychainAccessGroup)

        for config in NeutrinoAppConfig.allApps where config.slug != "drive" {
            XCTAssertNil(config.appGroupIdentifier, "\(config.slug) unexpectedly declares an App Group")
        }
    }
}
