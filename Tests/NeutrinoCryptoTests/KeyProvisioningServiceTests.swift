import XCTest
import CryptoKit
import NeutrinoCore
import NeutrinoAuth
@testable import NeutrinoCrypto

/// Minting this account's first identity key — the iOS half of what only the web app could do.
///
/// The crypto is not mocked: the test derives the public half from the private key that was stored
/// and compares it with what was published, because "the server was told about a key this device
/// does not hold" is exactly the failure that would leave an account unable to receive a share.
@MainActor
final class KeyProvisioningServiceTests: XCTestCase {

    private var sut: KeyProvisioningService!

    private static let publicKeyPath = "/api/v1/auth/users/\(TestTokens.userId)/public-key"
    private static let publishPath = "/api/v1/auth/keys"

    override func setUp() {
        super.setUp()
        NeutrinoApp.configure(.docs)
        // A SwiftPM test bundle has no host app, so every real `SecItemAdd` fails; see
        // `KeychainService.Backend`.
        KeychainService.installInMemoryBackendForTesting()
        MockURLProtocol.reset()
        TestTokens.remove()
        StoredTestKeys.remove()
        TestServer.use()
        TestTokens.install()
        sut = KeyProvisioningService(session: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        StoredTestKeys.remove()
        TestServer.reset()
        KeychainService.removeTestingBackend()
        sut = nil
        super.tearDown()
    }

    // MARK: - Account state

    func test404MeansTheAccountHasNoKey() async throws {
        MockURLProtocol.respond(json: "", statusCode: 404)

        let state = try await sut.accountKeyState()

        XCTAssertEqual(state, .unpublished)
    }

    func testAPublishedKeyIsReportedWithItsVersion() async throws {
        MockURLProtocol.respond(json: #"{"userId":"u","publicKey":"cHVi","version":3}"#)

        let state = try await sut.accountKeyState()

        XCTAssertEqual(state, .published(version: 3, publicKey: "cHVi"))
    }

    // MARK: - Provisioning

    func testProvisioningStoresTheKeyAndPublishesItsPublicHalf() async throws {
        stubFreshAccount()

        let kit = try await sut.provisionIdentity()

        XCTAssertFalse(kit.isEmpty)
        let stored = try XCTUnwrap(KeyImportService.storedKeys())
        XCTAssertEqual(stored.keyVersion, "1")

        // The published key must be the public half of the secret key this device kept — anything
        // else and collaborators would seal to a key nobody holds.
        let index = try XCTUnwrap(MockURLProtocol.requests.firstIndex { $0.url?.path == Self.publishPath })
        let body = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: MockURLProtocol.bodies[index])) as? [String: String]
        )
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: try XCTUnwrap(Data(base64URL: stored.privateKey))
        )
        XCTAssertEqual(body["publicKey"], StoredTestKeys.base64URL(privateKey.publicKey.rawRepresentation))
        XCTAssertEqual(body["publicKey"], stored.publicKey)
    }

    /// The account is checked before anything is minted, and the key is published after it is
    /// stored — publishing first would advertise a key a failed write means this device cannot use.
    func testProvisioningChecksTheAccountBeforePublishing() async throws {
        stubFreshAccount()

        _ = try await sut.provisionIdentity()

        let paths = MockURLProtocol.requests.compactMap { $0.url?.path }
        XCTAssertEqual(paths, [Self.publicKeyPath, Self.publishPath])
    }

    /// The kit is the only copy of the identity that survives losing this device, so it has to
    /// carry the key that was actually kept.
    func testTheKitCarriesTheStoredSecretKey() async throws {
        stubFreshAccount()

        let kit = try await sut.provisionIdentity()

        let stored = try XCTUnwrap(KeyImportService.storedKeys())
        let secretKey = try XCTUnwrap(Data(base64URL: stored.privateKey))
        XCTAssertEqual(kit, RecoveryKit.export(entries: [
            RecoveryKit.Entry(version: 1, secretKey: secretKey),
        ]))
    }

    // MARK: - Refusals

    /// Publishing a different key on an account that has one is a *rotation*: the server retires
    /// the current version, and every DEK sealed to it would need re-sealing by a client holding
    /// the old secret — which this device does not have.
    func testAnAccountThatAlreadyPublishesAKeyIsRefused() async {
        MockURLProtocol.respond(json: #"{"userId":"u","publicKey":"cHVi","version":1}"#)

        do {
            _ = try await sut.provisionIdentity()
            XCTFail("Expected provisioning to be refused")
        } catch {
            XCTAssertEqual(error as? KeyProvisioningError, .alreadyPublished)
        }
        XCTAssertFalse(KeyImportService.hasStoredKeys())
        XCTAssertNil(MockURLProtocol.request { $0.url?.path == Self.publishPath })
    }

    func testADeviceThatAlreadyHoldsAKeyIsRefusedWithoutACall() async {
        let existing = StoredTestKeys.install()
        MockURLProtocol.respond(json: "", statusCode: 404)

        do {
            _ = try await sut.provisionIdentity()
            XCTFail("Expected provisioning to be refused")
        } catch {
            XCTAssertEqual(error as? KeyProvisioningError, .deviceAlreadyHasKey)
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
        // The key already on the device is untouched.
        XCTAssertEqual(KeyImportService.storedKeys()?.privateKey, existing.privateKey)
    }

    /// Nothing has been encrypted with it yet, so rolling back is free — and a key left in the
    /// Keychain that the account never heard of would make every later attempt refuse.
    func testAFailedPublishRollsBackTheStoredKey() async {
        MockURLProtocol.handler = { request in
            if request.url?.path == Self.publicKeyPath {
                return (HTTPURLResponse(url: request.url!, statusCode: 404,
                                        httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 500,
                                    httpVersion: nil, headerFields: nil)!, Data())
        }

        do {
            _ = try await sut.provisionIdentity()
            XCTFail("Expected provisioning to fail")
        } catch {
            XCTAssertEqual(error as? KeyProvisioningError, .serverError(statusCode: 500))
        }
        XCTAssertFalse(KeyImportService.hasStoredKeys())
    }

    func testSignedOutProvisioningIsRefused() async {
        TestTokens.remove()

        do {
            _ = try await sut.provisionIdentity()
            XCTFail("Expected provisioning to be refused")
        } catch {
            XCTAssertEqual(error as? KeyProvisioningError, .notAuthenticated)
        }
    }

    // MARK: - Restoring from a recovery kit

    func testRestoringAKitAdoptsItsActiveKeyAndArchivesTheRetiredOnes() async throws {
        let keyring = Self.makeKeyring(versions: 3)
        stubAccount(publishing: keyring.activePublicKey, version: 3)

        let outcome = try await sut.restoreFromRecoveryKit(keyring.kit)

        XCTAssertEqual(outcome, RecoveryKitRestoreOutcome(activeVersion: 3,
                                                          archivedVersions: 2,
                                                          republished: false))
        XCTAssertEqual(KeyImportService.storedKeys()?.publicKey, keyring.activePublicKey)
        XCTAssertEqual(KeyImportService.activeKeyVersion(), 3)
        // The retired versions are what make documents written before the rotations open.
        XCTAssertEqual(KeyArchive.load().map(\.version), [1, 2])
        XCTAssertNotNil(KeyArchive.keyPair(forVersion: 1))
    }

    /// Restoring must never publish: adopting a key the account already has is not a rotation, and
    /// a POST would be one.
    func testRestoringAMatchingKitPublishesNothing() async throws {
        let keyring = Self.makeKeyring(versions: 1)
        stubAccount(publishing: keyring.activePublicKey, version: 1)

        _ = try await sut.restoreFromRecoveryKit(keyring.kit)

        XCTAssertNil(MockURLProtocol.request { $0.url?.path == Self.publishPath })
    }

    /// A kit printed before a rotation carries a key the account no longer uses. Adopting it would
    /// make this device seal new documents to a key no collaborator would use, so it is refused
    /// rather than half-working.
    func testAKitForADifferentKeyIsRefused() async {
        let keyring = Self.makeKeyring(versions: 1)
        let someoneElse = Curve25519.KeyAgreement.PrivateKey()
        stubAccount(publishing: StoredTestKeys.base64URL(someoneElse.publicKey.rawRepresentation),
                    version: 1)

        do {
            _ = try await sut.restoreFromRecoveryKit(keyring.kit)
            XCTFail("Expected the kit to be refused")
        } catch {
            XCTAssertEqual(error as? KeyProvisioningError, .kitDoesNotMatchAccount)
        }
        XCTAssertFalse(KeyImportService.hasStoredKeys())
        XCTAssertTrue(KeyArchive.load().isEmpty)
    }

    /// A kit exists only because a key was once published, so an empty directory means the publish
    /// never landed — repairable, but only for a keyring that never rotated.
    func testAnUnpublishedAccountIsRepairedFromASingleVersionKit() async throws {
        let keyring = Self.makeKeyring(versions: 1)
        MockURLProtocol.handler = { request in
            if request.url?.path == Self.publicKeyPath {
                return (HTTPURLResponse(url: request.url!, statusCode: 404,
                                        httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!,
                    Data(#"{"userId":"u","publicKey":"pub","version":1}"#.utf8))
        }

        let outcome = try await sut.restoreFromRecoveryKit(keyring.kit)

        XCTAssertTrue(outcome.republished)
        let index = try XCTUnwrap(MockURLProtocol.requests.firstIndex { $0.url?.path == Self.publishPath })
        let body = (try? JSONSerialization.jsonObject(with: MockURLProtocol.bodies[index]))
            as? [String: String]
        XCTAssertEqual(body?["publicKey"], keyring.activePublicKey)
    }

    /// With nothing published there is no way to tell which of a rotated kit's versions the account
    /// lost, and guessing wrong would retire a key that is still in use.
    func testARotatedKitIsNotUsedToRepairAnUnpublishedAccount() async {
        let keyring = Self.makeKeyring(versions: 2)
        MockURLProtocol.respond(json: "", statusCode: 404)

        do {
            _ = try await sut.restoreFromRecoveryKit(keyring.kit)
            XCTFail("Expected the kit to be refused")
        } catch {
            XCTAssertEqual(error as? KeyProvisioningError, .accountPublishesNoKey)
        }
        XCTAssertFalse(KeyImportService.hasStoredKeys())
    }

    func testGarbledKitIsReportedBeforeAnythingIsAsked() async {
        do {
            _ = try await sut.restoreFromRecoveryKit("not a recovery kit at all")
            XCTFail("Expected the kit to be rejected")
        } catch {
            XCTAssertTrue(error is RecoveryKitError, "Got \(error)")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
        XCTAssertFalse(KeyImportService.hasStoredKeys())
    }

    func testRestoringWhileSignedOutIsRefused() async {
        TestTokens.remove()
        let keyring = Self.makeKeyring(versions: 1)

        do {
            _ = try await sut.restoreFromRecoveryKit(keyring.kit)
            XCTFail("Expected the restore to be refused")
        } catch {
            XCTAssertEqual(error as? KeyProvisioningError, .notAuthenticated)
        }
    }

    // MARK: - canProvision

    func testCanProvisionIsTrueOnlyForAnAccountAndDeviceWithNoKey() async {
        MockURLProtocol.respond(json: "", statusCode: 404)
        var canProvision = await sut.canProvision()
        XCTAssertTrue(canProvision)

        StoredTestKeys.install()
        canProvision = await sut.canProvision()
        XCTAssertFalse(canProvision)
    }

    /// Offering to mint a key because the network was down is how an account ends up with its
    /// identity rotated away.
    func testCanProvisionIsFalseWhenTheAccountStateCannotBeFetched() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        let canProvision = await sut.canProvision()

        XCTAssertFalse(canProvision)
    }

    // MARK: - Helpers

    /// A real keyring and the kit that carries it: `versions` entries, the last one active.
    private static func makeKeyring(versions: Int) -> (kit: String, activePublicKey: String) {
        let keys = (0..<versions).map { _ in Curve25519.KeyAgreement.PrivateKey() }
        let entries = keys.enumerated().map { index, key in
            RecoveryKit.Entry(version: index + 1,
                              secretKey: key.rawRepresentation,
                              isRetired: index < versions - 1)
        }
        return (RecoveryKit.export(entries: entries),
                StoredTestKeys.base64URL(keys[versions - 1].publicKey.rawRepresentation))
    }

    /// An account whose directory publishes `publicKey`.
    private func stubAccount(publishing publicKey: String, version: Int) {
        MockURLProtocol.respond(json: """
        {"userId":"\(TestTokens.userId)","publicKey":"\(publicKey)","version":\(version)}
        """)
    }

    /// A new account: nothing published, and the publish call answers with version 1.
    private func stubFreshAccount() {
        MockURLProtocol.handler = { request in
            if request.url?.path == Self.publicKeyPath {
                return (HTTPURLResponse(url: request.url!, statusCode: 404,
                                        httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!,
                    Data(#"{"userId":"\#(TestTokens.userId)","publicKey":"pub","version":1}"#.utf8))
        }
    }
}

// MARK: - Base64URL

private extension Data {
    /// The encoding the app stores keys in — base64url, unpadded.
    init?(base64URL string: String) {
        var standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder != 0 {
            standard += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: standard) else { return nil }
        self = data
    }
}
