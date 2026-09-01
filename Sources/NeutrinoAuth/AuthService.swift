import Foundation
import CryptoKit
import os.log
import NeutrinoCore

// MARK: - AuthError

public enum AuthError: LocalizedError, Equatable {
    case invalidCredentials
    case twoFactorRequired
    case invalidTwoFactorCode
    case stateMismatch
    case missingCode
    case tokenExchangeFailed(String)
    case networkError(String)
    case serverError(statusCode: Int)
    case configuration
    case emailAlreadyRegistered
    /// A rule the server enforces that the form did not — its message names which one.
    case registrationRejected(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:            return "Invalid email or password."
        case .twoFactorRequired:             return "Enter the code from your authenticator app."
        case .invalidTwoFactorCode:          return "That code was not accepted. Try the current one."
        case .stateMismatch:                 return "Authorization failed — security check failed."
        case .missingCode:                   return "Authorization failed — no code returned."
        case .tokenExchangeFailed(let msg):  return "Token exchange failed: \(msg)"
        case .networkError:                  return "A network error occurred. Please check your connection."
        case .serverError(let code):         return "Server error (\(code)). Please try again later."
        case .configuration:                 return "Authentication is misconfigured."
        case .emailAlreadyRegistered:        return "That email already has an account. Sign in instead."
        case .registrationRejected(let msg): return msg
        }
    }
}

// MARK: - AuthService

/// Three-step OAuth PKCE flow (no browser required), shared by every Neutrino iOS app:
///
///   1. `POST /api/v1/auth/login`      → short-lived session token
///   2. `GET  /api/v1/oauth/authorize` → 302 `Location: <redirect_uri>?code=…&state=…`
///      (Bearer session token, redirect suppressed, code read from the Location header)
///   3. `POST /api/v1/oauth/token`     → long-lived access + refresh tokens
///
/// Step 1 also carries `X-Device-Name`, which is how a device registers itself — see
/// `DeviceIdentity`. Sign-up prefixes the flow with `POST /api/v1/auth/register`, which creates
/// the account and nothing else; the session comes from the ordinary three steps afterwards.
///
/// ## What was reconciled here
///
/// The five apps had diverged badly — Drive's copy and Docs' differed on 377 of 454 lines. This is
/// the union, not a pick:
///
/// - **Two-factor** came from Drive, which was alone in handling a `requiresTwoFactor` response.
///   The other four decoded `accessToken` as required and turned "this account has 2FA" into an
///   unreadable decoding error with no way forward.
/// - **Registration** came from Docs, the only app with a sign-up screen.
/// - **Device registration** (`X-Device-Name`) came from Docs, Sheets and Photos; Drive and Notes
///   were signing in without naming themselves, so their sessions listed as "Unknown device".
/// - **Keychain prefixes and client ids** were per-app constants and are now `NeutrinoAppConfig`.
///
/// Both flags are gates rather than statements about the server: the endpoints behave the same for
/// every client id, so an app opts in when its screens have been through QA.
@MainActor
public final class AuthService: ObservableObject {

    // MARK: - Published State

    @Published public var isAuthenticated: Bool = false
    @Published public var loginError: String?
    @Published public var isLoggingIn: Bool = false

    /// Kept apart from `loginError` / `isLoggingIn` so the sign-up sheet and the login screen
    /// underneath it never show each other's state.
    @Published public var registerError: String?
    @Published public var isRegistering: Bool = false

    /// True once the server has answered a sign-in with "this account has two-factor enabled".
    ///
    /// Drives the code field on the login screen. It stays set until the sign-in succeeds, since a
    /// wrong code has to be re-entered against the same account rather than sending the user back
    /// to the start.
    @Published public var requiresTwoFactorCode: Bool = false

    /// True from the moment this session creates an account until encryption setup is done or
    /// declined. Deliberately not persisted: a key that was skipped is offered again from
    /// Settings, not by a flag that outlives the launch that set it.
    @Published public private(set) var didRegisterThisSession: Bool = false

    // MARK: - Configuration

    private var config: NeutrinoAppConfig { NeutrinoApp.current }

    /// The server this app talks to. Settings writes it; every service reads it — including from
    /// off the main actor, hence `nonisolated`.
    public nonisolated static var baseURL: String { NeutrinoStorage.serverHost }

    public nonisolated static var accessTokenKey:  String { NeutrinoApp.current.accessTokenKey }
    public nonisolated static var refreshTokenKey: String { NeutrinoApp.current.refreshTokenKey }
    public nonisolated static var tokenExpiryKey:  String { NeutrinoApp.current.tokenExpiryKey }
    public nonisolated static var serverHostKey:   String { NeutrinoApp.current.serverHostKey }
    public nonisolated static var defaultHost:     String { NeutrinoApp.current.defaultHost }

    private var registerURL:  String { Self.baseURL + "/api/v1/auth/register" }
    private var loginURL:     String { Self.baseURL + "/api/v1/auth/login" }
    private var authorizeURL: String { Self.baseURL + "/api/v1/oauth/authorize" }
    private var tokenURL:     String { Self.baseURL + "/api/v1/oauth/token" }

    // MARK: - Private

    private let logger: Logger

    /// Both sessions are built from this. Injected in tests as a configuration carrying
    /// `MockURLProtocol`, which is what makes the whole flow — including the redirect step —
    /// exercisable without a server.
    private let configuration: URLSessionConfiguration

    private lazy var session = URLSession(configuration: configuration)

    /// Step 2 needs the 302 itself, not what it points at.
    private lazy var noRedirectSession = URLSession(configuration: configuration,
                                                    delegate: NoRedirectDelegate(),
                                                    delegateQueue: nil)

    // MARK: - Init

    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
        self.logger = Logger(subsystem: NeutrinoApp.current.logSubsystem, category: "AuthService")
        isAuthenticated = KeychainService.load(forKey: NeutrinoApp.current.accessTokenKey) != nil
    }

    // MARK: - Public API

    /// Runs the full three-step flow, registering this device by name along the way.
    ///
    /// Sets `loginError` rather than throwing — the login screen binds to it.
    ///
    /// An account with 2FA answers step 1 with `requiresTwoFactor` and no tokens. That is not an
    /// error, it is the server asking for the second factor: `requiresTwoFactorCode` is published
    /// so the screen shows the field, and the same call is made again with `totpCode`.
    public func login(email: String, password: String, totpCode: String? = nil) async {
        loginError = nil
        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            try await signIn(email: email, password: password, totpCode: totpCode)
            requiresTwoFactorCode = false
            logger.debug("login succeeded")
        } catch AuthError.twoFactorRequired {
            // Only a prompt on the first pass. Once the field is on screen, an unaccepted code
            // comes back the same way, and repeating "enter the code" reads as though nothing
            // happened at all.
            loginError = requiresTwoFactorCode
                ? AuthError.invalidTwoFactorCode.localizedDescription
                : nil
            requiresTwoFactorCode = true
            logger.debug("login requires second factor")
        } catch {
            logger.error("login failed: \(error.localizedDescription, privacy: .public)")
            loginError = error.localizedDescription
        }
    }

    /// Creates an account and signs straight into it, mirroring the web sign-up page.
    ///
    /// `POST /auth/register` only writes the user row — it returns no tokens — so the session
    /// comes from the ordinary three-step flow afterwards, which is also what registers this
    /// device.
    ///
    /// A sign-in that fails *after* the account exists says so explicitly: the account is not
    /// lost, and telling somebody "registration failed" when it did not would send them round to
    /// create a second one.
    public func register(name: String, email: String, password: String) async {
        registerError = nil
        isRegistering = true
        defer { isRegistering = false }

        var accountCreated = false
        do {
            try await createAccount(name: name, email: email, password: password)
            accountCreated = true
            try await signIn(email: email, password: password, totpCode: nil)
            didRegisterThisSession = true
            logger.debug("registration succeeded")
        } catch {
            logger.error("registration failed: \(error.localizedDescription, privacy: .public)")
            registerError = accountCreated
                ? "Your account was created, but signing in failed: \(error.localizedDescription)"
                : error.localizedDescription
        }
    }

    /// The three-step flow itself, shared by `login` and `register`.
    private func signIn(email: String, password: String, totpCode: String?) async throws {
        let sessionToken = try await step1Login(email: email, password: password, totpCode: totpCode)
        let (verifier, challenge) = Self.pkceValues()
        let state = Self.randomBase64URL(byteCount: 16)
        let code = try await step2Authorize(sessionToken: sessionToken, challenge: challenge,
                                            state: state, expectedState: state)
        try await step3Exchange(code: code, verifier: verifier)
    }

    /// Clears the session. The encryption key pair is deliberately *not* removed — signing back in
    /// should not mean re-importing a key, and Settings offers key removal explicitly.
    public func logout() {
        KeychainService.delete(forKey: config.accessTokenKey)
        KeychainService.delete(forKey: config.refreshTokenKey)
        KeychainService.delete(forKey: config.tokenExpiryKey)
        isAuthenticated = false
        loginError = nil
        registerError = nil
        requiresTwoFactorCode = false
        didRegisterThisSession = false
        logger.debug("logged out")
    }

    /// Called when first-run encryption setup finishes — or the user moves on without it.
    public func encryptionSetupFinished() {
        didRegisterThisSession = false
    }

    public func accessToken() -> String? {
        KeychainService.load(forKey: config.accessTokenKey)
    }

    /// Refreshes the access token when it is within a minute of expiring.
    ///
    /// Every service calls this before an authorized request, so it must stay cheap in the common
    /// case — the expiry check is a Keychain read and a date comparison, with no network traffic.
    public func refreshTokenIfNeeded() async {
        if let raw = KeychainService.load(forKey: config.tokenExpiryKey),
           let expiry = ISO8601DateFormatter().date(from: raw),
           expiry.timeIntervalSinceNow > 60 {
            return
        }

        guard let refreshToken = KeychainService.load(forKey: config.refreshTokenKey) else {
            logout()
            return
        }

        do {
            let response = try await postToken(formFields: [
                "grant_type":    "refresh_token",
                "refresh_token": refreshToken,
                "client_id":     config.oauthClientID,
            ])
            persist(response)
            logger.debug("token refreshed")
        } catch AuthError.invalidCredentials {
            // The refresh token itself was rejected — the session is over, not merely stale.
            logger.error("refresh rejected; signing out")
            logout()
        } catch {
            // Anything else (offline, 5xx) leaves the existing token in place: an unreachable
            // server is not a reason to sign somebody out of an offline-first app.
            logger.error("refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Registration

    private func createAccount(name: String, email: String, password: String) async throws {
        guard let url = URL(string: registerURL) else { throw AuthError.configuration }

        struct Body: Encodable { let name: String; let email: String; let password: String }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(name: name, email: email, password: password))

        let (data, response) = try await perform(request, on: session)
        guard let http = response as? HTTPURLResponse else { throw AuthError.serverError(statusCode: 0) }

        switch http.statusCode {
        case 200...299:
            return
        case 409:
            throw AuthError.emailAlreadyRegistered
        case 400:
            // The form checks the same rules the server does, so a 400 here means it enforces one
            // this client does not know about — worth showing verbatim rather than generically.
            throw AuthError.registrationRejected(
                Self.serverMessage(from: data) ?? "Please check your details and try again."
            )
        default:
            throw AuthError.serverError(statusCode: http.statusCode)
        }
    }

    /// Neutrino wraps errors as `{"error": {"code", "message"}}`.
    private static func serverMessage(from data: Data) -> String? {
        struct Envelope: Decodable { struct Body: Decodable { let message: String }; let error: Body }
        let message = try? JSONDecoder().decode(Envelope.self, from: data).error.message
        return (message?.isEmpty ?? true) ? nil : message
    }

    // MARK: - Step 1: Session login

    private func step1Login(email: String, password: String, totpCode: String?) async throws -> String {
        guard let url = URL(string: loginURL) else { throw AuthError.configuration }

        // `totpCode` is omitted rather than sent empty: the server's field is an `Option<String>`,
        // and an empty string is a code that was supplied and is wrong.
        struct Body: Encodable {
            let email: String
            let password: String
            let totpCode: String?
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Device registration: this populates `device_name` on the session row the server creates,
        // which `GET /auth/sessions` later lists.
        request.setValue(DeviceIdentity.deviceName, forHTTPHeaderField: DeviceIdentity.deviceNameHeader)
        request.httpBody = try JSONEncoder().encode(
            Body(email: email,
                 password: password,
                 totpCode: config.supportsTwoFactor
                     ? totpCode?.trimmingCharacters(in: .whitespaces).nilIfEmpty
                     : nil)
        )

        let (data, response) = try await perform(request, on: session)
        guard let http = response as? HTTPURLResponse else { throw AuthError.serverError(statusCode: 0) }

        switch http.statusCode {
        case 200...299:
            // The tokens are flattened alongside `requiresTwoFactor` and absent when the server
            // wants a second factor, so both halves are optional. Decoding `accessToken` as
            // required is what used to turn "2FA is on for this account" into an unreadable
            // decoding error with no way forward.
            struct SessionResponse: Decodable {
                let accessToken: String?
                let requiresTwoFactor: Bool?
            }
            let decoded = try JSONDecoder().decode(SessionResponse.self, from: data)
            if let token = decoded.accessToken { return token }
            if decoded.requiresTwoFactor == true { throw AuthError.twoFactorRequired }
            throw AuthError.serverError(statusCode: http.statusCode)
        case 401:
            // A rejected TOTP code arrives as a 401 like any other bad credential. Once the code
            // field is up, the credentials are known good, so this is the code.
            throw requiresTwoFactorCode ? AuthError.twoFactorRequired : AuthError.invalidCredentials
        default:
            throw AuthError.serverError(statusCode: http.statusCode)
        }
    }

    // MARK: - Step 2: Authorize (redirect suppressed)

    private func step2Authorize(sessionToken: String, challenge: String,
                                state: String, expectedState: String) async throws -> String {
        guard var components = URLComponents(string: authorizeURL) else {
            throw AuthError.configuration
        }
        components.queryItems = [
            URLQueryItem(name: "client_id",             value: config.oauthClientID),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "redirect_uri",          value: config.oauthRedirectURI),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state",                 value: state),
        ]
        guard let url = components.url else { throw AuthError.configuration }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await perform(request, on: noRedirectSession)

        guard let http = response as? HTTPURLResponse,
              (300...399).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"),
              let redirectURL = URL(string: location),
              let redirectComponents = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false)
        else {
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            throw AuthError.tokenExchangeFailed(body)
        }

        guard let code = redirectComponents.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthError.missingCode
        }

        // Checked before the code is used: a mismatched state means the response is not an answer
        // to the request this client made.
        let returnedState = redirectComponents.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        guard returnedState == expectedState else { throw AuthError.stateMismatch }

        return code
    }

    // MARK: - Step 3: Exchange code for tokens

    private func step3Exchange(code: String, verifier: String) async throws {
        let response = try await postToken(formFields: [
            "grant_type":    "authorization_code",
            "code":          code,
            "code_verifier": verifier,
            "redirect_uri":  config.oauthRedirectURI,
            "client_id":     config.oauthClientID,
        ])
        persist(response)
    }

    // MARK: - Token endpoint

    private func postToken(formFields: [String: String]) async throws -> TokenResponse {
        guard let url = URL(string: tokenURL) else { throw AuthError.configuration }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formFields
            .map { key, value in "\(key)=\(Self.formEncode(value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await perform(request, on: session)
        guard let http = response as? HTTPURLResponse else { throw AuthError.serverError(statusCode: 0) }

        switch http.statusCode {
        case 200...299:
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        case 401:
            throw AuthError.invalidCredentials
        default:
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            throw AuthError.tokenExchangeFailed(body)
        }
    }

    // MARK: - Helpers

    private func perform(_ request: URLRequest, on session: URLSession) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw AuthError.networkError(error.localizedDescription)
        }
    }

    private func persist(_ response: TokenResponse) {
        KeychainService.save(response.accessToken,  forKey: config.accessTokenKey)
        KeychainService.save(response.refreshToken, forKey: config.refreshTokenKey)
        let expiry = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        KeychainService.save(ISO8601DateFormatter().string(from: expiry), forKey: config.tokenExpiryKey)
        isAuthenticated = true
    }

    // MARK: - Encoding

    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - PKCE

    /// Verifier and its S256 challenge, per RFC 7636.
    public static func pkceValues() -> (verifier: String, challenge: String) {
        let verifier = randomBase64URL(byteCount: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return (verifier, base64URLEncode(Data(digest)))
    }

    public static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URLEncode(Data(bytes))
    }
}

// MARK: - Redirect suppression

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Helpers

private extension String {
    /// `nil` for an empty string, so an untouched text field encodes as an absent JSON field
    /// rather than a supplied-and-wrong value.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Models

private struct TokenResponse: Decodable {
    let accessToken:  String
    let refreshToken: String
    let expiresIn:    Int
    let tokenType:    String

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn    = "expires_in"
        case tokenType    = "token_type"
    }
}
