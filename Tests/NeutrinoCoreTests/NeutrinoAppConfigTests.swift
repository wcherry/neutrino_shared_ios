import XCTest
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
