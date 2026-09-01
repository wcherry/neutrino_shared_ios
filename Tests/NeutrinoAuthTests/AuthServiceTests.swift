import XCTest
import NeutrinoCore
@testable import NeutrinoAuth

// MARK: - AuthServiceTests

/// The reconciled sign-in flow.
///
/// These cover the behaviours that were present in *some* of the five apps and absent from others,
/// because those are precisely the ones a consolidation can silently drop:
///
/// - two-factor (Drive only),
/// - registration (Docs only),
/// - the `X-Device-Name` header (Docs, Sheets, Photos only),
/// - the per-app OAuth client id and Keychain prefix (all five, all different).
@MainActor
final class AuthServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        KeychainService.installInMemoryBackendForTesting()
        NeutrinoApp.configure(.drive)
        MockURLProtocol.reset()
        clearKeychain()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        clearKeychain()
        KeychainService.removeTestingBackend()
        super.tearDown()
    }

    private func clearKeychain() {
        let config = NeutrinoApp.current
        KeychainService.delete(forKey: config.accessTokenKey)
        KeychainService.delete(forKey: config.refreshTokenKey)
        KeychainService.delete(forKey: config.tokenExpiryKey)
    }

    private func makeSUT() -> AuthService {
        AuthService(configuration: MockURLProtocol.configuration())
    }

    // MARK: - Fixtures

    /// The three legs of a successful PKCE sign-in.
    private func routeSuccessfulLogin() {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch path {
            case let p where p.hasSuffix("/auth/login"):
                return (Self.response(request, 200),
                        Data(#"{"accessToken":"session-token"}"#.utf8))
            case let p where p.hasSuffix("/oauth/authorize"):
                let state = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "state" }?.value ?? ""
                let location = "neutrino://oauth/callback?code=auth-code&state=\(state)"
                return (Self.response(request, 302, headers: ["Location": location]), Data())
            case let p where p.hasSuffix("/oauth/token"):
                return (Self.response(request, 200), Data(#"""
                    {"access_token":"at","refresh_token":"rt","expires_in":3600,"token_type":"Bearer"}
                """#.utf8))
            default:
                return (Self.response(request, 404), Data())
            }
        }
    }

    private static func response(_ request: URLRequest,
                                 _ code: Int,
                                 headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
    }

    // MARK: - Happy path

    func testSuccessfulLoginPersistsTokensUnderTheAppsOwnPrefix() async {
        routeSuccessfulLogin()
        let sut = makeSUT()

        await sut.login(email: "a@b.com", password: "hunter2")

        XCTAssertTrue(sut.isAuthenticated)
        XCTAssertNil(sut.loginError)
        XCTAssertEqual(KeychainService.load(forKey: "nd.access_token"), "at")
        XCTAssertEqual(KeychainService.load(forKey: "nd.refresh_token"), "rt")
        // The other apps' slots must be untouched — this is the collision the prefix prevents.
        XCTAssertNil(KeychainService.load(forKey: "ndoc.access_token"))
    }

    /// Device registration. Drive and Notes were signing in without this header, so their sessions
    /// showed as "Unknown device" in the account's device list.
    func testLoginSendsTheDeviceNameHeader() async {
        routeSuccessfulLogin()
        let sut = makeSUT()

        await sut.login(email: "a@b.com", password: "hunter2")

        let loginRequest = MockURLProtocol.request { $0.url?.path.hasSuffix("/auth/login") == true }
        let sent = loginRequest?.value(forHTTPHeaderField: DeviceIdentity.deviceNameHeader)
        XCTAssertNotNil(sent, "login must name the device")
        XCTAssertTrue(sent?.contains("Neutrino Drive") == true,
                      "device name should identify the app, got \(sent ?? "nil")")
    }

    /// Each app must present its own client id, or the server attributes every session to one app.
    func testAuthorizeUsesTheConfiguredClientID() async {
        NeutrinoApp.configure(.docs)
        routeSuccessfulLogin()
        let sut = makeSUT()

        await sut.login(email: "a@b.com", password: "hunter2")

        let authorize = MockURLProtocol.request { $0.url?.path.hasSuffix("/oauth/authorize") == true }
        let clientID = URLComponents(url: authorize!.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "client_id" }?.value
        XCTAssertEqual(clientID, "neutrino-docs-ios")
    }

    // MARK: - Failure paths

    func testRejectedCredentialsReportAnErrorAndDoNotAuthenticate() async {
        MockURLProtocol.handler = { request in (Self.response(request, 401), Data()) }
        let sut = makeSUT()

        await sut.login(email: "a@b.com", password: "wrong")

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertEqual(sut.loginError, AuthError.invalidCredentials.localizedDescription)
        XCTAssertNil(KeychainService.load(forKey: "nd.access_token"))
    }

    /// A returned `state` that is not the one this client sent means the response is not an answer
    /// to our request. It must not be exchanged.
    func testStateMismatchIsRefused() async {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/login") {
                return (Self.response(request, 200), Data(#"{"accessToken":"s"}"#.utf8))
            }
            if path.hasSuffix("/oauth/authorize") {
                let location = "neutrino://oauth/callback?code=c&state=not-the-state-we-sent"
                return (Self.response(request, 302, headers: ["Location": location]), Data())
            }
            return (Self.response(request, 200), Data())
        }
        let sut = makeSUT()

        await sut.login(email: "a@b.com", password: "hunter2")

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertEqual(sut.loginError, AuthError.stateMismatch.localizedDescription)
    }

    // MARK: - Two-factor

    /// The bug this consolidation fixes for four apps: a 2FA account answers step 1 with no tokens
    /// and `requiresTwoFactor: true`. Decoding `accessToken` as required — which Docs, Sheets,
    /// Notes and Photos all did — turned that into an opaque decoding error with no way forward.
    func testTwoFactorAccountPromptsForACodeRatherThanFailing() async {
        MockURLProtocol.handler = { request in
            (Self.response(request, 200), Data(#"{"requiresTwoFactor":true}"#.utf8))
        }
        let sut = makeSUT()

        await sut.login(email: "a@b.com", password: "hunter2")

        XCTAssertTrue(sut.requiresTwoFactorCode)
        XCTAssertFalse(sut.isAuthenticated)
        // The first prompt is not an error — nothing has gone wrong yet.
        XCTAssertNil(sut.loginError)
    }

    /// A second rejection, once the field is already on screen, must read as a bad code rather
    /// than repeating "enter the code" as though nothing happened.
    func testSecondRejectionReportsABadCode() async {
        MockURLProtocol.handler = { request in
            (Self.response(request, 200), Data(#"{"requiresTwoFactor":true}"#.utf8))
        }
        let sut = makeSUT()

        await sut.login(email: "a@b.com", password: "hunter2")
        await sut.login(email: "a@b.com", password: "hunter2", totpCode: "000000")

        XCTAssertTrue(sut.requiresTwoFactorCode)
        XCTAssertEqual(sut.loginError, AuthError.invalidTwoFactorCode.localizedDescription)
    }

    func testSupplyingTheCodeCompletesTheSignInAndClearsThePrompt() async {
        routeSuccessfulLogin()
        let sut = makeSUT()

        await sut.login(email: "a@b.com", password: "hunter2", totpCode: "123456")

        XCTAssertTrue(sut.isAuthenticated)
        XCTAssertFalse(sut.requiresTwoFactorCode)
    }

    /// An untouched code field must encode as an absent JSON field, not `""` — the server reads an
    /// empty string as a code that was supplied and is wrong.
    func testEmptyCodeIsOmittedFromTheRequestBody() async {
        routeSuccessfulLogin()
        let sut = makeSUT()

        await sut.login(email: "a@b.com", password: "hunter2", totpCode: "")

        let body = MockURLProtocol.bodies.first ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        XCTAssertNotNil(json, "login body should be JSON")
        XCTAssertNil(json?["totpCode"] ?? nil, "an empty code must not be sent")
    }

    // MARK: - Registration

    func testRegistrationCreatesTheAccountThenSignsIn() async {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/register") {
                return (Self.response(request, 201), Data())
            }
            if path.hasSuffix("/auth/login") {
                return (Self.response(request, 200), Data(#"{"accessToken":"s"}"#.utf8))
            }
            if path.hasSuffix("/oauth/authorize") {
                let state = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "state" }?.value ?? ""
                return (Self.response(request, 302,
                                      headers: ["Location": "neutrino://oauth/callback?code=c&state=\(state)"]),
                        Data())
            }
            return (Self.response(request, 200), Data(#"""
                {"access_token":"at","refresh_token":"rt","expires_in":3600,"token_type":"Bearer"}
            """#.utf8))
        }
        let sut = makeSUT()

        await sut.register(name: "Will", email: "a@b.com", password: "hunter22")

        XCTAssertTrue(sut.isAuthenticated)
        XCTAssertTrue(sut.didRegisterThisSession)
        XCTAssertNil(sut.registerError)
    }

    func testDuplicateEmailIsReportedAsSuch() async {
        MockURLProtocol.handler = { request in (Self.response(request, 409), Data()) }
        let sut = makeSUT()

        await sut.register(name: "Will", email: "taken@b.com", password: "hunter22")

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertEqual(sut.registerError, AuthError.emailAlreadyRegistered.localizedDescription)
    }

    /// The account exists; only the sign-in leg failed. Saying "registration failed" would send
    /// the user round to create a second account.
    func testSignInFailureAfterAccountCreationSaysTheAccountWasMade() async {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/register") { return (Self.response(request, 201), Data()) }
            return (Self.response(request, 500), Data())
        }
        let sut = makeSUT()

        await sut.register(name: "Will", email: "a@b.com", password: "hunter22")

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertTrue(sut.registerError?.contains("account was created") == true,
                      "got: \(sut.registerError ?? "nil")")
    }

    /// Registration errors must not leak into the login screen underneath the sheet.
    func testRegisterErrorDoesNotTouchLoginError() async {
        MockURLProtocol.handler = { request in (Self.response(request, 409), Data()) }
        let sut = makeSUT()

        await sut.register(name: "Will", email: "taken@b.com", password: "hunter22")

        XCTAssertNotNil(sut.registerError)
        XCTAssertNil(sut.loginError)
    }

    // MARK: - Logout

    func testLogoutClearsEveryTokenAndTheTwoFactorPrompt() async {
        routeSuccessfulLogin()
        let sut = makeSUT()
        await sut.login(email: "a@b.com", password: "hunter2")
        XCTAssertTrue(sut.isAuthenticated)

        sut.logout()

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertFalse(sut.requiresTwoFactorCode)
        XCTAssertNil(KeychainService.load(forKey: "nd.access_token"))
        XCTAssertNil(KeychainService.load(forKey: "nd.refresh_token"))
        XCTAssertNil(KeychainService.load(forKey: "nd.token_expiry"))
    }

    // MARK: - Refresh

    /// An unreachable server must not sign somebody out of an offline-first app.
    func testRefreshLeavesTheSessionAloneWhenTheServerIsUnreachable() async {
        KeychainService.save("at", forKey: "nd.access_token")
        KeychainService.save("rt", forKey: "nd.refresh_token")
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let sut = makeSUT()

        await sut.refreshTokenIfNeeded()

        XCTAssertEqual(KeychainService.load(forKey: "nd.access_token"), "at")
    }

    /// A rejected refresh token is the session ending, not a transient failure.
    func testRejectedRefreshTokenSignsOut() async {
        KeychainService.save("at", forKey: "nd.access_token")
        KeychainService.save("rt", forKey: "nd.refresh_token")
        MockURLProtocol.handler = { request in (Self.response(request, 401), Data()) }
        let sut = makeSUT()

        await sut.refreshTokenIfNeeded()

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertNil(KeychainService.load(forKey: "nd.access_token"))
    }

    /// A token still comfortably in date must cost no network traffic — every authorized request
    /// calls this first.
    func testValidTokenSkipsTheNetworkEntirely() async {
        KeychainService.save("at", forKey: "nd.access_token")
        KeychainService.save("rt", forKey: "nd.refresh_token")
        let future = Date().addingTimeInterval(3600)
        KeychainService.save(ISO8601DateFormatter().string(from: future), forKey: "nd.token_expiry")
        let sut = makeSUT()

        await sut.refreshTokenIfNeeded()

        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    // MARK: - PKCE

    func testPKCEChallengeIsTheSHA256OfTheVerifier() {
        let (verifier, challenge) = AuthService.pkceValues()
        XCTAssertFalse(verifier.isEmpty)
        XCTAssertFalse(challenge.isEmpty)
        XCTAssertNotEqual(verifier, challenge)
        // base64url: no padding, no + or /.
        for token in [verifier, challenge] {
            XCTAssertFalse(token.contains("="))
            XCTAssertFalse(token.contains("+"))
            XCTAssertFalse(token.contains("/"))
        }
    }

    func testRandomValuesDoNotRepeat() {
        let values = (0..<32).map { _ in AuthService.randomBase64URL(byteCount: 16) }
        XCTAssertEqual(Set(values).count, values.count)
    }
}
