import Foundation
import os.log

// MARK: - OfflineFileCache

/// The last copy of each recently opened file, exactly as the server holds it, so the file can
/// still be opened — read-only — without a connection.
///
/// What is kept is what the server keeps: the ciphertext body and the file key sealed to the
/// account's identity. Neither is readable without the identity key in the Keychain, so the cache
/// adds nothing an attacker holding the device's disk could not already have fetched with the
/// account's session. No plaintext and no unsealed key is ever written here.
///
/// The app supplies `metadata` — its own encoding of whatever it needs to show the file (a name, a
/// role, a content version) — and reads it back the same way; the cache does not interpret it.
///
/// Bounded by count and by bytes; the least recently stored entries go first. It is the apps' job
/// to call `removeAll()` on sign-out, so the next account does not inherit this one's copies.
///
/// Not thread-safe: use it from one actor, which in the apps is the main actor.
public final class OfflineFileCache {

    // MARK: - Entry

    public struct Entry: Codable, Equatable, Sendable {
        public let fileID: String
        public let sealedKey: String
        public let keyVersion: Int
        public let metadata: Data
        public let byteCount: Int
        public let storedAt: Date
    }

    // MARK: - Properties

    public let directory: URL
    public let maxEntries: Int
    public let maxBytes: Int

    private let fileManager: FileManager
    private let logger: Logger

    // MARK: - Init

    public init(directory: URL, maxEntries: Int = 30, maxBytes: Int = 250 * 1024 * 1024,
                fileManager: FileManager = .default) {
        self.directory = directory
        self.maxEntries = max(1, maxEntries)
        self.maxBytes = max(1, maxBytes)
        self.fileManager = fileManager
        self.logger = Logger(
            subsystem: NeutrinoApp.isConfigured ? NeutrinoApp.current.logSubsystem : "app.getneutrino.shared",
            category: "OfflineFileCache"
        )
    }

    /// `Application Support/<name>`: kept across launches, excluded from backups, never purged by
    /// the system the way `Caches` is — an offline copy that vanishes under storage pressure is
    /// gone exactly when the user is somewhere without a connection to fetch it again.
    public static func inApplicationSupport(named name: String = "OfflineFiles") -> OfflineFileCache {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return OfflineFileCache(directory: base.appendingPathComponent(name, isDirectory: true))
    }

    // MARK: - Reading

    /// Every entry, newest first.
    public var entries: [Entry] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
                return try? Self.decoder.decode(Entry.self, from: data)
            }
            .sorted { $0.storedAt > $1.storedAt }
    }

    public func entry(for fileID: String) -> Entry? {
        guard let data = try? Data(contentsOf: entryURL(fileID)) else { return nil }
        return try? Self.decoder.decode(Entry.self, from: data)
    }

    /// The entry and its body together, or nil when either is missing — a half-written pair is no
    /// copy at all.
    public func copy(for fileID: String) -> (entry: Entry, ciphertext: Data)? {
        guard let entry = entry(for: fileID),
              let body = try? Data(contentsOf: bodyURL(fileID)),
              body.count == entry.byteCount else { return nil }
        return (entry, body)
    }

    // MARK: - Writing

    /// Keeps `ciphertext` as the file's offline copy, replacing any earlier one, then trims the
    /// cache to its limits. A body larger than the whole budget is not kept.
    public func store(fileID: String, ciphertext: Data, sealedKey: String, keyVersion: Int,
                      metadata: Data, now: Date = Date()) throws {
        guard ciphertext.count <= maxBytes else {
            logger.debug("store: id=\(fileID, privacy: .public) is larger than the cache; not kept")
            remove(fileID: fileID)
            return
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)

        let entry = Entry(fileID: fileID, sealedKey: sealedKey, keyVersion: keyVersion,
                          metadata: metadata, byteCount: ciphertext.count, storedAt: now)
        // Body first, entry second: `copy(for:)` treats an entry without its body as absent, so a
        // crash between the two leaves no copy rather than a corrupt one.
        try ciphertext.write(to: bodyURL(fileID), options: Self.writeOptions)
        try Self.encoder.encode(entry).write(to: entryURL(fileID), options: Self.writeOptions)
        trim()
    }

    public func remove(fileID: String) {
        try? fileManager.removeItem(at: entryURL(fileID))
        try? fileManager.removeItem(at: bodyURL(fileID))
    }

    /// For sign-out.
    public func removeAll() {
        try? fileManager.removeItem(at: directory)
    }

    // MARK: - Private

    private func trim() {
        var kept = 0
        var bytes = 0
        for entry in entries {
            if kept < maxEntries, bytes + entry.byteCount <= maxBytes {
                kept += 1
                bytes += entry.byteCount
            } else {
                remove(fileID: entry.fileID)
            }
        }
    }

    /// A file id is a UUID in practice, but it comes from the server: anything outside a safe
    /// alphabet is percent-encoded so an id can never name a path outside the directory.
    private func stem(_ fileID: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        let encoded = fileID.addingPercentEncoding(withAllowedCharacters: allowed) ?? UUID().uuidString
        return encoded.isEmpty ? "_" : encoded
    }

    private func entryURL(_ fileID: String) -> URL { directory.appendingPathComponent(stem(fileID) + ".json") }
    private func bodyURL(_ fileID: String) -> URL { directory.appendingPathComponent(stem(fileID) + ".blob") }

    #if os(iOS)
    private static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    #else
    private static let writeOptions: Data.WritingOptions = [.atomic]
    #endif

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
