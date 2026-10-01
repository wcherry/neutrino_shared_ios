import Foundation
import Combine
import os.log
import Sodium
import NeutrinoCore

// MARK: - Why this file exists
//
// Every app that uploads sealed each new file's DEK to whatever public key was in its Keychain, and
// asked nobody whether that was still the account's key. When an account's key is replaced from
// another device, a device that kept its old key goes on sealing to it: every file it uploads opens
// on that device and nowhere else, and the web reports "This file's key does not open with any
// encryption key this device holds". Neutrino Drive did this to 374 photos over two weeks.
//
// Two things follow, and both are here so the apps cannot disagree about them:
//
//   * before sealing, the stored key is compared with the account's active published key, and an
//     upload is refused when they differ (`DeviceKeyCheck`);
//   * a device found holding a stale key re-seals what it sealed to that key onto the published
//     one (`DeviceKeyRepairService`) — the only place that can, since its Keychain holds the only
//     secret that opens those files, and only until that key is replaced.

// MARK: - PublishedKey

/// The account's **active** identity key, as the key directory publishes it
/// (`GET /api/v1/auth/users/{id}/public-key`).
///
/// The key every other client seals to and opens with. The web keeps nothing else: its keyring is
/// exactly the directory's versions, so a DEK sealed to any other key is a file the web can never
/// open.
public struct PublishedKey: Equatable, Sendable, Decodable {
    public let publicKey: String
    public let version: Int

    public init(publicKey: String, version: Int) {
        self.publicKey = publicKey
        self.version = version
    }
}

// MARK: - DeviceKeyStatus

/// Whether the key in this device's Keychain is the one the account publishes.
public enum DeviceKeyStatus: Equatable, Sendable {
    /// It is. New work may be sealed to it, filed under `version`.
    case current(version: Int)
    /// It is not. Anything sealed to it opens on this device and nowhere else.
    case stale(published: PublishedKey)
    /// The account publishes no key at all, so there is nothing to check the device's against.
    case unpublished

    /// Compares the stored public key with the published one, as bytes — a key file may carry
    /// padding or the standard alphabet where the directory does not, and the same key must not
    /// read as two.
    public static func of(storedPublicKey: String, published: PublishedKey?) -> DeviceKeyStatus {
        guard let published else { return .unpublished }
        guard let stored = Data(base64URLEncoded: storedPublicKey),
              let current = Data(base64URLEncoded: published.publicKey),
              stored == current else {
            return .stale(published: published)
        }
        return .current(version: published.version)
    }
}

// MARK: - DeviceKeyCheckError

public enum DeviceKeyCheckError: Error, Equatable {
    /// This device holds no identity key at all.
    case noKey
    /// This device's key is not the account's, or the account publishes none. Sealing to it would
    /// make a file that opens here and on no other device.
    case stale
}

// MARK: - DeviceKeyCheck

/// Answers "may a new file be sealed to this device's key, and under which version?"
///
/// One small GET, cached for ``cacheLifetime`` against the exact public key it checked, so a backup
/// of a thousand photos costs one request rather than a thousand — and a key imported mid-run is
/// checked afresh rather than riding on the old key's answer.
///
/// Static, and safe from any isolation, because the callers are: a `@MainActor` service in one app,
/// a plain struct the share extension constructs per upload in another. The cache is process-wide,
/// which is what lets the extension's uploads and the app's share one answer within a process.
public enum DeviceKeyCheck {

    /// How long a `.current` answer is trusted. Short: a key replaced on another device should stop
    /// this one sealing within minutes, not at the next launch.
    public static let cacheLifetime: TimeInterval = 10 * 60

    private static let lock = NSLock()
    private static var cached: (publicKey: String, version: Int, at: Date)?
    private static var logger: Logger { Logger(subsystem: NeutrinoApp.current.logSubsystem, category: "DeviceKeyCheck") }

    /// The version to file a new file's key under — the account's number for the key this device
    /// holds — or a throw when this device's key is not the account's.
    ///
    /// - Parameter fetchPublished: the account's active key, or nil when it publishes none (404).
    ///   Supplied by the app, through whatever authorized transport it has.
    /// - Throws: ``DeviceKeyCheckError`` for a missing or stale key; whatever `fetchPublished`
    ///   throws when the directory cannot be asked, which a caller should treat as retryable.
    public static func sealingVersion(
        fetchPublished: () async throws -> PublishedKey?
    ) async throws -> Int {
        guard let stored = KeyImportService.storedKeys() else { throw DeviceKeyCheckError.noKey }
        if let version = cachedVersion(for: stored.publicKey) { return version }

        let status = DeviceKeyStatus.of(storedPublicKey: stored.publicKey,
                                        published: try await fetchPublished())
        record(status, for: stored.publicKey)
        guard case .current(let version) = status else {
            logger.error("refusing to seal: this device's key is not the account's")
            throw DeviceKeyCheckError.stale
        }
        return version
    }

    /// Records an answer obtained elsewhere — the repair service asks the same question at launch.
    public static func record(_ status: DeviceKeyStatus, for storedPublicKey: String) {
        lock.lock(); defer { lock.unlock() }
        if case .current(let version) = status {
            cached = (storedPublicKey, version, Date())
        } else {
            cached = nil
        }
    }

    /// Drops any cached answer. For tests, and for a caller that has just replaced the key.
    public static func forget() {
        lock.lock(); defer { lock.unlock() }
        cached = nil
    }

    private static func cachedVersion(for storedPublicKey: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let cached, cached.publicKey == storedPublicKey,
              Date().timeIntervalSince(cached.at) < cacheLifetime else { return nil }
        return cached.version
    }
}

// MARK: - DeviceKeyRewrap

/// Moves one file's DEK from this device's stale key onto the account's published key.
///
/// Pure and static so the one step that can make a file unreadable — what gets sealed to whom — is
/// testable without a network or a Keychain.
public enum DeviceKeyRewrap {

    /// The DEK in `sealed`, re-sealed to `published`, or nil when this device's key does not open
    /// it. File the result under `published.version`.
    ///
    /// Nil is the common answer and not a failure: anything uploaded from the web or a healthy
    /// device was sealed to the published key, which this device (holding a different one) cannot
    /// open. Those refs are already right and are left alone.
    ///
    /// Sealing needs only the published *public* key, which is why a device that does not hold the
    /// account's current secret can still repair the files only it can open.
    public static func rewrap(_ sealed: String, deviceKey: KeyBundle, to published: PublishedKey) -> String? {
        guard let publicKey = Data(base64URLEncoded: deviceKey.publicKey),
              let secretKey = Data(base64URLEncoded: deviceKey.privateKey),
              let recipient = Data(base64URLEncoded: published.publicKey),
              let dek = try? DriveFileCrypto.openDEK(sealed, publicKey: Bytes(publicKey), secretKey: Bytes(secretKey)) else {
            return nil
        }
        return try? DriveFileCrypto.seal(dek: dek, toPublicKey: Bytes(recipient))
    }
}

// MARK: - DeviceKeyTransport

/// The four requests the repair needs, made through the app's own authorized client.
///
/// A protocol because each app has its own: token refresh, error types and session configuration
/// differ, and this package should not grow a fifth HTTP client to paper over that.
public protocol DeviceKeyTransport: AnyObject {
    /// The account's active key, or nil when it publishes none (404).
    func publishedKey() async throws -> PublishedKey?
    /// One page of the ids of every file the caller owns, whatever folder it is in, **oldest first**
    /// — so files uploaded while the pass runs land after the cursor rather than shifting the pages
    /// under it. (`GET /api/v1/drive/files?limit&offset&orderBy=createdAt&direction=asc`.)
    func fileIDsPage(limit: Int, offset: Int) async throws -> [String]
    /// The caller's sealed DEK for `fileID` and the version it is filed under, or nil when the file
    /// has no key ref (404).
    func fileKey(fileID: String) async throws -> (sealed: String, keyVersion: Int)?
    /// Replaces the caller's own key ref (`PUT /api/v1/drive/files/{id}/key`).
    func setFileKey(fileID: String, sealed: String, keyVersion: Int) async throws
    /// Whether a failed request describes a moment — a transport error, 408, 429, 5xx — and is worth
    /// sending again.
    func isRetryable(_ error: Error) -> Bool
}

// MARK: - DeviceKeyRepairReport

public struct DeviceKeyRepairReport: Equatable, Sendable {
    /// Files whose key was moved onto the account's key. These now open everywhere.
    public var rewrapped = 0
    /// Files this device's key does not open — sealed to the account's key already.
    public var alreadyCorrect = 0
    /// Files with no key ref (not encrypted).
    public var unencrypted = 0
    /// A read or write that failed after retries. Running the pass again picks these up.
    public var failed = 0

    public init() {}

    public var examined: Int { rewrapped + alreadyCorrect + unencrypted + failed }

    public var summary: String {
        var parts = ["\(rewrapped) repaired"]
        if failed > 0 { parts.append("\(failed) failed — run again to retry") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - DeviceKeyRepairState

public enum DeviceKeyRepairState: Equatable, Sendable {
    case unknown
    /// This device's key is the account's key. Nothing to do.
    case current
    /// It is not, and the repair pass has not run (or is about to).
    case stale
    case running(examined: Int, rewrapped: Int)
    /// The pass finished. The device is still stale — it needs the account's current key — but
    /// nothing it uploaded is unreadable elsewhere any more.
    case repaired(DeviceKeyRepairReport)
    case failed(String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// True while files exist that only this device's key opens. Removing the key then destroys
    /// them, so the UI holds the "remove key" action back.
    public var keyMustBeKept: Bool {
        switch self {
        case .stale, .running, .failed: return true
        case .repaired(let report):     return report.failed > 0
        case .unknown, .current:        return false
        }
    }
}

// MARK: - DeviceKeyRepairService

/// Finds the files this device sealed to a key the account no longer publishes, and re-seals each
/// one to the key it does.
///
/// ## Why it has to run on the device
///
/// A file sealed to this device's old key can be opened by exactly one secret in the world: the one
/// in this device's Keychain. The server never sees a DEK, and no other client holds the old key. So
/// the repair can only happen here, and only *before* that key is replaced — importing the account's
/// current key overwrites it. That is why an app should run ``checkAndRepair()`` at launch and on
/// foreground, rather than wait for someone to find a button.
///
/// ## Why it is safe
///
/// It only rewrites a ref that this device's key opens, and only the caller's own ref. The DEK and
/// the ciphertext are untouched — the same key, sealed to a different recipient — so an interrupted
/// or repeated pass leaves every file readable by at least the key it was readable by before. A
/// second run finds nothing left to do.
@MainActor
public final class DeviceKeyRepairService: ObservableObject {

    @Published public private(set) var state: DeviceKeyRepairState = .unknown

    public static let pageSize = 200
    /// Key reads in flight at once. One ref per file in the drive is the better part of an hour in
    /// series on a large library.
    public static let concurrency = 6
    public static let backoff: [TimeInterval] = [1, 4, 16]

    /// Held strongly: an app often hands in a small adapter over its API client that nothing else
    /// retains.
    public var transport: DeviceKeyTransport?
    private let sleep: (TimeInterval) async -> Void
    private var inFlight = false
    private var logger: Logger { Logger(subsystem: NeutrinoApp.current.logSubsystem, category: "DeviceKeyRepair") }

    /// - Parameter sleep: the backoff delay; injected so tests do not wait.
    public init(transport: DeviceKeyTransport? = nil,
                sleep: @escaping (TimeInterval) async -> Void = { seconds in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }) {
        self.transport = transport
        self.sleep = sleep
    }

    /// Checks this device's key against the account's, and repairs straight away if it is stale.
    public func checkAndRepair() async {
        // Launch and the first foreground both ask; the flag is set before the first await so the
        // second caller cannot start a second pass while the first is still reading the key.
        guard !inFlight, let transport, let stored = KeyImportService.storedKeys() else { return }
        inFlight = true
        defer { inFlight = false }

        let published: PublishedKey?
        do {
            published = try await transport.publishedKey()
        } catch {
            // Offline, most likely. Uploads check for themselves; the next foreground asks again.
            logger.error("checkAndRepair: could not read the account's key: \(error.localizedDescription, privacy: .public)")
            return
        }

        let status = DeviceKeyStatus.of(storedPublicKey: stored.publicKey, published: published)
        DeviceKeyCheck.record(status, for: stored.publicKey)
        switch status {
        case .current:
            state = .current
        case .unpublished:
            // Nothing to seal to. Uploads refuse on their own; the provisioning flow publishes.
            state = .stale
        case .stale(let published):
            state = .stale
            await repair(to: published, deviceKey: stored, using: transport)
        }
    }

    private func repair(to published: PublishedKey, deviceKey: KeyBundle,
                        using transport: DeviceKeyTransport) async {
        logger.info("repair: device key is stale; re-sealing its files to account key v\(published.version, privacy: .public)")
        var report = DeviceKeyRepairReport()
        state = .running(examined: 0, rewrapped: 0)
        var offset = 0

        while true {
            let ids: [String]
            do {
                ids = try await withBackoff(transport) {
                    try await transport.fileIDsPage(limit: Self.pageSize, offset: offset)
                }
            } catch {
                logger.error("repair: listing failed at offset \(offset): \(error.localizedDescription, privacy: .public)")
                state = .failed("Could not list your files: \(error.localizedDescription)")
                return
            }
            if ids.isEmpty { break }

            for chunk in stride(from: 0, to: ids.count, by: Self.concurrency) {
                let slice = ids[chunk..<min(chunk + Self.concurrency, ids.count)]
                let outcomes = await withTaskGroup(of: Outcome.self) { group in
                    for id in slice {
                        group.addTask {
                            await self.repairOne(fileID: id, published: published,
                                                 deviceKey: deviceKey, using: transport)
                        }
                    }
                    var all: [Outcome] = []
                    for await outcome in group { all.append(outcome) }
                    return all
                }
                for outcome in outcomes {
                    switch outcome {
                    case .rewrapped:      report.rewrapped += 1
                    case .alreadyCorrect: report.alreadyCorrect += 1
                    case .unencrypted:    report.unencrypted += 1
                    case .failed:         report.failed += 1
                    }
                }
                state = .running(examined: report.examined, rewrapped: report.rewrapped)
            }

            if ids.count < Self.pageSize { break }
            offset += Self.pageSize
        }

        logger.info("repair: finished — \(report.rewrapped) re-sealed, \(report.alreadyCorrect) already right, \(report.failed) failed")
        state = .repaired(report)
    }

    private enum Outcome { case rewrapped, alreadyCorrect, unencrypted, failed }

    private func repairOne(fileID: String, published: PublishedKey, deviceKey: KeyBundle,
                           using transport: DeviceKeyTransport) async -> Outcome {
        let ref: (sealed: String, keyVersion: Int)?
        do {
            ref = try await withBackoff(transport) { try await transport.fileKey(fileID: fileID) }
        } catch {
            logger.error("repair: reading key for \(fileID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
        guard let ref else { return .unencrypted }
        guard let resealed = DeviceKeyRewrap.rewrap(ref.sealed, deviceKey: deviceKey, to: published) else {
            return .alreadyCorrect
        }
        do {
            try await withBackoff(transport) {
                try await transport.setFileKey(fileID: fileID, sealed: resealed, keyVersion: published.version)
            }
            return .rewrapped
        } catch {
            logger.error("repair: writing key for \(fileID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    private func withBackoff<T>(_ transport: DeviceKeyTransport,
                                _ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < Self.backoff.count, transport.isRetryable(error) else { throw error }
                await sleep(Self.backoff[attempt])
                attempt += 1
            }
        }
    }
}
