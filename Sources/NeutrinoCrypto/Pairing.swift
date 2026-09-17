import Foundation
import Sodium

// MARK: - Pairing
//
// Receiving the keyring from a device that already has it, offline, in two QR codes. This device is
// always the **receiver**; the web client is the sender.
//
//   1. receiver  generates an ephemeral X25519 keypair, shows QR-A
//                = { ephemeral public key, session nonce }
//   2. sender    scans QR-A, seals its keyring to that public key, shows QR-B
//   3. receiver  scans QR-B and opens it with the ephemeral secret key
//   4. both      display the same 6-digit code; the user confirms they match
//
// This replaces the old PIN-protected QR, which put the whole keypair behind a few digits — anyone
// who photographed that code held the identity after a few seconds on a GPU. Here, photographing
// either code yields nothing: QR-A is a public key, and QR-B can only be opened by the ephemeral
// secret half, which never leaves this device.
//
// Step 4 is what a passive photograph cannot defeat but an *active* relay could — someone
// substituting their own ephemeral key in QR-A and re-sealing to the real receiver would sit
// invisibly in the middle. The confirmation code is derived from both halves of the transcript, so
// a relay produces two different codes and the humans see it. It is a short authentication string,
// not a PIN: it authenticates a channel that already exists rather than protecting a blob at rest,
// which is why six digits is enough.
//
// Nothing here touches the network. Must stay byte-compatible with
// `web/packages/e2e-crypto/src/pairing.ts`.

// MARK: - Wire types

/// QR-A — what this device displays.
public struct PairingOffer: Codable, Sendable {
    public let t: String
    public let v: Int
    /// base64url ephemeral X25519 public key.
    public let pk: String
    /// base64url, 16 random bytes binding this exchange to this attempt.
    public let n: String

    public static let type = "neutrino-pair-offer"

    public init(t: String, v: Int, pk: String, n: String) {
        self.t = t
        self.v = v
        self.pk = pk
        self.n = n
    }
}

/// QR-B — what the sending device shows in reply.
public struct PairingResponse: Codable, Sendable {
    public let t: String
    public let v: Int
    /// base64url sealed-box ciphertext of the serialised keyring.
    public let ct: String
    /// Echo of the offer's nonce, so a stale QR-B is detected rather than opened.
    public let n: String

    public static let type = "neutrino-pair-response"

    public init(t: String, v: Int, ct: String, n: String) {
        self.t = t
        self.v = v
        self.ct = ct
        self.n = n
    }
}

// MARK: - Errors

public enum PairingError: LocalizedError, Equatable {
    case notAPairingCode
    case differentAttempt
    case couldNotOpen

    public var errorDescription: String? {
        switch self {
        case .notAPairingCode:
            return "That is not a Neutrino pairing code."
        case .differentAttempt:
            return "This code is from a different pairing attempt — start again."
        case .couldNotOpen:
            return "Could not read the pairing code — it may be damaged."
        }
    }
}

// MARK: - Session

/// Held between showing QR-A and scanning QR-B.
public final class PairingSession {
    public let offer: PairingOffer
    fileprivate let ephemeralPublicKey: [UInt8]
    fileprivate var ephemeralSecretKey: [UInt8]

    fileprivate init(offer: PairingOffer, publicKey: [UInt8], secretKey: [UInt8]) {
        self.offer = offer
        self.ephemeralPublicKey = publicKey
        self.ephemeralSecretKey = secretKey
    }

    /// Wipe the ephemeral secret once pairing finishes or is abandoned.
    public func close() {
        for i in ephemeralSecretKey.indices { ephemeralSecretKey[i] = 0 }
    }

    deinit { close() }
}

// MARK: - Pairing

public enum Pairing {

    private static let sodium = Sodium()
    private static let nonceBytes = 16
    private static let sasDigits = 6

    // MARK: Step 1 — the offer

    /// Mint the ephemeral pair and build QR-A.
    public static func createSession() -> PairingSession {
        let keyPair = sodium.box.keyPair()!
        let nonce = sodium.randomBytes.buf(length: nonceBytes)!
        let offer = PairingOffer(
            t: PairingOffer.type,
            v: 1,
            pk: Base64URL.encode(keyPair.publicKey),
            n: Base64URL.encode(nonce)
        )
        return PairingSession(offer: offer,
                              publicKey: keyPair.publicKey,
                              secretKey: keyPair.secretKey)
    }

    /// The JSON payload to render as QR-A.
    public static func encode(_ offer: PairingOffer) throws -> String {
        String(data: try JSONEncoder().encode(offer), encoding: .utf8) ?? ""
    }

    // MARK: Step 3 — accepting the reply

    public static func parseResponse(_ raw: String) throws -> PairingResponse {
        guard let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let parsed = try? JSONDecoder().decode(PairingResponse.self, from: data),
              parsed.t == PairingResponse.type,
              parsed.v == 1
        else {
            throw PairingError.notAPairingCode
        }
        return parsed
    }

    /// Open QR-B and recover the keyring.
    ///
    /// Rejects a response whose nonce is not this session's — that is a QR left on screen from an
    /// earlier attempt, and opening it would install a keyring the user did not just approve.
    public static func accept(
        _ response: PairingResponse,
        session: PairingSession,
        userId: String
    ) throws -> Keyring {
        guard response.n == session.offer.n else { throw PairingError.differentAttempt }

        guard let sealed = Base64URL.decode(response.ct),
              let opened = sodium.box.open(anonymousCipherText: sealed,
                                           recipientPublicKey: session.ephemeralPublicKey,
                                           recipientSecretKey: session.ephemeralSecretKey)
        else {
            throw PairingError.couldNotOpen
        }

        let keyring = try KeyringCoder.decodeJSON(Data(opened))
        guard keyring.userId == userId else { throw KeyringError.wrongAccount }
        return keyring
    }

    // MARK: Step 4 — the confirmation code

    /// The 6-digit code both devices show.
    ///
    /// Derived from the full transcript — offer nonce, offer public key, and the ciphertext
    /// actually exchanged — so a relay that substituted its own ephemeral key cannot make both ends
    /// agree. Length-prefixed because the parts are variable-length and must not be able to slide
    /// across each other.
    public static func confirmationCode(offer: PairingOffer, response: PairingResponse) -> String {
        var input: [UInt8] = []
        for part in ["neutrino-pair-sas-v1", offer.n, offer.pk, response.ct] {
            let bytes = Array(part.utf8)
            let length = UInt32(bytes.count)
            input.append(UInt8((length >> 24) & 0xFF))
            input.append(UInt8((length >> 16) & 0xFF))
            input.append(UInt8((length >> 8) & 0xFF))
            input.append(UInt8(length & 0xFF))
            input.append(contentsOf: bytes)
        }

        let digest = sodium.genericHash.hash(message: input, outputLength: 32)!
        // Fold four bytes into a number, then take the low digits. Modulo bias across 2^32 into
        // 10^6 is negligible and the code is not a secret — it only has to differ when the
        // transcripts differ.
        let value = (UInt32(digest[0]) << 24)
            | (UInt32(digest[1]) << 16)
            | (UInt32(digest[2]) << 8)
            | UInt32(digest[3])
        let modulus = UInt32(pow(10.0, Double(sasDigits)))
        return String(format: "%0\(sasDigits)u", value % modulus)
    }
}
