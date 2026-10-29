import XCTest
import Sodium
@testable import NeutrinoCrypto

// MARK: - Pairing, sender half
//
// The half a Mac runs: scan QR-A, seal the keyring to it, show QR-B. Ported from the macOS client's
// own copy when it adopted this package; the receiver half beside it is what the phones run, so the
// round trip below is the two shipped implementations talking to each other.

final class PairingSenderTests: XCTestCase {

    private func makeKeyring(versions: [Int] = [1]) throws -> Keyring {
        let sodium = Sodium()
        let entries = try versions.map { version -> KeyringEntry in
            let pair = try XCTUnwrap(sodium.box.keyPair())
            return KeyringEntry(version: version,
                                publicKey: pair.publicKey,
                                secretKey: pair.secretKey,
                                createdAt: "2026-01-0\(version)T00:00:00Z",
                                retiredAt: version == versions.max() ? nil : "2026-02-01T00:00:00Z")
        }
        return Keyring(userId: "user-1", entries: entries)
    }

    /// A receiver's offer built by hand, for the tests that need its secret half.
    private func makeOffer() throws -> (offer: PairingOffer, publicKey: [UInt8], secretKey: [UInt8]) {
        let sodium = Sodium()
        let pair = try XCTUnwrap(sodium.box.keyPair())
        let nonce = try XCTUnwrap(sodium.randomBytes.buf(length: 16))
        let offer = PairingOffer(t: PairingOffer.type, v: 1,
                                 pk: Base64URL.encode(pair.publicKey),
                                 n: Base64URL.encode(nonce))
        return (offer, pair.publicKey, pair.secretKey)
    }

    /// Sender and receiver halves of this package, end to end — the exchange a Mac and a phone run.
    func testTheReceiverOpensWhatTheSenderSealed() throws {
        let keyring = try makeKeyring(versions: [1, 2])
        let session = Pairing.createSession()

        let offer = try Pairing.parseOffer(try Pairing.encode(session.offer))
        let reply = try Pairing.encode(try Pairing.respond(keyring: keyring, offer: offer))
        let response = try Pairing.parseResponse(reply)
        let received = try Pairing.accept(response, session: session, userId: "user-1")

        XCTAssertEqual(received, keyring)
        XCTAssertEqual(Pairing.confirmationCode(offer: session.offer, response: response),
                       Pairing.confirmationCode(offer: offer, response: response))
    }

    /// Only the holder of the ephemeral secret can read the keyring, so a photograph of either code
    /// yields nothing.
    func testReplyIsOpenableOnlyByTheOfferedKey() throws {
        let keyring = try makeKeyring(versions: [1, 2])
        let (offer, publicKey, secretKey) = try makeOffer()

        let response = try Pairing.respond(keyring: keyring, offer: offer)

        let opened = try XCTUnwrap(Sodium().box.open(
            anonymousCipherText: try XCTUnwrap(Base64URL.decode(response.ct)),
            recipientPublicKey: publicKey,
            recipientSecretKey: secretKey
        ))
        let received = try KeyringCoder.decodeJSON(Data(opened))
        XCTAssertEqual(received.entries.map(\.secretKey), keyring.entries.map(\.secretKey))
        XCTAssertEqual(received.active?.version, 2)

        let (_, otherPublic, otherSecret) = try makeOffer()
        XCTAssertNil(Sodium().box.open(anonymousCipherText: try XCTUnwrap(Base64URL.decode(response.ct)),
                                       recipientPublicKey: otherPublic,
                                       recipientSecretKey: otherSecret))
    }

    /// The receiver rejects a reply whose nonce is not its own — a QR left on screen from an
    /// earlier attempt.
    func testReplyEchoesTheOfferNonce() throws {
        let (offer, _, _) = try makeOffer()
        let response = try Pairing.respond(keyring: try makeKeyring(), offer: offer)
        XCTAssertEqual(response.n, offer.n)
    }

    func testParseOfferRejectsAnythingElse() throws {
        XCTAssertThrowsError(try Pairing.parseOffer("not json")) { error in
            XCTAssertEqual(error as? PairingError, .notAPairingCode)
        }
        // A pairing *response* is well-formed JSON of the wrong type; accepting it would seal the
        // keyring to nothing.
        let response = PairingResponse(t: PairingResponse.type, v: 1, ct: "x", n: "y")
        XCTAssertThrowsError(try Pairing.parseOffer(try Pairing.encode(response))) { error in
            XCTAssertEqual(error as? PairingError, .notAPairingCode)
        }
    }

    /// A mis-scanned public key is reported as a bad code rather than surfacing later as an
    /// unexplained failure to encrypt.
    func testParseOfferRejectsAWrongLengthPublicKey() throws {
        let offer = PairingOffer(t: PairingOffer.type, v: 1,
                                 pk: Base64URL.encode([UInt8](repeating: 1, count: 16)),
                                 n: Base64URL.encode([UInt8](repeating: 2, count: 16)))
        XCTAssertThrowsError(try Pairing.parseOffer(try Pairing.encode(offer))) { error in
            XCTAssertEqual(error as? PairingError, .damagedOffer)
        }
    }

    /// The confirmation code is what makes an active relay visible: two exchanges that differ
    /// anywhere in the transcript must not produce the same six digits.
    func testConfirmationCodeDiffersWhenTheTranscriptDiffers() throws {
        let keyring = try makeKeyring()
        let (offerA, _, _) = try makeOffer()
        let (offerB, _, _) = try makeOffer()

        let codeA = Pairing.confirmationCode(offer: offerA,
                                             response: try Pairing.respond(keyring: keyring, offer: offerA))
        let codeB = Pairing.confirmationCode(offer: offerB,
                                             response: try Pairing.respond(keyring: keyring, offer: offerB))

        XCTAssertEqual(codeA.count, 6)
        XCTAssertTrue(codeA.allSatisfy(\.isNumber))
        XCTAssertNotEqual(codeA, codeB)
    }
}
