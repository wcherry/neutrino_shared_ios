import XCTest
@testable import NeutrinoCore

final class RetryPolicyTests: XCTestCase {

    override func tearDown() {
        ScriptedURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Delay

    func test_delay_doublesFromTheBaseAndCaps() {
        let policy = RetryPolicy(maxAttempts: 6, baseDelay: 0.5, maxDelay: 3, jitter: 0)
        XCTAssertEqual(policy.delay(beforeRetry: 1), 0.5)
        XCTAssertEqual(policy.delay(beforeRetry: 2), 1)
        XCTAssertEqual(policy.delay(beforeRetry: 3), 2)
        XCTAssertEqual(policy.delay(beforeRetry: 4), 3)
    }

    func test_delay_jitterStaysWithinItsFraction() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 10, jitter: 0.2)
        XCTAssertEqual(policy.delay(beforeRetry: 1, random: 0), 0.8, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(beforeRetry: 1, random: 1), 1.2, accuracy: 1e-9)
    }

    func test_delay_retryAfterWinsButIsCapped() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, maxDelay: 8, jitter: 0)
        XCTAssertEqual(policy.delay(beforeRetry: 1, retryAfter: 4), 4)
        XCTAssertEqual(policy.delay(beforeRetry: 1, retryAfter: 600), 8)
    }

    // MARK: - Classification

    func test_onlyReadsAreIdempotent() {
        XCTAssertTrue(RetryPolicy.isIdempotent(method: nil))
        XCTAssertTrue(RetryPolicy.isIdempotent(method: "get"))
        XCTAssertTrue(RetryPolicy.isIdempotent(method: "HEAD"))
        // A save's expectedContentVersion makes a repeated PUT look like somebody else's edit.
        XCTAssertFalse(RetryPolicy.isIdempotent(method: "PUT"))
        XCTAssertFalse(RetryPolicy.isIdempotent(method: "POST"))
        XCTAssertFalse(RetryPolicy.isIdempotent(method: "DELETE"))
    }

    func test_offlineIsNeverTransient() {
        XCTAssertFalse(RetryPolicy.isTransient(URLError(.notConnectedToInternet), idempotent: true))
    }

    func test_lostConnectionIsTransientOnlyForReads() {
        XCTAssertTrue(RetryPolicy.isTransient(URLError(.networkConnectionLost), idempotent: true))
        XCTAssertTrue(RetryPolicy.isTransient(URLError(.timedOut), idempotent: true))
        XCTAssertFalse(RetryPolicy.isTransient(URLError(.networkConnectionLost), idempotent: false))
        XCTAssertFalse(RetryPolicy.isTransient(URLError(.timedOut), idempotent: false))
    }

    func test_neverConnectingIsTransientForAnyMethod() {
        XCTAssertTrue(RetryPolicy.isTransient(URLError(.cannotConnectToHost), idempotent: false))
        XCTAssertTrue(RetryPolicy.isTransient(URLError(.dnsLookupFailed), idempotent: false))
    }

    func test_otherErrorsAreNotTransient() {
        XCTAssertFalse(RetryPolicy.isTransient(URLError(.cancelled), idempotent: true))
        XCTAssertFalse(RetryPolicy.isTransient(URLError(.badURL), idempotent: true))
        XCTAssertFalse(RetryPolicy.isTransient(CocoaError(.fileNoSuchFile), idempotent: true))
    }

    func test_retryableStatuses() {
        for status in [429, 503] {
            XCTAssertTrue(RetryPolicy.isRetryable(statusCode: status, idempotent: false), "\(status)")
        }
        for status in [408, 502, 504] {
            XCTAssertTrue(RetryPolicy.isRetryable(statusCode: status, idempotent: true), "\(status)")
            XCTAssertFalse(RetryPolicy.isRetryable(statusCode: status, idempotent: false), "\(status)")
        }
        for status in [200, 400, 401, 404, 409, 500] {
            XCTAssertFalse(RetryPolicy.isRetryable(statusCode: status, idempotent: true), "\(status)")
        }
    }

    func test_retryAfter_readsSecondsAndHTTPDates() {
        let url = URL(string: "https://example.com")!
        let seconds = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil,
                                      headerFields: ["Retry-After": "7"])!
        XCTAssertEqual(RetryPolicy.retryAfter(seconds), 7)

        let now = Date(timeIntervalSince1970: 1_000_000_000)   // Sun, 09 Sep 2001 01:46:40 GMT
        let dated = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil,
                                    headerFields: ["Retry-After": "Sun, 09 Sep 2001 01:46:50 GMT"])!
        XCTAssertEqual(RetryPolicy.retryAfter(dated, now: now), 10)

        let none = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!
        XCTAssertNil(RetryPolicy.retryAfter(none))
    }

    // MARK: - URLSession

    private let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, maxDelay: 8, jitter: 0)

    func test_session_retriesAGetThroughABlipAndReturnsTheSuccess() async throws {
        ScriptedURLProtocol.script = [.fail(URLError(.networkConnectionLost)), .status(502), .status(200)]
        var waits: [TimeInterval] = []

        let (_, response) = try await ScriptedURLProtocol.session.data(
            for: URLRequest(url: URL(string: "https://example.com/a")!), retry: policy) { waits.append($0) }

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 3)
        XCTAssertEqual(waits, [0.5, 1])
    }

    func test_session_returnsTheLastResponseWhenRetriesRunOut() async throws {
        ScriptedURLProtocol.script = [.status(503), .status(503), .status(503), .status(200)]

        let (_, response) = try await ScriptedURLProtocol.session.data(
            for: URLRequest(url: URL(string: "https://example.com/a")!), retry: policy) { _ in }

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 3)
    }

    func test_session_doesNotRepeatASaveWhoseConnectionDropped() async {
        ScriptedURLProtocol.script = [.fail(URLError(.networkConnectionLost)), .status(200)]
        var request = URLRequest(url: URL(string: "https://example.com/content")!)
        request.httpMethod = "PUT"

        do {
            _ = try await ScriptedURLProtocol.session.data(for: request, retry: policy) { _ in }
            XCTFail("expected the error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 1)
    }

    func test_session_honoursRetryAfter() async throws {
        ScriptedURLProtocol.script = [.status(429, headers: ["Retry-After": "2"]), .status(201)]
        var request = URLRequest(url: URL(string: "https://example.com/files")!)
        request.httpMethod = "POST"
        var waits: [TimeInterval] = []

        let (_, response) = try await ScriptedURLProtocol.session.data(for: request, retry: policy) { waits.append($0) }

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        XCTAssertEqual(waits, [2])
    }

    func test_session_failsAtOnceWhenOffline() async {
        ScriptedURLProtocol.script = [.fail(URLError(.notConnectedToInternet)), .status(200)]
        do {
            _ = try await ScriptedURLProtocol.session.data(
                for: URLRequest(url: URL(string: "https://example.com/a")!), retry: policy) { _ in }
            XCTFail("expected the error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 1)
    }
}

// MARK: - ScriptedURLProtocol

/// Answers each request with the next step of a script, so a test can lay out a run of failures.
final class ScriptedURLProtocol: URLProtocol {

    enum Step {
        case status(Int, headers: [String: String] = [:])
        case fail(URLError)
    }

    private static let lock = NSLock()
    private static var _script: [Step] = []
    private static var _requestCount = 0

    static var script: [Step] {
        get { lock.withLock { _script } }
        set { lock.withLock { _script = newValue } }
    }

    static var requestCount: Int { lock.withLock { _requestCount } }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        return URLSession(configuration: config)
    }()

    static func reset() {
        lock.withLock {
            _script = []
            _requestCount = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let step: Step? = Self.lock.withLock {
            Self._requestCount += 1
            return Self._script.isEmpty ? nil : Self._script.removeFirst()
        }
        switch step {
        case .status(let code, let headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        }
    }

    override func stopLoading() {}
}
