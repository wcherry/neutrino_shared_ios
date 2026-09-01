import XCTest
import CryptoKit
import Sodium
import NeutrinoCore
@testable import NeutrinoCrypto

// MARK: - Test keys

/// Real X25519 material, deliberately not mocked.
///
/// `crypto_box_seal` round trips are the part of this codebase most expensive to get subtly wrong,
/// and a fake that always "decrypts" would assert nothing about them. libsodium's `crypto_box` uses
/// X25519 keys, which is exactly what `Curve25519.KeyAgreement` produces, so a CryptoKit-generated
/// pair is interchangeable with the one the web app exports.
enum TestKeys {

    static func generate(version: Int = 1) -> (bundle: KeyBundle, raw: Curve25519.KeyAgreement.PrivateKey) {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let bundle = KeyBundle(publicKey: base64URL(priv.publicKey.rawRepresentation),
                               privateKey: base64URL(priv.rawRepresentation),
                               keyVersion: String(version))
        return (bundle, priv)
    }

    static func keyFileJSON(_ bundle: KeyBundle) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "public_key": bundle.publicKey,
            "private_key": bundle.privateKey,
            "key_version": bundle.keyVersion,
        ])
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - KeyImportServiceTests

final class KeyImportServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        KeychainService.installInMemoryBackendForTesting()
        NeutrinoApp.configure(.docs)
        KeyImportService.removeKeys()
    }

    override func tearDown() {
        KeyImportService.removeKeys()
        KeychainService.removeTestingBackend()
        super.tearDown()
    }

    // MARK: - Parsing

    func testImportsTheWebAppsExportFormat() throws {
        let (bundle, _) = TestKeys.generate(version: 3)
        let imported = try KeyImportService.importKey(from: TestKeys.keyFileJSON(bundle))

        XCTAssertEqual(imported.publicKey, bundle.publicKey)
        XCTAssertEqual(imported.privateKey, bundle.privateKey)
        XCTAssertEqual(imported.keyVersion, "3")
    }

    /// The web app has used both spellings; a key file from either vintage must import.
    func testAcceptsTheShortFieldSpellings() throws {
        let (bundle, _) = TestKeys.generate()
        let json = try! JSONSerialization.data(withJSONObject: [
            "pk": bundle.publicKey, "sk": bundle.privateKey, "v": "2",
        ])
        let imported = try KeyImportService.importKey(from: json)
        XCTAssertEqual(imported.keyVersion, "2")
    }

    /// A key stored before the version field meant anything is version 1 — which is also what the
    /// server defaults `file_key_refs.key_version` to, so the two agree.
    func testMissingVersionDefaultsToOne() throws {
        let (bundle, _) = TestKeys.generate()
        let json = try! JSONSerialization.data(withJSONObject: [
            "public_key": bundle.publicKey, "private_key": bundle.privateKey,
        ])
        XCTAssertEqual(try KeyImportService.importKey(from: json).keyVersion, "1")
    }

    // MARK: - Rejection

    /// The single most important check here: two halves that are not a pair would be stored
    /// happily and then fail to decrypt anything, with no clue why.
    func testMismatchedPairIsRefused() {
        let (a, _) = TestKeys.generate()
        let (b, _) = TestKeys.generate()
        let json = try! JSONSerialization.data(withJSONObject: [
            "public_key": a.publicKey, "private_key": b.privateKey,
        ])
        XCTAssertThrowsError(try KeyImportService.importKey(from: json)) { error in
            XCTAssertEqual(error as? KeyImportError, .keyPairMismatch)
        }
    }

    func testPEMIsRefusedWithAnActionableMessage() {
        let json = try! JSONSerialization.data(withJSONObject: [
            "public_key": "-----BEGIN PUBLIC KEY-----\nabc\n-----END PUBLIC KEY-----",
            "private_key": "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----",
        ])
        XCTAssertThrowsError(try KeyImportService.importKey(from: json)) { error in
            XCTAssertEqual(error as? KeyImportError, .unsupportedFormat)
        }
    }

    func testGarbageIsRefused() {
        XCTAssertThrowsError(try KeyImportService.importKey(from: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? KeyImportError, .invalidJSON)
        }
        let missing = try! JSONSerialization.data(withJSONObject: ["public_key": "abc"])
        XCTAssertThrowsError(try KeyImportService.importKey(from: missing)) { error in
            XCTAssertEqual(error as? KeyImportError, .missingFields)
        }
    }

    // MARK: - Storage

    func testStoredKeysRoundTripThroughTheKeychain() throws {
        let (bundle, _) = TestKeys.generate(version: 4)
        KeyImportService.storeKeys(bundle)

        XCTAssertTrue(KeyImportService.hasStoredKeys())
        XCTAssertEqual(KeyImportService.storedKeys()?.publicKey, bundle.publicKey)
        XCTAssertEqual(KeyImportService.activeKeyVersion(), 4)
    }

    /// The retired keys are worth no less than the active one; forgetting the identity has to
    /// forget all of it.
    func testRemovingKeysAlsoClearsTheArchive() {
        let (active, _) = TestKeys.generate()
        let (retired, _) = TestKeys.generate()
        KeyImportService.storeKeys(active)
        KeyArchive.store([StoredKeyPair(version: 1,
                                        publicKey: retired.publicKey,
                                        privateKey: retired.privateKey)])
        XCTAssertFalse(KeyArchive.load().isEmpty)

        KeyImportService.removeKeys()

        XCTAssertFalse(KeyImportService.hasStoredKeys())
        XCTAssertTrue(KeyArchive.load().isEmpty)
    }

    // MARK: - Version resolution

    func testActiveVersionResolvesToTheActiveKey() {
        let (active, _) = TestKeys.generate(version: 2)
        KeyImportService.storeKeys(active)

        guard case .found(let pub, _) = KeyImportService.keyPair(forVersion: 2) else {
            return XCTFail("expected the active key")
        }
        XCTAssertEqual(pub, active.publicKey)
    }

    func testRetiredVersionResolvesToTheArchive() {
        let (active, _) = TestKeys.generate(version: 2)
        let (old, _) = TestKeys.generate(version: 1)
        KeyImportService.storeKeys(active)
        KeyArchive.store([StoredKeyPair(version: 1, publicKey: old.publicKey, privateKey: old.privateKey)])

        guard case .found(let pub, _) = KeyImportService.keyPair(forVersion: 1) else {
            return XCTFail("expected the archived key")
        }
        XCTAssertEqual(pub, old.publicKey)
    }

    /// "This file needs key version 3" is actionable; a bare nil is not. The three-way result is
    /// the whole point of `KeyLookup`.
    func testUnknownVersionIsReportedByNumberNotAsAbsence() {
        let (active, _) = TestKeys.generate(version: 2)
        KeyImportService.storeKeys(active)

        XCTAssertEqual(KeyImportService.keyPair(forVersion: 7), .missingVersion(7))
    }

    func testNoKeyAtAllIsDistinctFromAMissingVersion() {
        XCTAssertEqual(KeyImportService.keyPair(forVersion: 1), .noKey)
    }
}

// MARK: - KeyFileServiceTests

/// The unsealing decisions, exercised against real sealed boxes.
final class KeyFilePlanTests: XCTestCase {

    private let sodium = Sodium()

    override func setUp() {
        super.setUp()
        KeychainService.installInMemoryBackendForTesting()
        NeutrinoApp.configure(.docs)
    }

    /// Seals `secret` to `recipient`, the way the web app does before upload.
    private func sealed(secret: Curve25519.KeyAgreement.PrivateKey,
                        to recipient: Curve25519.KeyAgreement.PrivateKey,
                        version: Int,
                        declarePublicKey: Bool = true) -> ArchivedKeyDTO {
        let box = sodium.box.seal(message: Array(secret.rawRepresentation),
                                  recipientPublicKey: Array(recipient.publicKey.rawRepresentation))!
        return ArchivedKeyDTO(
            keyVersion: version,
            encryptedKey: SealedKeyCoding.encode(box)!,
            publicKey: declarePublicKey ? SealedKeyCoding.encode(Array(secret.publicKey.rawRepresentation)) : nil
        )
    }

    func testRetiredKeySealedToTheActiveKeyIsRecovered() {
        let active = Curve25519.KeyAgreement.PrivateKey()
        let old = Curve25519.KeyAgreement.PrivateKey()

        let (outcome, keys) = KeyFileService.plan(
            keys: [sealed(secret: old, to: active, version: 1)],
            activePublicKey: Array(active.publicKey.rawRepresentation),
            activeSecretKey: Array(active.rawRepresentation),
            activeVersion: 2,
            held: []
        )

        XCTAssertEqual(outcome.recovered, 1)
        XCTAssertEqual(outcome.unopenable, 0)
        XCTAssertEqual(keys.first?.version, 1)
        XCTAssertEqual(keys.first?.publicKey,
                       TestKeys.base64URL(old.publicKey.rawRepresentation))
    }

    func testAlreadyHeldVersionsAreCountedSeparatelyFromNewOnes() {
        let active = Curve25519.KeyAgreement.PrivateKey()
        let old = Curve25519.KeyAgreement.PrivateKey()

        let (outcome, _) = KeyFileService.plan(
            keys: [sealed(secret: old, to: active, version: 1)],
            activePublicKey: Array(active.publicKey.rawRepresentation),
            activeSecretKey: Array(active.rawRepresentation),
            activeVersion: 2,
            held: [1]
        )

        XCTAssertEqual(outcome.alreadyHeld, 1)
        XCTAssertEqual(outcome.recovered, 0)
    }

    /// An entry sealed to somebody else's key must be refused, not stored as a key that opens
    /// nothing.
    func testEntrySealedToAnotherKeyIsRefused() {
        let active = Curve25519.KeyAgreement.PrivateKey()
        let stranger = Curve25519.KeyAgreement.PrivateKey()
        let old = Curve25519.KeyAgreement.PrivateKey()

        let (outcome, keys) = KeyFileService.plan(
            keys: [sealed(secret: old, to: stranger, version: 1)],
            activePublicKey: Array(active.publicKey.rawRepresentation),
            activeSecretKey: Array(active.rawRepresentation),
            activeVersion: 2,
            held: []
        )

        XCTAssertEqual(outcome.unopenable, 1)
        XCTAssertTrue(keys.isEmpty)
    }

    /// A tampered `publicKey` field must not install a mismatched pair — the public half is
    /// derived from the recovered secret and the declared one is only ever checked against it.
    func testTamperedPublicHalfIsRefused() {
        let active = Curve25519.KeyAgreement.PrivateKey()
        let old = Curve25519.KeyAgreement.PrivateKey()
        var entry = sealed(secret: old, to: active, version: 1)
        entry = ArchivedKeyDTO(keyVersion: entry.keyVersion,
                               encryptedKey: entry.encryptedKey,
                               publicKey: TestKeys.base64URL(
                                   Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation))

        let (outcome, keys) = KeyFileService.plan(
            keys: [entry],
            activePublicKey: Array(active.publicKey.rawRepresentation),
            activeSecretKey: Array(active.rawRepresentation),
            activeVersion: 2,
            held: []
        )

        XCTAssertEqual(outcome.unopenable, 1)
        XCTAssertTrue(keys.isEmpty)
    }

    /// The file holds retired keys only. This device's "active" version appearing in it means the
    /// account rotated and this key is stale — the one staleness signal the file yields on its own.
    func testActiveVersionAppearingInTheFileIsReportedAsStale() {
        let active = Curve25519.KeyAgreement.PrivateKey()
        let old = Curve25519.KeyAgreement.PrivateKey()

        let (outcome, _) = KeyFileService.plan(
            keys: [sealed(secret: old, to: active, version: 2)],
            activePublicKey: Array(active.publicKey.rawRepresentation),
            activeSecretKey: Array(active.rawRepresentation),
            activeVersion: 2,
            held: []
        )

        XCTAssertTrue(outcome.activeIsStale)
    }

    func testActiveVersionIsNeverRecoveredIntoTheArchive() {
        let active = Curve25519.KeyAgreement.PrivateKey()

        let (_, keys) = KeyFileService.plan(
            keys: [sealed(secret: active, to: active, version: 2)],
            activePublicKey: Array(active.publicKey.rawRepresentation),
            activeSecretKey: Array(active.rawRepresentation),
            activeVersion: 2,
            held: []
        )

        XCTAssertTrue(keys.isEmpty, "the active key is already in the Keychain")
    }
}

// MARK: - KeyArchiveTests

final class KeyArchiveTests: XCTestCase {

    override func setUp() {
        super.setUp()
        KeychainService.installInMemoryBackendForTesting()
        NeutrinoApp.configure(.notes)
        KeyArchive.clear()
    }

    override func tearDown() {
        KeyArchive.clear()
        KeychainService.removeTestingBackend()
        super.tearDown()
    }

    private func pair(_ version: Int) -> StoredKeyPair {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        return StoredKeyPair(version: version,
                             publicKey: TestKeys.base64URL(priv.publicKey.rawRepresentation),
                             privateKey: TestKeys.base64URL(priv.rawRepresentation))
    }

    func testStoredKeysComeBackAscendingByVersion() {
        XCTAssertTrue(KeyArchive.store([pair(3), pair(1), pair(2)]))
        XCTAssertEqual(KeyArchive.load().map(\.version), [1, 2, 3])
    }

    func testDuplicateVersionsAreCollapsed() {
        XCTAssertTrue(KeyArchive.store([pair(1), pair(1), pair(2)]))
        XCTAssertEqual(KeyArchive.load().map(\.version), [1, 2])
    }

    func testStoringAnEmptySetClearsTheArchive() {
        XCTAssertTrue(KeyArchive.store([pair(1)]))
        XCTAssertTrue(KeyArchive.store([]))
        XCTAssertTrue(KeyArchive.load().isEmpty)
    }

    func testLookupByVersion() {
        let target = pair(2)
        XCTAssertTrue(KeyArchive.store([pair(1), target]))
        XCTAssertEqual(KeyArchive.keyPair(forVersion: 2)?.publicKey, target.publicKey)
        XCTAssertNil(KeyArchive.keyPair(forVersion: 9))
    }

    /// The archive is namespaced like everything else — Notes' retired keys must not be visible to
    /// Drive.
    func testArchiveIsNamespacedPerApp() {
        XCTAssertTrue(KeyArchive.store([pair(1)]))
        XCTAssertEqual(KeyArchive.load().count, 1)

        NeutrinoApp.configure(.drive)
        XCTAssertTrue(KeyArchive.load().isEmpty, "Drive must not see Notes' archive")

        NeutrinoApp.configure(.notes)
        XCTAssertEqual(KeyArchive.load().count, 1)
    }
}
