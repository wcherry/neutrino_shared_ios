import Foundation
import CryptoKit
import XCTest
import NeutrinoCore
import NeutrinoAuth
@testable import NeutrinoCrypto

// MARK: - StoredTestKeys

/// An identity keypair in the Keychain, where `KeyImportService` reads it from.
///
/// Named apart from `TestKeys` in `KeyLifecycleTests`, which builds bundles without storing them:
/// these tests care about what a device *holds*, and conflating "generated" with "installed" is how
/// a provisioning test passes against a device that has no key at all.
enum StoredTestKeys {

    @discardableResult
    static func install(version: Int = 1) -> KeyBundle {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let bundle = KeyBundle(publicKey: base64URL(priv.publicKey.rawRepresentation),
                               privateKey: base64URL(priv.rawRepresentation),
                               keyVersion: String(version))
        KeyImportService.storeKeys(bundle)
        return bundle
    }

    static func remove() {
        KeyImportService.removeKeys()
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - TestTokens

/// Puts an access token in the Keychain so services believe they are signed in.
enum TestTokens {

    /// Decodes to `{"alg":"none","typ":"JWT"}.{"sub":"test-user-id"}.` — a real (if unsigned) JWT
    /// shape rather than an opaque string, because `AccessToken.currentUserID()` reads the `sub`
    /// claim and `KeyProvisioningService` addresses the key directory with it.
    static let userId = "test-user-id"
    static let defaultAccessToken =
        "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJ0ZXN0LXVzZXItaWQifQ."

    static func install(accessToken: String = TestTokens.defaultAccessToken) {
        KeychainService.save(accessToken, forKey: AuthService.accessTokenKey)
        // Far-future expiry so `refreshTokenIfNeeded` short-circuits and no test accidentally
        // depends on a refresh round trip it did not stub.
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        KeychainService.save(expiry, forKey: AuthService.tokenExpiryKey)
    }

    static func remove() {
        KeychainService.delete(forKey: AuthService.accessTokenKey)
        KeychainService.delete(forKey: AuthService.refreshTokenKey)
        KeychainService.delete(forKey: AuthService.tokenExpiryKey)
    }
}

// MARK: - TestServer

/// Points the package at a fixed host so assertions on request URLs are stable.
enum TestServer {
    static let host = "https://test.neutrino.local"

    static func use() {
        UserDefaults.standard.set(host, forKey: AuthService.serverHostKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: AuthService.serverHostKey)
    }
}
