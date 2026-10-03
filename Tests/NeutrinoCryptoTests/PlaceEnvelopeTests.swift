import XCTest
import Sodium
import NeutrinoCrypto

// MARK: - PlaceEnvelope

/// `Fixtures/place_envelope_vectors.json` is sealed by the web's own `e2e-crypto`
/// (`scripts/generate_place_envelope_vectors.mjs`), so these prove NeutrinoCrypto opens what the
/// web writes. The web's tests read the same file the other way round.
final class PlaceEnvelopeTests: XCTestCase {

    private struct Vectors: Decodable {
        struct Key: Decodable { let publicKey: String; let secretKey: String }
        struct Case: Decodable {
            let name: String
            let keyVersion: Int
            let encryptedPayload: String
            let expected: PlaceEnvelope.Payload
        }
        struct Rejected: Decodable { let name: String; let encryptedPayload: String; let error: String }
        let keys: [String: Key]
        let cases: [Case]
        let rejected: [Rejected]
    }

    private func vectors() throws -> Vectors {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "place_envelope_vectors", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testOpensWhatTheWebSealed() throws {
        let vectors = try vectors()
        XCTAssertFalse(vectors.cases.isEmpty)
        for vector in vectors.cases {
            let key = try XCTUnwrap(vectors.keys[String(vector.keyVersion)], vector.name)
            XCTAssertEqual(try PlaceEnvelope.keyVersion(of: vector.encryptedPayload), vector.keyVersion, vector.name)
            let payload = try PlaceEnvelope.open(vector.encryptedPayload,
                                                 publicKey: XCTUnwrap(Base64URL.decode(key.publicKey)),
                                                 secretKey: XCTUnwrap(Base64URL.decode(key.secretKey)))
            XCTAssertEqual(payload, vector.expected, vector.name)
        }
    }

    func testRejectsWhatItCantRead() throws {
        for vector in try vectors().rejected {
            XCTAssertThrowsError(try PlaceEnvelope.keyVersion(of: vector.encryptedPayload), vector.name) { error in
                switch (vector.error, error as? PlaceEnvelope.Failure) {
                case ("unsupportedVersion", .unsupportedVersion?), ("malformed", .malformed?): break
                default: XCTFail("\(vector.name): expected \(vector.error), got \(error)")
                }
            }
        }
    }

    func testTheWrongKeyCantOpenIt() throws {
        let vectors = try vectors()
        let vector = try XCTUnwrap(vectors.cases.first { $0.keyVersion == 2 })
        let other = try XCTUnwrap(vectors.keys["1"])
        XCTAssertThrowsError(try PlaceEnvelope.open(vector.encryptedPayload,
                                                    publicKey: XCTUnwrap(Base64URL.decode(other.publicKey)),
                                                    secretKey: XCTUnwrap(Base64URL.decode(other.secretKey))))
    }

    /// What NeutrinoCrypto seals has the shape the web reads, and holds nothing in the clear.
    func testSealsTheSharedShape() throws {
        let pair = try XCTUnwrap(Sodium().box.keyPair())
        let payload = PlaceEnvelope.Payload(name: "Home", lat: 51.501364, lng: -0.14189, radiusM: 150)
        let sealed = try PlaceEnvelope.seal(payload, publicKey: pair.publicKey, keyVersion: 3)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sealed.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["v", "keyVersion", "key", "data"])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["keyVersion"] as? Int, 3)
        XCTAssertFalse(sealed.contains("Home"))
        XCTAssertFalse(sealed.contains("51.5"))

        XCTAssertEqual(try PlaceEnvelope.open(sealed, publicKey: pair.publicKey, secretKey: pair.secretKey), payload)
        // Through the Drive primitives the web's `decryptFileKey` / `decryptMetadata` mirror.
        let dek = try DriveFileCrypto.openDEK(XCTUnwrap(object["key"] as? String),
                                              publicKey: pair.publicKey, secretKey: pair.secretKey)
        let json = try DriveFileCrypto.decrypt(Data(XCTUnwrap(Base64URL.decode(XCTUnwrap(object["data"] as? String)))), dek: dek)
        XCTAssertEqual(try JSONDecoder().decode(PlaceEnvelope.Payload.self, from: json), payload)
    }

    /// Each seal has its own key, so two saves of one place don't show they are the same.
    func testEverySealIsFresh() throws {
        let pair = try XCTUnwrap(Sodium().box.keyPair())
        let payload = PlaceEnvelope.Payload(name: "Work", lat: 1, lng: 2, radiusM: 100)
        XCTAssertNotEqual(try PlaceEnvelope.seal(payload, publicKey: pair.publicKey, keyVersion: 1),
                          try PlaceEnvelope.seal(payload, publicKey: pair.publicKey, keyVersion: 1))
    }
}
