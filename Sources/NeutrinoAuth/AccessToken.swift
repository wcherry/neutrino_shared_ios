import Foundation
import NeutrinoCore

// MARK: - AccessToken

/// Reads the claims the client needs out of the stored access token.
///
/// Deliberately not a verification of anything: the server checks the signature on every request,
/// and nothing here decides whether a caller is allowed to do something. It only saves a round trip
/// for facts the server has already signed and handed over.
public enum AccessToken {

    /// The signed-in user's id, from the token's `sub` claim.
    ///
    /// A user's root folder id *is* their user id (`GET /api/v1/drive/folders/{id}`), which is how
    /// a Drive listing addresses the root without calling `/api/v1/auth/me` first. Notes uses it to
    /// name the per-user keyring it stores.
    public static func currentUserID() -> String? {
        guard let token = KeychainService.load(forKey: NeutrinoApp.current.accessTokenKey) else {
            return nil
        }
        let segments = token.split(separator: ".")
        guard segments.count > 1 else { return nil }

        // A JWT payload is base64url without padding; `Data(base64Encoded:)` wants standard base64
        // with it — which is exactly what `Data(base64URLEncoded:)` normalizes.
        guard let data = Data(base64URLEncoded: String(segments[1])),
              let claims = try? JSONDecoder().decode(Claims.self, from: data) else { return nil }
        return claims.sub
    }

    /// The subset of a JWT's claims this reads.
    private struct Claims: Decodable {
        let sub: String
    }
}

// MARK: - AuthService

public extension AuthService {

    /// The signed-in user's id.
    ///
    /// Reads the token's `sub` claim first — it is already in hand and costs nothing — and falls
    /// back to `GET /auth/me` for a token whose payload this build cannot read. `async` for that
    /// fallback's sake; the common path does no I/O.
    func currentUserID() async -> String? {
        if let id = AccessToken.currentUserID() { return id }
        if let id = profile?.id { return id }
        return await loadProfile()?.id
    }
}
