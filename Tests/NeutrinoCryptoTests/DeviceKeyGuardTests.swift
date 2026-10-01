import XCTest
import CryptoKit
import Sodium
import NeutrinoCore
@testable import NeutrinoCrypto

// MARK: - Helpers

private func makeKeyPair() -> KeyBundle {
    let priv = Curve25519.KeyAgreement.PrivateKey()
    return KeyBundle(publicKey: StoredTestKeys.base64URL(priv.publicKey.rawRepresentation),
                     privateKey: StoredTestKeys.base64URL(priv.rawRepresentation),
                     keyVersion: "1")
}

private func seal(_ dek: Bytes, to key: KeyBundle) throws -> String {
    try DriveFileCrypto.seal(dek: dek, toPublicKey: Bytes(Data(base64URLEncoded: key.publicKey)!))
}

private func open(_ sealed: String, with key: KeyBundle) throws -> Bytes {
    try DriveFileCrypto.openDEK(sealed,
                                publicKey: Bytes(Data(base64URLEncoded: key.publicKey)!),
                                secretKey: Bytes(Data(base64URLEncoded: key.privateKey)!))
}

/// An in-memory server: a key directory, a file listing and the caller's key refs.
private class FakeTransport: DeviceKeyTransport {
    var published: PublishedKey?
    var refs: [String: (sealed: String, keyVersion: Int)] = [:]
    var fileIDs: [String] = []
    private(set) var writes: [String: (sealed: String, keyVersion: Int)] = [:]
    private(set) var directoryReads = 0
    /// How many times `fileKey` fails with a retryable error before answering.
    var transientFailures: [String: Int] = [:]

    struct Transient: Error {}

    func publishedKey() async throws -> PublishedKey? {
        directoryReads += 1
        return published
    }

    func fileIDsPage(limit: Int, offset: Int) async throws -> [String] {
        guard offset < fileIDs.count else { return [] }
        return Array(fileIDs[offset..<min(offset + limit, fileIDs.count)])
    }

    func fileKey(fileID: String) async throws -> (sealed: String, keyVersion: Int)? {
        if let remaining = transientFailures[fileID], remaining > 0 {
            transientFailures[fileID] = remaining - 1
            throw Transient()
        }
        return refs[fileID]
    }

    func setFileKey(fileID: String, sealed: String, keyVersion: Int) async throws {
        writes[fileID] = (sealed, keyVersion)
        refs[fileID] = (sealed, keyVersion)
    }

    func isRetryable(_ error: Error) -> Bool { error is Transient }
}

// MARK: - DeviceKeyStatusTests

final class DeviceKeyStatusTests: XCTestCase {

    func testCurrentWhenTheStoredKeyIsThePublishedOne() {
        let key = makeKeyPair().publicKey
        XCTAssertEqual(DeviceKeyStatus.of(storedPublicKey: key, published: PublishedKey(publicKey: key, version: 2)),
                       .current(version: 2))
    }

    func testCurrentWhenOnlyTheEncodingDiffers() {
        let bytes = Data(base64URLEncoded: makeKeyPair().publicKey)!
        XCTAssertEqual(DeviceKeyStatus.of(storedPublicKey: bytes.base64EncodedString(),
                                          published: PublishedKey(publicKey: StoredTestKeys.base64URL(bytes), version: 1)),
                       .current(version: 1))
    }

    func testStaleWhenTheAccountPublishesAnotherKey() {
        let published = PublishedKey(publicKey: makeKeyPair().publicKey, version: 1)
        XCTAssertEqual(DeviceKeyStatus.of(storedPublicKey: makeKeyPair().publicKey, published: published),
                       .stale(published: published))
    }

    func testUnpublishedWhenTheAccountPublishesNothing() {
        XCTAssertEqual(DeviceKeyStatus.of(storedPublicKey: makeKeyPair().publicKey, published: nil), .unpublished)
    }
}

// MARK: - DeviceKeyRewrapTests

final class DeviceKeyRewrapTests: XCTestCase {

    /// The incident: a device sealed to its own stale key. After the rewrap the ref must open with
    /// the account's key — the one the web holds — and carry the same DEK.
    func testMovesADEKSealedToTheDeviceKeyOntoTheAccountsKey() throws {
        let device = makeKeyPair(), account = makeKeyPair()
        let dek = DriveFileCrypto.newDEK()

        let resealed = try XCTUnwrap(DeviceKeyRewrap.rewrap(try seal(dek, to: device), deviceKey: device,
                                                            to: PublishedKey(publicKey: account.publicKey, version: 4)))

        XCTAssertEqual(try open(resealed, with: account), dek, "Same DEK, new recipient")
    }

    func testLeavesARefTheDeviceKeyDoesNotOpenAlone() throws {
        let device = makeKeyPair(), account = makeKeyPair()
        XCTAssertNil(DeviceKeyRewrap.rewrap(try seal(DriveFileCrypto.newDEK(), to: account), deviceKey: device,
                                            to: PublishedKey(publicKey: account.publicKey, version: 1)))
    }
}

// MARK: - DeviceKeyCheckTests

final class DeviceKeyCheckTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NeutrinoApp.configure(.drive)
        KeychainService.installInMemoryBackendForTesting()
        DeviceKeyCheck.forget()
    }

    override func tearDown() {
        DeviceKeyCheck.forget()
        StoredTestKeys.remove()
        super.tearDown()
    }

    func testAnswersThePublishedVersion_notTheKeychainsNumber() async throws {
        let stored = StoredTestKeys.install(version: 1)
        let version = try await DeviceKeyCheck.sealingVersion {
            PublishedKey(publicKey: stored.publicKey, version: 3)
        }
        XCTAssertEqual(version, 3)
    }

    func testRefusesAStaleKey() async {
        StoredTestKeys.install()
        do {
            _ = try await DeviceKeyCheck.sealingVersion { PublishedKey(publicKey: makeKeyPair().publicKey, version: 1) }
            XCTFail("expected .stale")
        } catch {
            XCTAssertEqual(error as? DeviceKeyCheckError, .stale)
        }
    }

    func testRefusesWhenTheAccountPublishesNoKey() async {
        StoredTestKeys.install()
        do {
            _ = try await DeviceKeyCheck.sealingVersion { nil }
            XCTFail("expected .stale")
        } catch {
            XCTAssertEqual(error as? DeviceKeyCheckError, .stale)
        }
    }

    func testRefusesWithNoKeyStored() async {
        do {
            _ = try await DeviceKeyCheck.sealingVersion { XCTFail("must not ask"); return nil }
            XCTFail("expected .noKey")
        } catch {
            XCTAssertEqual(error as? DeviceKeyCheckError, .noKey)
        }
    }

    func testCachesAMatchForTheSameKey_andAsksAgainForANewOne() async throws {
        let first = StoredTestKeys.install()
        var asks = 0
        for _ in 0..<3 {
            _ = try await DeviceKeyCheck.sealingVersion { asks += 1; return PublishedKey(publicKey: first.publicKey, version: 1) }
        }
        XCTAssertEqual(asks, 1, "a backup of a thousand photos must not ask a thousand times")

        let second = StoredTestKeys.install()
        _ = try await DeviceKeyCheck.sealingVersion { asks += 1; return PublishedKey(publicKey: second.publicKey, version: 2) }
        XCTAssertEqual(asks, 2, "a key imported mid-run must be checked, not ride on the old key's answer")
    }
}

// MARK: - DeviceKeyRepairServiceTests

@MainActor
final class DeviceKeyRepairServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NeutrinoApp.configure(.drive)
        KeychainService.installInMemoryBackendForTesting()
        DeviceKeyCheck.forget()
    }

    override func tearDown() {
        DeviceKeyCheck.forget()
        StoredTestKeys.remove()
        super.tearDown()
    }

    private func makeSUT(_ transport: FakeTransport) -> DeviceKeyRepairService {
        DeviceKeyRepairService(transport: transport, sleep: { _ in })
    }

    func testReSealsOnlyTheFilesTheDeviceKeyOpens() async throws {
        let device = StoredTestKeys.install()
        let account = makeKeyPair()
        let dek = DriveFileCrypto.newDEK()
        let transport = FakeTransport()
        transport.published = PublishedKey(publicKey: account.publicKey, version: 2)
        transport.fileIDs = ["mine", "theirs", "plain"]
        transport.refs = ["mine": (try seal(dek, to: device), 1),
                          "theirs": (try seal(DriveFileCrypto.newDEK(), to: account), 2)]

        let sut = makeSUT(transport)
        await sut.checkAndRepair()

        guard case .repaired(let report) = sut.state else { return XCTFail("state is \(sut.state)") }
        XCTAssertEqual(report.rewrapped, 1)
        XCTAssertEqual(report.alreadyCorrect, 1)
        XCTAssertEqual(report.unencrypted, 1)
        XCTAssertEqual(Set(transport.writes.keys), ["mine"], "only the caller's device-sealed ref is written")
        XCTAssertEqual(transport.writes["mine"]?.keyVersion, 2)
        XCTAssertEqual(try open(try XCTUnwrap(transport.writes["mine"]?.sealed), with: account), dek)
        XCTAssertFalse(sut.state.keyMustBeKept)
    }

    func testASecondRunWritesNothing() async throws {
        let device = StoredTestKeys.install()
        let account = makeKeyPair()
        let transport = FakeTransport()
        transport.published = PublishedKey(publicKey: account.publicKey, version: 1)
        transport.fileIDs = ["mine"]
        transport.refs = ["mine": (try seal(DriveFileCrypto.newDEK(), to: device), 1)]

        await makeSUT(transport).checkAndRepair()
        let afterFirst = transport.writes.count
        let second = makeSUT(transport)
        await second.checkAndRepair()

        XCTAssertEqual(afterFirst, 1)
        XCTAssertEqual(transport.writes.count, 1)
        guard case .repaired(let report) = second.state else { return XCTFail("state is \(second.state)") }
        XCTAssertEqual(report.alreadyCorrect, 1)
    }

    func testPagesThroughTheWholeDrive() async throws {
        let device = StoredTestKeys.install()
        let transport = FakeTransport()
        transport.published = PublishedKey(publicKey: makeKeyPair().publicKey, version: 1)
        transport.fileIDs = (0..<(DeviceKeyRepairService.pageSize + 7)).map { "f\($0)" }
        for id in transport.fileIDs { transport.refs[id] = (try seal(DriveFileCrypto.newDEK(), to: device), 1) }

        let sut = makeSUT(transport)
        await sut.checkAndRepair()

        guard case .repaired(let report) = sut.state else { return XCTFail("state is \(sut.state)") }
        XCTAssertEqual(report.rewrapped, transport.fileIDs.count)
    }

    func testRetriesATransientFailure_andCountsOneThatPersists() async throws {
        let device = StoredTestKeys.install()
        let transport = FakeTransport()
        transport.published = PublishedKey(publicKey: makeKeyPair().publicKey, version: 1)
        transport.fileIDs = ["flaky", "down"]
        transport.refs = ["flaky": (try seal(DriveFileCrypto.newDEK(), to: device), 1),
                          "down": (try seal(DriveFileCrypto.newDEK(), to: device), 1)]
        transport.transientFailures = ["flaky": 2, "down": 99]

        let sut = makeSUT(transport)
        await sut.checkAndRepair()

        guard case .repaired(let report) = sut.state else { return XCTFail("state is \(sut.state)") }
        XCTAssertEqual(report.rewrapped, 1)
        XCTAssertEqual(report.failed, 1)
        XCTAssertTrue(sut.state.keyMustBeKept, "a file only this key opens is still out there")
    }

    func testACurrentKeyTouchesNoFiles_andPrimesTheSealingCheck() async throws {
        let stored = StoredTestKeys.install()
        let transport = FakeTransport()
        transport.published = PublishedKey(publicKey: stored.publicKey, version: 5)
        transport.fileIDs = ["a"]

        let sut = makeSUT(transport)
        await sut.checkAndRepair()

        XCTAssertEqual(sut.state, .current)
        XCTAssertTrue(transport.writes.isEmpty)
        let version = try await DeviceKeyCheck.sealingVersion { XCTFail("cached answer expected"); return nil }
        XCTAssertEqual(version, 5)
    }

    func testOfflineLeavesTheStateAlone() async {
        StoredTestKeys.install()
        final class Offline: FakeTransport {
            override func publishedKey() async throws -> PublishedKey? { throw URLError(.notConnectedToInternet) }
        }
        let sut = makeSUT(Offline())
        await sut.checkAndRepair()
        XCTAssertEqual(sut.state, .unknown)
    }
}
