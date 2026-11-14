import Foundation
import Sodium

// MARK: - DriveFileCryptoError

public enum DriveFileCryptoError: LocalizedError, Equatable {
    case encryptionFailed
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .encryptionFailed: return "The file could not be encrypted."
        case .decryptionFailed: return "The file could not be decrypted. It may be damaged, or sealed to a key this device doesn't have."
        }
    }
}

// MARK: - DriveFileCrypto

/// The primitives an encrypted Drive file goes through: its data encryption key (DEK), its
/// content, and its metadata. No networking and no actor, so any app can call them from any
/// context and tests can assert them directly.
///
/// ## Wire format
///
/// - **DEK:** 32 random bytes, generated per file, sealed to the account's Curve25519 identity
///   key with `crypto_box_seal`, base64url without padding. Stored server-side with the keyring
///   version it was sealed to (`PUT /drive/files/{id}/key`).
/// - **Content:** one of three shapes, told apart by the bytes
///   (`neutrino/agent_docs/chunked-file-encryption.md`): **v0**, one secretstream push of the whole
///   file; **NEB1**, a self-describing chunked blob; and **Photos-chunked**, chunks whose size is
///   in the encrypted metadata as `chunkSize`. ``decrypt(_:dek:chunkSize:)`` and the streaming
///   ``decrypt(from:to:dek:chunkSize:)`` open all three; new chunked writes are NEB1.
/// - **Metadata:** `{ name, mimeType[, chunkSize] }` as JSON, encrypted as one push with the DEK,
///   base64url without padding.
///
/// These are the web's `encryptFileKey` / `decryptFileKey` / `encryptFile` / `decryptFile` /
/// `encryptMetadata` / `decryptMetadata` (`packages/e2e-crypto/src/crypto.ts`), and match the
/// copies inside the Drive (`SealedKeyCrypto`) and Photos (`MediaCrypto`) apps, so a file written
/// by any of them opens in the others. Changing anything here is a wire-format change across the
/// web, every iOS app, the macOS client and the server.
public enum DriveFileCrypto {

    private static let sodium = Sodium()

    /// The secretstream header, which prefixes every ciphertext.
    public static let headerBytes = SecretStream.XChaCha20Poly1305.HeaderBytes
    /// The per-chunk overhead: a tag byte plus a 16-byte Poly1305 MAC.
    public static let chunkOverheadBytes = SecretStream.XChaCha20Poly1305.ABytes

    // MARK: - Keys

    /// A fresh 32-byte DEK.
    public static func newDEK() -> Bytes {
        sodium.secretStream.xchacha20poly1305.key()
    }

    /// Seals `dek` to a Curve25519 public key, returning base64url.
    public static func seal(dek: Bytes, toPublicKey publicKey: Bytes) throws -> String {
        guard let sealed = sodium.box.seal(message: dek, recipientPublicKey: publicKey),
              let encoded = sodium.utils.bin2base64(sealed, variant: .URLSAFE_NO_PADDING) else {
            throw DriveFileCryptoError.encryptionFailed
        }
        return encoded
    }

    /// Opens a DEK sealed by ``seal(dek:toPublicKey:)``.
    public static func openDEK(_ sealedBase64URL: String, publicKey: Bytes, secretKey: Bytes) throws -> Bytes {
        guard let sealed = sodium.utils.base642bin(sealedBase64URL, variant: .URLSAFE_NO_PADDING),
              let dek: Bytes = sodium.box.open(anonymousCipherText: sealed,
                                               recipientPublicKey: publicKey,
                                               recipientSecretKey: secretKey) else {
            throw DriveFileCryptoError.decryptionFailed
        }
        return dek
    }

    // MARK: - Content

    /// Encrypts `plaintext` as a single push, the format every client reads.
    public static func encrypt(_ plaintext: Data, dek: Bytes) throws -> Data {
        guard let stream = sodium.secretStream.xchacha20poly1305.initPush(secretKey: dek),
              let ciphertext = stream.push(message: Bytes(plaintext), tag: .FINAL) else {
            throw DriveFileCryptoError.encryptionFailed
        }
        return Data(stream.header() + ciphertext)
    }

    /// Decrypts a file body in any of the three shapes the platform writes, chosen by the bytes
    /// (`neutrino/agent_docs/chunked-file-encryption.md` §3.5–§3.6):
    ///
    /// - **NEB1** — starts `NEB1`; self-describing, its header authenticated on every chunk.
    /// - **Photos-chunked** — `[header][chunk]…[FINAL chunk]`, with `chunkSize` in the metadata.
    /// - **v0** — one push; everything else.
    ///
    /// A NEB1 header that fails its structural checks falls through to the other shapes (a v0
    /// header starts `NEB1` by chance once in 2³²); one that fails authentication does not. A body
    /// read without its metadata that fails as one push is retried as 1 MiB chunks, the only size
    /// Photos has written — safe, because both readings are fully authenticated.
    ///
    /// - Parameter chunkSize: the framing from the file's metadata; nil for most files.
    public static func decrypt(_ data: Data, dek: Bytes, chunkSize: Int? = nil) throws -> Data {
        if data.starts(with: neb1Magic) {
            do {
                return try decryptNEB1(data, dek: dek)
            } catch ChunkedFailure.header {
                // Structural: a v0 or Photos body whose random header begins `NEB1`. Fall through.
            } catch {
                throw DriveFileCryptoError.decryptionFailed
            }
        }
        if let chunkSize, chunkSize > 0 {
            return try decryptPhotosChunked(data, dek: dek, chunkSize: chunkSize)
        }
        do {
            return try decryptSinglePush(data, dek: dek)
        } catch {
            if data.count > headerBytes + photosChunkSize + chunkOverheadBytes,
               let plaintext = try? decryptPhotosChunked(data, dek: dek, chunkSize: photosChunkSize) {
                return plaintext
            }
            throw error
        }
    }

    /// v0, unchanged: one push, tagged FINAL.
    private static func decryptSinglePush(_ data: Data, dek: Bytes) throws -> Data {
        guard data.count > headerBytes,
              let pull = sodium.secretStream.xchacha20poly1305.initPull(
                secretKey: dek, header: Bytes(data.prefix(headerBytes))),
              let (plaintext, tag) = pull.pull(cipherText: Bytes(data.dropFirst(headerBytes))),
              tag == .FINAL else {
            throw DriveFileCryptoError.decryptionFailed
        }
        return Data(plaintext)
    }

    /// The Photos-chunked shape (§3.6): no prefix, no AD, every chunk but the last exactly
    /// `chunkSize`, the last tagged FINAL with nothing after it.
    static func decryptPhotosChunked(_ data: Data, dek: Bytes, chunkSize: Int) throws -> Data {
        guard (1...neb1MaxChunkSize).contains(chunkSize), data.count > headerBytes,
              let pull = sodium.secretStream.xchacha20poly1305.initPull(
                secretKey: dek, header: Bytes(data.prefix(headerBytes))) else {
            throw DriveFileCryptoError.decryptionFailed
        }
        let body = data.dropFirst(headerBytes)
        var plaintext = Data()
        plaintext.reserveCapacity(body.count)
        var offset = body.startIndex
        var sawFinal = false
        while offset < body.endIndex {
            let end = body.index(offset, offsetBy: chunkSize + chunkOverheadBytes,
                                 limitedBy: body.endIndex) ?? body.endIndex
            guard let (chunk, tag) = pull.pull(cipherText: Bytes(body[offset..<end])) else {
                throw DriveFileCryptoError.decryptionFailed
            }
            plaintext.append(contentsOf: chunk)
            offset = end
            if tag == .FINAL { sawFinal = true; break }
            // A short chunk that isn't the last means a re-framed body.
            guard chunk.count == chunkSize else { throw DriveFileCryptoError.decryptionFailed }
        }
        // Every chunk authenticates itself, so only this catches a stream cut short.
        guard sawFinal, offset == body.endIndex else { throw DriveFileCryptoError.decryptionFailed }
        return plaintext
    }

    // MARK: - NEB1

    /// `NEB1`: "Neutrino Encrypted Blob, format 1".
    public static let neb1Magic: Bytes = [0x4E, 0x45, 0x42, 0x31]
    public static let neb1DefaultChunkSize = 1 << 20
    public static let neb1MinChunkSize = 4096
    public static let neb1MaxChunkSize = 16 * 1024 * 1024
    /// The chunk size Neutrino Photos iOS writes its chunked bodies with.
    public static let photosChunkSize = 1 << 20
    static let neb1PrefixBytes = 20
    static let neb1HeaderBytes = 44

    /// Which kind of NEB1 failure: only a structural one may fall through to another shape.
    enum ChunkedFailure: Error { case header, authentication }

    /// The 20-byte prefix, which is also every chunk's additional data.
    static func neb1Prefix(chunkSize: Int, plaintextLength: UInt64) -> Bytes {
        var prefix = neb1Magic + [0x01, 0x01, 0x00, 0x00]
        prefix += withUnsafeBytes(of: UInt32(chunkSize).bigEndian, Array.init)
        prefix += withUnsafeBytes(of: plaintextLength.bigEndian, Array.init)
        return prefix
    }

    /// Encrypts `plaintext` as NEB1 (§4.1), in memory. ``encryptNEB1(from:to:dek:chunkSize:)``
    /// writes the same bytes holding one chunk at a time.
    public static func encryptNEB1(_ plaintext: Data, dek: Bytes,
                                   chunkSize: Int = neb1DefaultChunkSize) throws -> Data {
        var out = Data()
        try encryptNEB1(length: UInt64(plaintext.count), dek: dek, chunkSize: chunkSize,
                        read: { offset, count in plaintext.subdata(in: offset..<offset + count) },
                        write: { out.append(contentsOf: $0) })
        return out
    }

    /// Encrypts `plaintext` as NEB1, handing each piece to `write` as it is made — the 44-byte
    /// header first, then one ciphertext chunk at a time — so the caller can stream it into a
    /// request body without the ciphertext ever existing whole. Returns the ciphertext's length.
    @discardableResult
    public static func encryptNEB1(_ plaintext: Data, dek: Bytes,
                                   chunkSize: Int = neb1DefaultChunkSize,
                                   writing write: (Bytes) throws -> Void) throws -> Int {
        var written = 0
        try encryptNEB1(length: UInt64(plaintext.count), dek: dek, chunkSize: chunkSize,
                        read: { offset, count in plaintext.subdata(in: offset..<offset + count) },
                        write: { bytes in try write(bytes); written += bytes.count })
        return written
    }

    /// Encrypts the file at `source` into a new file at `destination` as NEB1, holding one chunk of
    /// plaintext and one of ciphertext at a time. Returns the ciphertext's length.
    @discardableResult
    public static func encryptNEB1(from source: URL, to destination: URL, dek: Bytes,
                                   chunkSize: Int = neb1DefaultChunkSize) throws -> Int {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let length = try input.seekToEnd()
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var written = 0
        try encryptNEB1(length: length, dek: dek, chunkSize: chunkSize,
                        read: { offset, count in
                            try input.seek(toOffset: UInt64(offset))
                            return try input.read(upToCount: count) ?? Data()
                        },
                        write: { bytes in
                            try output.write(contentsOf: bytes)
                            written += bytes.count
                        })
        return written
    }

    private static func encryptNEB1(length: UInt64, dek: Bytes, chunkSize: Int,
                                     read: (Int, Int) throws -> Data,
                                     write: (Bytes) throws -> Void) throws {
        guard (neb1MinChunkSize...neb1MaxChunkSize).contains(chunkSize),
              let stream = sodium.secretStream.xchacha20poly1305.initPush(secretKey: dek) else {
            throw DriveFileCryptoError.encryptionFailed
        }
        let total = Int(length)
        let prefix = neb1Prefix(chunkSize: chunkSize, plaintextLength: length)
        try write(prefix + stream.header())
        let count = max(1, (total + chunkSize - 1) / chunkSize)
        for index in 0..<count {
            let offset = index * chunkSize
            let plain = try read(offset, min(chunkSize, total - offset))
            guard let cipher = stream.push(message: Bytes(plain),
                                           tag: index == count - 1 ? .FINAL : .MESSAGE,
                                           ad: prefix) else {
                throw DriveFileCryptoError.encryptionFailed
            }
            try write(cipher)
        }
    }

    /// The parsed, length-checked header of a NEB1 blob (§4.2 steps 1–8). Throws
    /// ``ChunkedFailure/header`` for anything structural, before a byte is decrypted.
    struct NEB1Header {
        let prefix: Bytes
        let streamHeader: Bytes
        let chunkSize: Int
        let plaintextLength: Int
        var chunkCount: Int { max(1, (plaintextLength + chunkSize - 1) / chunkSize) }

        init(_ header: Bytes, totalLength: UInt64) throws {
            guard header.count >= DriveFileCrypto.neb1HeaderBytes,
                  Array(header[0..<4]) == DriveFileCrypto.neb1Magic else { throw ChunkedFailure.header }
            guard header[4] == 0x01, header[5] == 0x01, header[6] == 0, header[7] == 0 else {
                throw ChunkedFailure.header
            }
            let size = header[8..<12].reduce(0) { $0 << 8 | Int($1) }
            let length = header[12..<20].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard (DriveFileCrypto.neb1MinChunkSize...DriveFileCrypto.neb1MaxChunkSize).contains(size),
                  length <= UInt64(Int.max / 2) else { throw ChunkedFailure.header }
            chunkSize = size
            plaintextLength = Int(length)
            prefix = Array(header[0..<20])
            streamHeader = Array(header[20..<44])
            let expected = UInt64(DriveFileCrypto.neb1HeaderBytes + plaintextLength
                                  + DriveFileCrypto.chunkOverheadBytes * chunkCount)
            guard totalLength == expected else { throw ChunkedFailure.header }
        }
    }

    /// Decrypts a NEB1 blob in memory (§4.2).
    static func decryptNEB1(_ data: Data, dek: Bytes) throws -> Data {
        let header = try NEB1Header(Bytes(data.prefix(neb1HeaderBytes)), totalLength: UInt64(data.count))
        var out = Data()
        out.reserveCapacity(header.plaintextLength)
        try decryptNEB1Chunks(header, dek: dek,
                              read: { offset, count in Bytes(data.subdata(in: offset..<offset + count)) },
                              write: { out.append(contentsOf: $0) })
        return out
    }

    private static func decryptNEB1Chunks(_ header: NEB1Header, dek: Bytes,
                                          read: (Int, Int) throws -> Bytes,
                                          write: (Bytes) throws -> Void) throws {
        guard let pull = sodium.secretStream.xchacha20poly1305.initPull(secretKey: dek,
                                                                         header: header.streamHeader) else {
            throw ChunkedFailure.authentication
        }
        var offset = neb1HeaderBytes
        for index in 0..<header.chunkCount {
            let want = min(header.chunkSize, header.plaintextLength - index * header.chunkSize)
            let cipher = try read(offset, want + chunkOverheadBytes)
            guard let (plain, tag) = pull.pull(cipherText: cipher, ad: header.prefix),
                  plain.count == want,
                  tag == (index == header.chunkCount - 1 ? .FINAL : .MESSAGE) else {
                throw ChunkedFailure.authentication
            }
            try write(plain)
            offset += want + chunkOverheadBytes
        }
    }

    // MARK: - Streaming decrypt

    /// Decrypts the file at `source` into a new file at `destination`, in any of the three shapes.
    ///
    /// NEB1 and Photos-chunked bodies are decrypted one chunk at a time, so a video of any size
    /// needs about one chunk of memory — a Photos body even without its metadata, recognised by
    /// authenticating its first 1 MiB chunk. A v0 body is one push and can only be opened whole,
    /// exactly as ``decrypt(_:dek:chunkSize:)`` does. On failure the destination is removed.
    public static func decrypt(from source: URL, to destination: URL, dek: Bytes,
                               chunkSize: Int? = nil) throws {
        do {
            try streamDecrypt(from: source, to: destination, dek: dek, chunkSize: chunkSize)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw DriveFileCryptoError.decryptionFailed
        }
    }

    private static func streamDecrypt(from source: URL, to destination: URL, dek: Bytes,
                                      chunkSize: Int?) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let length = try input.seekToEnd()
        try input.seek(toOffset: 0)
        let head = Bytes(try input.read(upToCount: neb1HeaderBytes) ?? Data())

        let open = { () throws -> FileHandle in
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            return try FileHandle(forWritingTo: destination)
        }
        let read = { (offset: Int, count: Int) throws -> Bytes in
            try input.seek(toOffset: UInt64(offset))
            return Bytes(try input.read(upToCount: count) ?? Data())
        }

        if head.starts(with: neb1Magic), let header = try? NEB1Header(head, totalLength: length) {
            let output = try open()
            defer { try? output.close() }
            try decryptNEB1Chunks(header, dek: dek, read: read, write: { try output.write(contentsOf: $0) })
            return
        }
        let photosSize: Int? = {
            if let chunkSize, chunkSize > 0 { return chunkSize }
            return nil
        }()
        if let photosSize {
            let output = try open()
            defer { try? output.close() }
            try streamPhotosChunked(length: Int(length), dek: dek, chunkSize: photosSize, read: read,
                                    write: { try output.write(contentsOf: $0) })
            return
        }
        // No metadata. A Photos body (always 1 MiB chunks) is recognised by authenticating just its
        // first chunk: a genuine one opens as a non-final message, while a v0 body can't — its only
        // tag is at the very end. That keeps a large Photos video streaming instead of read whole.
        if Int(length) > headerBytes + photosChunkSize + chunkOverheadBytes,
           let probe = sodium.secretStream.xchacha20poly1305.initPull(secretKey: dek, header: try read(0, headerBytes)),
           let (_, tag) = probe.pull(cipherText: try read(headerBytes, photosChunkSize + chunkOverheadBytes)),
           tag == .MESSAGE {
            let output = try open()
            defer { try? output.close() }
            try streamPhotosChunked(length: Int(length), dek: dek, chunkSize: photosChunkSize, read: read,
                                    write: { try output.write(contentsOf: $0) })
            return
        }
        // v0 has no framing to stream by. Read whole, as the in-memory path does — including its
        // 1 MiB retry, kept for symmetry with it.
        try input.seek(toOffset: 0)
        let whole = try input.readToEnd() ?? Data()
        let output = try open()
        defer { try? output.close() }
        if let plain = try? decryptSinglePush(whole, dek: dek) {
            try output.write(contentsOf: plain)
            return
        }
        guard whole.count > headerBytes + photosChunkSize + chunkOverheadBytes else {
            throw DriveFileCryptoError.decryptionFailed
        }
        try streamPhotosChunked(length: whole.count, dek: dek, chunkSize: photosChunkSize,
                                read: { offset, count in Bytes(whole.subdata(in: offset..<min(whole.count, offset + count))) },
                                write: { try output.write(contentsOf: $0) })
    }

    private static func streamPhotosChunked(length: Int, dek: Bytes, chunkSize: Int,
                                            read: (Int, Int) throws -> Bytes,
                                            write: (Bytes) throws -> Void) throws {
        guard (1...neb1MaxChunkSize).contains(chunkSize), length > headerBytes,
              let pull = sodium.secretStream.xchacha20poly1305.initPull(
                secretKey: dek, header: try read(0, headerBytes)) else {
            throw DriveFileCryptoError.decryptionFailed
        }
        var offset = headerBytes
        var sawFinal = false
        while offset < length {
            let count = min(chunkSize + chunkOverheadBytes, length - offset)
            guard let (chunk, tag) = pull.pull(cipherText: try read(offset, count)) else {
                throw DriveFileCryptoError.decryptionFailed
            }
            try write(chunk)
            offset += count
            if tag == .FINAL { sawFinal = true; break }
            guard chunk.count == chunkSize else { throw DriveFileCryptoError.decryptionFailed }
        }
        guard sawFinal, offset == length else { throw DriveFileCryptoError.decryptionFailed }
    }

    // MARK: - Metadata

    /// The plaintext of a file's `encryptedMetadata`.
    public struct Metadata: Equatable, Sendable {
        public let name: String
        public let mimeType: String
        /// The content's framing; nil for a single push.
        public let chunkSize: Int?

        public init(name: String, mimeType: String, chunkSize: Int? = nil) {
            self.name = name
            self.mimeType = mimeType
            self.chunkSize = chunkSize
        }
    }

    /// Encrypts `{ name, mimeType }` (and `chunkSize` only when the content is chunked, so an
    /// ordinary file's blob is exactly the web's shape).
    public static func encryptMetadata(_ metadata: Metadata, dek: Bytes) throws -> String {
        var fields: [String: Any] = ["name": metadata.name, "mimeType": metadata.mimeType]
        if let chunkSize = metadata.chunkSize { fields["chunkSize"] = chunkSize }
        guard let json = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let encoded = sodium.utils.bin2base64(Bytes(try encrypt(json, dek: dek)),
                                                    variant: .URLSAFE_NO_PADDING) else {
            throw DriveFileCryptoError.encryptionFailed
        }
        return encoded
    }

    public static func decryptMetadata(_ encoded: String, dek: Bytes) throws -> Metadata {
        guard let raw = sodium.utils.base642bin(encoded, variant: .URLSAFE_NO_PADDING) else {
            throw DriveFileCryptoError.decryptionFailed
        }
        let json = try decrypt(Data(raw), dek: dek)
        guard let fields = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw DriveFileCryptoError.decryptionFailed
        }
        return Metadata(name: fields["name"] as? String ?? "",
                        mimeType: fields["mimeType"] as? String ?? "application/octet-stream",
                        chunkSize: fields["chunkSize"] as? Int)
    }
}
