import Foundation

// MARK: - RetryPolicy

/// When, and how often, a request that failed for a reason unrelated to the request itself is sent
/// again.
///
/// A dropped connection, a DNS blip, a proxy answering 502 while the server restarts — each is
/// gone a second later, and showing it to the user as "Sync failed" makes a brief hiccup look like
/// an outage. These failures are retried here, a few times with growing delays, before the caller
/// ever sees them.
///
/// Two rules keep the retry from making things worse:
///
/// - **Offline is not transient.** `notConnectedToInternet` fails at once, so the app's offline
///   path (the cached copy, the queued edit) takes over immediately rather than after the last
///   backoff.
/// - **Only idempotent requests are retried on an ambiguous failure.** A timeout or a lost
///   connection does not say whether the server acted. Repeating a GET is harmless; repeating a
///   save is not — the first one may have landed, and the repeat would come back as a
///   content-version conflict for the user's own edit. A non-idempotent request is retried only
///   when the server cannot have seen it (the connection was never made) or said outright that it
///   did not act (429, 503).
public struct RetryPolicy: Sendable, Equatable {

    /// Total attempts, the first one included. 1 means "never retry".
    public var maxAttempts: Int

    /// The delay before the first retry; each later retry doubles it.
    public var baseDelay: TimeInterval

    /// No delay — computed or asked for with `Retry-After` — is longer than this.
    public var maxDelay: TimeInterval

    /// How far each delay is spread, as a fraction of itself, so a fleet of clients knocked off by
    /// the same blip does not reconnect in lockstep.
    public var jitter: Double

    public init(maxAttempts: Int, baseDelay: TimeInterval, maxDelay: TimeInterval, jitter: Double = 0.2) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
        self.jitter = min(max(0, jitter), 1)
    }

    /// Three attempts over about a second and a half: long enough to ride out a blip, short enough
    /// that a user waiting on a spinner is not left there.
    public static let `default` = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, maxDelay: 8)

    /// Send once.
    public static let none = RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0, jitter: 0)

    // MARK: - Delay

    /// The wait before retry number `retry` (1 for the first retry).
    ///
    /// - Parameters:
    ///   - retryAfter: the server's `Retry-After`, which wins over the computed backoff but is
    ///     still capped at `maxDelay` — a server asking for ten minutes is asking for a different
    ///     kind of retry than this one.
    ///   - random: a value in `0...1`; injected so the curve is testable.
    public func delay(beforeRetry retry: Int, retryAfter: TimeInterval? = nil,
                      random: Double = Double.random(in: 0...1)) -> TimeInterval {
        if let retryAfter { return min(max(0, retryAfter), maxDelay) }
        let exponent = Double(max(0, retry - 1))
        let backoff = min(baseDelay * pow(2, exponent), maxDelay)
        let spread = backoff * jitter * (random * 2 - 1)
        return min(max(0, backoff + spread), maxDelay)
    }

    // MARK: - Classification

    /// Methods whose repeat cannot change the outcome. A nil method is URLRequest's default, GET.
    ///
    /// PUT and DELETE are idempotent by the letter of HTTP, but not here: a save carries an
    /// `expectedContentVersion` that its own first attempt bumps, so a repeat of a save that landed
    /// reads as somebody else's edit.
    public static func isIdempotent(method: String?) -> Bool {
        switch (method ?? "GET").uppercased() {
        case "GET", "HEAD", "OPTIONS": return true
        default:                       return false
        }
    }

    /// Whether a failure to get any response at all is worth another attempt.
    public static func isTransient(_ error: Error, idempotent: Bool) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        // Never connected: the server cannot have acted, whatever the method.
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        // Connected, then lost: the server may have acted.
        case .timedOut, .networkConnectionLost:
            return idempotent
        default:
            return false
        }
    }

    /// Whether a response's status says "try again shortly" rather than "this request is wrong".
    public static func isRetryable(statusCode: Int, idempotent: Bool) -> Bool {
        switch statusCode {
        case 429, 503:           return true          // the server declined to act
        case 408, 502, 504:      return idempotent    // a gateway may have passed it on
        default:                 return false
        }
    }

    /// `Retry-After` in seconds. The HTTP-date form is accepted too, though the server sends seconds.
    public static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

// MARK: - URLSession

extension URLSession {

    /// `data(for:)`, with transient failures retried under `policy`.
    ///
    /// A response is returned as soon as one arrives that is not retryable, or on the last attempt
    /// whatever its status — the caller's status handling is unchanged. An error is thrown only
    /// once retries are exhausted or the error is not transient. Cancelling the task stops the
    /// retries.
    public func data(for request: URLRequest, retry policy: RetryPolicy) async throws -> (Data, URLResponse) {
        try await data(for: request, retry: policy) { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    /// The same, with the wait injected so a test does not sleep.
    func data(for request: URLRequest, retry policy: RetryPolicy,
              sleep: (TimeInterval) async throws -> Void) async throws -> (Data, URLResponse) {
        let idempotent = RetryPolicy.isIdempotent(method: request.httpMethod)
        var attempt = 1
        while true {
            try Task.checkCancellation()
            let isLast = attempt >= policy.maxAttempts
            do {
                let (data, response) = try await self.data(for: request)
                guard !isLast,
                      let http = response as? HTTPURLResponse,
                      RetryPolicy.isRetryable(statusCode: http.statusCode, idempotent: idempotent) else {
                    return (data, response)
                }
                try await sleep(policy.delay(beforeRetry: attempt, retryAfter: RetryPolicy.retryAfter(http)))
            } catch {
                guard !isLast, !(error is CancellationError),
                      RetryPolicy.isTransient(error, idempotent: idempotent) else { throw error }
                try await sleep(policy.delay(beforeRetry: attempt))
            }
            attempt += 1
        }
    }
}
