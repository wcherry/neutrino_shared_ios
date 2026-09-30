import XCTest
import Sodium
@testable import NeutrinoCrypto

/// The vault apps filed their key under the vault's envelope version (always 1), so on a rotated
/// account files sealed to v2 were recorded as v1. These pin down that such a file still opens, that
/// the caller is told it is misfiled, and that the directory — not the vault — numbers a key.
final class KeyVersionRepairTests: XCTestCase {

    private let sodium = Sodium()

    private func keyPair(version: Int) -> StoredKeyPair {
        let kp = sodium.box.keyPair()!
        return StoredKeyPair(version: version,
                             publicKey: SealedKeyCoding.encode(kp.publicKey)!,
                             privateKey: SealedKeyCoding.encode(kp.secretKey)!)
    }

    private func seal(_ dek: Bytes, to key: StoredKeyPair) -> String {
        let sealed = sodium.box.seal(message: dek,
                                     recipientPublicKey: SealedKeyCoding.decode(key.publicKey)!)!
        return SealedKeyCoding.encode(sealed)!
    }

    private let dek: Bytes = Array(repeating: 7, count: 32)

    func testOpensWithTheNamedVersionAndIsNotMisfiled() throws {
        let v1 = keyPair(version: 1), v2 = keyPair(version: 2)

        let opened = try KeyImportService.openSealedDEK(seal(dek, to: v1), keyVersion: 1, using: [v2, v1])

        XCTAssertEqual(opened.dek, dek)
        XCTAssertEqual(opened.version, 1)
        XCTAssertFalse(opened.isMisfiled)
    }

    func testOpensARefThatNamesTheWrongVersion() throws {
        // The reported case: sealed to v2, recorded as v1.
        let v1 = keyPair(version: 1), v2 = keyPair(version: 2)

        let opened = try KeyImportService.openSealedDEK(seal(dek, to: v2), keyVersion: 1, using: [v2, v1])

        XCTAssertEqual(opened.dek, dek)
        XCTAssertEqual(opened.version, 2)
        XCTAssertTrue(opened.isMisfiled)
    }

    func testOpensARefNamingAVersionThisDeviceLacks() throws {
        let v2 = keyPair(version: 2)

        let opened = try KeyImportService.openSealedDEK(seal(dek, to: v2), keyVersion: 1, using: [v2])

        XCTAssertEqual(opened.version, 2)
    }

    func testReportsAMissingVersionWhenNothingHeldOpensIt() {
        let stranger = keyPair(version: 9)

        XCTAssertThrowsError(
            try KeyImportService.openSealedDEK(seal(dek, to: stranger), keyVersion: 3,
                                               using: [keyPair(version: 1)])
        ) { XCTAssertEqual($0 as? SealedDEKError, .missingVersion(3)) }
    }

    func testReportsNotOpenableWhenTheNamedKeyIsHeldButWrong() {
        let stranger = keyPair(version: 9)

        XCTAssertThrowsError(
            try KeyImportService.openSealedDEK(seal(dek, to: stranger), keyVersion: 1,
                                               using: [keyPair(version: 1)])
        ) { XCTAssertEqual($0 as? SealedDEKError, .notOpenable(namedVersion: 1)) }
    }

    func testReportsNoKeyOnADeviceWithNone() {
        XCTAssertThrowsError(try KeyImportService.openSealedDEK("AAAA", keyVersion: 1, using: [])) {
            XCTAssertEqual($0 as? SealedDEKError, .noKey)
        }
    }

    func testTriesTheNamedVersionFirstThenNewestFirst() {
        let keys = [1, 2, 3, 4].map { keyPair(version: $0) }

        let order = KeyImportService.candidateOrder(keys, preferring: 2).map(\.version)

        XCTAssertEqual(order, [2, 4, 3, 1])
    }

    func testTheDirectoryNumbersAKeyByMatchingItAcrossEncodings() {
        let key = keyPair(version: 0)
        let bytes = Data(SealedKeyCoding.decode(key.publicKey)!)
        let entries = [
            PublishedKeyDirectory.Entry(version: 1, publicKey: keyPair(version: 0).publicKey),
            // Standard, padded base64 in the directory; base64url from the vault.
            PublishedKeyDirectory.Entry(version: 2, publicKey: bytes.base64EncodedString()),
        ]

        XCTAssertEqual(PublishedKeyDirectory.version(of: key.publicKey, in: entries), 2)
        XCTAssertNil(PublishedKeyDirectory.version(of: keyPair(version: 0).publicKey, in: entries))
    }
}
