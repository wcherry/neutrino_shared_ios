import Foundation
import CryptoKit
import os
import NeutrinoCore
import NeutrinoAuth

// MARK: - KeyProvisioningService
//
// Giving this device an identity: minting the account's *first* key, or adopting the keyring a
// recovery kit carries. Both were previously things only the web app could do.
//
// The identity is the *account's*, not one editor's: a key minted in Sheets is what Docs, Notes and
// the web all seal to, which is why this lives in the shared package rather than in whichever app
// happened to need it first.
//
// ── Minting ──────────────────────────────────────────────────────────────────
//
// The web equivalent is `provisionKeyring` in `web/packages/auth/src/e2e-keys.ts`, and this is
// deliberately the same three steps in the same order:
//
//   1. mint a Curve25519 keypair — `crypto_box_keypair`, which is what X25519 produces
//   2. store the secret half where this device keeps keys (the Keychain, via `KeyImportService`;
//      on the web, IndexedDB)
//   3. publish the *public* half to the account's directory, so collaborators can seal to it
//
// and then hand back the recovery kit, which is the only copy of the identity that survives losing
// this device. The secret half is never transmitted.
//
// ── Why this refuses to run on an account that already has a key ──────────────
// `POST /auth/keys` is append-only: publishing a *different* key retires the current version and
// creates the next one (`repository.rs::publish_public_key`). On an account that already has a key
// that is a rotation, and every DEK sealed to the old version would need re-sealing by a client
// holding the old secret — which this device, by definition, does not have. So provisioning is only
// ever offered to an account with nothing published; a device that is merely missing the key needs
// the QR code, the key file, or its recovery kit instead. This mirrors the 'none' versus
// 'needs-device' split `getKeyringState` makes on the web.

// MARK: - Account key state

/// What the account's directory says, which is what decides whether a key may be minted here.
///
/// The empty case is `unpublished` rather than `none` on purpose: `state == .none` against an
/// optional binds to `Optional.none`, so a check for "this account has no key" would silently
/// become a check for "the request failed".
public enum AccountKeyState: Equatable {
    /// Nothing published — a new account, safe to provision.
    case unpublished
    /// The account already has an identity; this device needs a copy, not a new one. The public
    /// half comes with it, because that is what a recovery kit is checked against.
    case published(version: Int, publicKey: String)
}

// MARK: - Restore outcome

/// What restoring a recovery kit actually recovered.
public struct RecoveryKitRestoreOutcome: Equatable {
    /// The version new files will now be sealed to.
    public let activeVersion: Int
    /// Retired versions the kit brought across, which is what makes older files open.
    public let archivedVersions: Int
    /// True when the account's directory held no key and this restore repopulated it.
    public let republished: Bool

    public init(activeVersion: Int, archivedVersions: Int, republished: Bool) {
        self.activeVersion = activeVersion
        self.archivedVersions = archivedVersions
        self.republished = republished
    }
}

// MARK: - Errors

public enum KeyProvisioningError: LocalizedError, Equatable {
    case notAuthenticated
    case alreadyPublished
    case deviceAlreadyHasKey
    case couldNotStore
    case serverError(statusCode: Int)
    case networkError(String)
    case kitDoesNotMatchAccount
    case accountPublishesNoKey

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You are signed out. Sign in and try again."
        case .alreadyPublished:
            return "This account already has an encryption key. Bring it to this device with your "
                 + "recovery kit or the key code shown on the web — creating a new one here would "
                 + "leave your existing \(NeutrinoApp.current.contentNoun) unreadable."
        case .deviceAlreadyHasKey:
            return "This device already holds an encryption key."
        case .couldNotStore:
            return "Could not save the new key to this device\u{2019}s Keychain."
        case .serverError(let code):
            return "The server returned an error (\(code))."
        case .networkError:
            return "A network error occurred. Please check your connection."
        case .kitDoesNotMatchAccount:
            return "This recovery kit holds a different key from the one your account uses now. It "
                 + "may belong to another account, or date from before your key was replaced — in "
                 + "which case you need a kit exported since then, or the key code from the web."
        case .accountPublishesNoKey:
            return "Your account has published no encryption key, so there is nothing for this kit "
                 + "to restore. Set up a new key instead."
        }
    }
}

// MARK: - Service

@MainActor
public final class KeyProvisioningService: ObservableObject {

    private let logger = Logger(subsystem: NeutrinoApp.current.logSubsystem,
                                category: "KeyProvisioningService")

    public weak var authService: AuthService?

    /// Injected in tests as a `MockURLProtocol`-backed session, as the other services take one.
    private let session: URLSession

    public init(session: URLSession = .shared, authService: AuthService? = nil) {
        self.session = session
        self.authService = authService
    }

    private var baseURL: String { AuthService.baseURL }

    // MARK: - State

    /// Whether this account has ever published an identity key.
    public func accountKeyState() async throws -> AccountKeyState {
        guard let userID = AccessToken.currentUserID() else {
            throw KeyProvisioningError.notAuthenticated
        }
        let token = try await authorizedToken()

        guard let url = URL(string: baseURL + "/api/v1/auth/users/\(userID)/public-key") else {
            throw KeyProvisioningError.serverError(statusCode: 0)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw KeyProvisioningError.serverError(statusCode: 0)
        }
        // 404 is the answer, not a failure: it is how the server says "this account has published
        // nothing", which is the one state in which a key may be minted here.
        if http.statusCode == 404 { return .unpublished }
        guard (200..<300).contains(http.statusCode) else {
            throw KeyProvisioningError.serverError(statusCode: http.statusCode)
        }
        let published = try decode(PublicKeyDTO.self, from: data)
        return .published(version: published.version, publicKey: published.publicKey)
    }

    /// True when this device could mint a key: it holds none, and the account publishes none.
    public func canProvision() async -> Bool {
        guard !KeyImportService.hasStoredKeys() else { return false }
        // A state that could not be fetched is not an empty one: offering to mint a key because the
        // network was down is how an account ends up with its identity rotated away.
        guard let state = try? await accountKeyState() else { return false }
        return state == .unpublished
    }

    // MARK: - Provisioning

    /// Mint this account's identity key, store it, publish the public half, and return the
    /// recovery kit.
    ///
    /// The kit is shown once and never again — it is derived from the secret key, not stored — so a
    /// caller that discards the return value has thrown away the user's only backup.
    @discardableResult
    public func provisionIdentity() async throws -> String {
        guard AccessToken.currentUserID() != nil else { throw KeyProvisioningError.notAuthenticated }
        guard !KeyImportService.hasStoredKeys() else { throw KeyProvisioningError.deviceAlreadyHasKey }
        guard try await accountKeyState() == .unpublished else {
            throw KeyProvisioningError.alreadyPublished
        }

        // X25519. libsodium's `crypto_box` keys are exactly these, which is what makes a key minted
        // here interchangeable with one minted on the web.
        let secretKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKeyB64 = base64URL(secretKey.publicKey.rawRepresentation)

        // Stored before it is published, deliberately: publishing first would advertise a key that
        // a failed Keychain write means this device cannot use, and the account would be left
        // needing a recovery for a key nobody ever held.
        let bundle = KeyBundle(publicKey: publicKeyB64,
                               privateKey: base64URL(secretKey.rawRepresentation),
                               keyVersion: "1")
        KeyImportService.storeKeys(bundle)
        guard KeyImportService.hasStoredKeys() else {
            KeyImportService.removeKeys()
            throw KeyProvisioningError.couldNotStore
        }

        let published: PublicKeyDTO
        do {
            published = try await publish(publicKey: publicKeyB64)
        } catch {
            // Nothing has been encrypted with it yet, so rolling back is free — and leaving an
            // unpublished key in place would make every later "set up encryption" refuse.
            KeyImportService.removeKeys()
            throw error
        }

        // The version the server assigned is authoritative. It is 1 for the account this is allowed
        // to run on; it would differ only if another device published between the check above and
        // this call, and then the kit and the Keychain must both say what the server says.
        if published.version != 1 {
            logger.error("provisionIdentity: server assigned version \(published.version, privacy: .public), not 1")
            KeyImportService.storeKeys(KeyBundle(publicKey: bundle.publicKey,
                                                 privateKey: bundle.privateKey,
                                                 keyVersion: String(published.version)))
        }

        logger.info("provisionIdentity: minted and published version \(published.version, privacy: .public)")
        return RecoveryKit.export(entries: [
            RecoveryKit.Entry(version: published.version,
                              secretKey: secretKey.rawRepresentation),
        ])
    }

    // MARK: - Restoring from a recovery kit

    /// Adopt the keyring a printed recovery kit carries: the active key becomes this device's, and
    /// every retired version in the kit goes to `KeyArchive` so older files open too.
    ///
    /// The kit names no account — it is key material and nothing else — so the account it is being
    /// restored onto is what binds it, and the binding is checked rather than assumed. A kit whose
    /// active key is not the one the account publishes is refused: it belongs to somebody else, or
    /// it was printed before a rotation, and adopting it would make this device seal new files
    /// to a key no collaborator would use. That check is also what makes this safe where minting is
    /// not — nothing here can retire the account's current key.
    @discardableResult
    public func restoreFromRecoveryKit(_ text: String) async throws -> RecoveryKitRestoreOutcome {
        guard AccessToken.currentUserID() != nil else { throw KeyProvisioningError.notAuthenticated }

        let entries = try RecoveryKit.import(text)
        // `RecoveryKit.import` has already established there is exactly one.
        guard let active = entries.first(where: { !$0.isRetired }) else {
            throw RecoveryKitError.noSingleActiveKey
        }
        let activePublicKey = base64URL(try publicKey(for: active.secretKey))

        var activeVersion = active.version
        var republished = false

        switch try await accountKeyState() {
        case .published(let version, let publicKey):
            guard publicKey == activePublicKey else {
                throw KeyProvisioningError.kitDoesNotMatchAccount
            }
            // The directory's numbering is what `file_key_refs.key_version` points at, so where the
            // kit and the server disagree about the same key's number, the server is right.
            if version != active.version {
                logger.error("restore: kit calls the active key v\(active.version, privacy: .public), the account calls it v\(version, privacy: .public)")
                activeVersion = version
            }

        case .unpublished:
            // A kit exists only because a key was once published, so an empty directory means the
            // publish never landed. Repairing that is only unambiguous for a keyring that never
            // rotated; anything else, and there is no way to tell which version the account lost.
            guard active.version == 1, entries.count == 1 else {
                throw KeyProvisioningError.accountPublishesNoKey
            }
            _ = try await publish(publicKey: activePublicKey)
            republished = true
        }

        // Retired keys first: an interrupted restore that left the active key in place with no
        // archive would look complete while older files silently failed to open.
        let retired = try entries.filter(\.isRetired).map { entry in
            StoredKeyPair(version: entry.version,
                          publicKey: base64URL(try publicKey(for: entry.secretKey)),
                          privateKey: base64URL(entry.secretKey))
        }
        KeyArchive.store(retired)

        KeyImportService.storeKeys(KeyBundle(publicKey: activePublicKey,
                                             privateKey: base64URL(active.secretKey),
                                             keyVersion: String(activeVersion)))
        guard KeyImportService.hasStoredKeys() else {
            KeyImportService.removeKeys()
            throw KeyProvisioningError.couldNotStore
        }

        logger.info("restore: adopted v\(activeVersion, privacy: .public) with \(retired.count, privacy: .public) retired key(s)")
        return RecoveryKitRestoreOutcome(activeVersion: activeVersion,
                                         archivedVersions: retired.count,
                                         republished: republished)
    }

    /// The public half of a raw X25519 secret key, derived rather than trusted — the kit carries
    /// secret keys only, for exactly this reason.
    private func publicKey(for secretKey: Data) throws -> Data {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secretKey)
            .publicKey.rawRepresentation
    }

    // MARK: - Publishing

    private func publish(publicKey: String) async throws -> PublicKeyDTO {
        let token = try await authorizedToken()
        guard let url = URL(string: baseURL + "/api/v1/auth/keys") else {
            throw KeyProvisioningError.serverError(statusCode: 0)
        }

        struct Body: Encodable { let publicKey: String }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Body(publicKey: publicKey))

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw KeyProvisioningError.serverError(statusCode: code)
        }
        return try decode(PublicKeyDTO.self, from: data)
    }

    // MARK: - Helpers

    private func authorizedToken() async throws -> String {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            throw KeyProvisioningError.notAuthenticated
        }
        return token
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw KeyProvisioningError.networkError(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            // camelCase on the wire, like the other auth endpoints.
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw KeyProvisioningError.serverError(statusCode: 0)
        }
    }

    private func base64URL(_ data: Data) -> String {
        AuthService.base64URLEncode(data)
    }
}

// MARK: - Wire types

/// `PublicKeyResponse` from `src/auth/dto.rs`.
private struct PublicKeyDTO: Decodable {
    let userId: String
    let publicKey: String
    let version: Int
}
