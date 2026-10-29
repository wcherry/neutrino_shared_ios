import XCTest
import Sodium
@testable import NeutrinoCrypto

// MARK: - KeyringCoder
//
// The wire format is shared with the web client and the macOS client, byte for byte, and nothing in
// the build catches a drift — a keyring that decodes to the wrong bytes still decodes. These pin the
// invariants the other implementations rely on: the public half is derived and never carried,
// exactly one entry is active, versions are unique, secret keys are 32 bytes.
//
// Ported from the macOS client's suite when it adopted this package.

/// A keyring of `versions` entries, the highest active, over real Curve25519 pairs.
private func makeKeyring(versions: [Int]) throws -> Keyring {
    let sodium = Sodium()
    let highest = try XCTUnwrap(versions.max())
    let entries = try versions.map { version -> KeyringEntry in
        let pair = try XCTUnwrap(sodium.box.keyPair())
        return KeyringEntry(version: version,
                            publicKey: pair.publicKey,
                            secretKey: pair.secretKey,
                            createdAt: "2026-01-01T00:00:00Z",
                            retiredAt: version == highest ? nil : "2026-01-02T00:00:00Z")
    }
    return Keyring(userId: "user-1", entries: entries)
}

final class KeyringCoderTests: XCTestCase {

    func testRoundTripPreservesEveryVersion() throws {
        let keyring = try makeKeyring(versions: [1, 2, 3])

        let decoded = try KeyringCoder.decodeJSON(try KeyringCoder.encodeJSON(keyring))

        XCTAssertEqual(decoded.userId, keyring.userId)
        XCTAssertEqual(decoded.entries.map(\.version), [1, 2, 3])
        XCTAssertEqual(decoded.entries.map(\.secretKey), keyring.entries.map(\.secretKey))
        XCTAssertEqual(decoded.active?.version, 3)
    }

    /// The serialised form carries secret keys only. A public half on the wire could disagree
    /// with its secret, and the seals made against it would then be quietly unopenable.
    func testSerializedFormCarriesNoPublicKey() throws {
        let keyring = try makeKeyring(versions: [1])
        let json = try XCTUnwrap(String(data: try KeyringCoder.encodeJSON(keyring), encoding: .utf8))

        XCTAssertTrue(json.contains("\"sk\""))
        XCTAssertFalse(json.contains("\"pk\""))
        XCTAssertFalse(json.contains("publicKey"))
    }

    /// Deriving rather than trusting is what makes the above safe: the recovered public key
    /// must be the one the secret actually multiplies to.
    func testPublicKeyIsDerivedFromTheSecret() throws {
        let keyring = try makeKeyring(versions: [1])
        let expected = try XCTUnwrap(keyring.active).publicKey

        let decoded = try KeyringCoder.decodeJSON(try KeyringCoder.encodeJSON(keyring))

        XCTAssertEqual(decoded.active?.publicKey, expected)
    }

    func testDeserializeRejectsAKeyringWithNoActiveEntry() {
        let payload = SerializedKeyring(v: 1, userId: "user-1", entries: [
            .init(version: 1, sk: Base64URL.encode([UInt8](repeating: 1, count: 32)),
                  createdAt: "t", retiredAt: "t")
        ])

        XCTAssertThrowsError(try KeyringCoder.deserialize(payload)) { error in
            XCTAssertEqual(error as? KeyringError, .notExactlyOneActive(count: 0))
        }
    }

    /// Two active entries means the payload does not say which key new work is sealed to.
    /// Guessing would silently seal to the wrong one.
    func testDeserializeRejectsTwoActiveEntries() {
        let sk = Base64URL.encode([UInt8](repeating: 1, count: 32))
        let sk2 = Base64URL.encode([UInt8](repeating: 2, count: 32))
        let payload = SerializedKeyring(v: 1, userId: "user-1", entries: [
            .init(version: 1, sk: sk, createdAt: "t", retiredAt: nil),
            .init(version: 2, sk: sk2, createdAt: "t", retiredAt: nil),
        ])

        XCTAssertThrowsError(try KeyringCoder.deserialize(payload)) { error in
            XCTAssertEqual(error as? KeyringError, .notExactlyOneActive(count: 2))
        }
    }

    func testDeserializeRejectsDuplicateVersions() {
        let sk = Base64URL.encode([UInt8](repeating: 1, count: 32))
        let payload = SerializedKeyring(v: 1, userId: "user-1", entries: [
            .init(version: 1, sk: sk, createdAt: "t", retiredAt: "t"),
            .init(version: 1, sk: sk, createdAt: "t", retiredAt: nil),
        ])

        XCTAssertThrowsError(try KeyringCoder.deserialize(payload)) { error in
            XCTAssertEqual(error as? KeyringError, .duplicateVersions)
        }
    }

    func testDeserializeRejectsAShortSecretKey() {
        let payload = SerializedKeyring(v: 1, userId: "user-1", entries: [
            .init(version: 4, sk: Base64URL.encode([UInt8](repeating: 1, count: 16)),
                  createdAt: "t", retiredAt: nil)
        ])

        XCTAssertThrowsError(try KeyringCoder.deserialize(payload)) { error in
            XCTAssertEqual(error as? KeyringError, .badSecretKeyLength(version: 4))
        }
    }

    func testEntryLookupResolvesByVersion() throws {
        let keyring = try makeKeyring(versions: [1, 2, 5])

        XCTAssertEqual(keyring.entry(forVersion: 2)?.version, 2)
        XCTAssertNil(keyring.entry(forVersion: 3))
    }
}
