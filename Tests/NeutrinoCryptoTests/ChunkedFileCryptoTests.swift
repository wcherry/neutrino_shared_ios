import XCTest
import CryptoKit
import Sodium
@testable import NeutrinoCrypto

/// Chunked file bodies against the platform's canonical vectors.
///
/// `Fixtures/chunked_file_vectors.json` is a copy of
/// `neutrino/web/packages/e2e-crypto/src/__tests__/fixtures/chunked_file_vectors.json`, the only
/// editable one, generated from an independent libsodium implementation
/// (`scripts/sync-chunked-file-vectors.sh` refreshes it). Opening every case here, on the web and in
/// every other client is what keeps them able to read each other's files.
final class ChunkedFileCryptoTests: XCTestCase {

    private struct Vectors: Decodable {
        struct Case: Decodable {
            let name: String
            let shape: String
            let length: Int
            let chunkSize: Int?
            let sha256: String
            let ciphertext: String
        }
        struct Rejected: Decodable {
            let name: String
            let ciphertext: String
            let chunkSize: Int?
            let dek: String?
        }
        let dek: String
        let cases: [Case]
        let rejected: [Rejected]
    }

    private static let vectors: Vectors = {
        let url = Bundle.module.url(forResource: "chunked_file_vectors", withExtension: "json",
                                    subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()

    private var dek: Bytes { Bytes(Data(base64Encoded: Self.vectors.dek)!) }
    private func data(_ base64: String) -> Data { Data(base64Encoded: base64)! }
    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func plaintext(_ length: Int) -> Data {
        Data((0..<length).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })
    }
    private func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunked-\(UUID().uuidString)-\(name)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Vectors

    func testEveryCaseOpens() throws {
        XCTAssertEqual(Self.vectors.cases.count, 11)
        for c in Self.vectors.cases {
            let plain = try DriveFileCrypto.decrypt(data(c.ciphertext), dek: dek, chunkSize: c.chunkSize)
            XCTAssertEqual(plain.count, c.length, c.name)
            XCTAssertEqual(sha256(plain), c.sha256, c.name)
        }
    }

    func testEveryCaseOpensStreamingToDisk() throws {
        for c in Self.vectors.cases {
            let source = temp("in"), destination = temp("out")
            try data(c.ciphertext).write(to: source)
            try DriveFileCrypto.decrypt(from: source, to: destination, dek: dek, chunkSize: c.chunkSize)
            XCTAssertEqual(sha256(try Data(contentsOf: destination)), c.sha256, c.name)
        }
    }

    func testAPhotosBodyOpensWithoutItsMetadata() throws {
        let c = try XCTUnwrap(Self.vectors.cases.first { $0.name == "photos-1mib" })
        XCTAssertEqual(sha256(try DriveFileCrypto.decrypt(data(c.ciphertext), dek: dek)), c.sha256)
        let source = temp("in"), destination = temp("out")
        try data(c.ciphertext).write(to: source)
        try DriveFileCrypto.decrypt(from: source, to: destination, dek: dek)
        XCTAssertEqual(sha256(try Data(contentsOf: destination)), c.sha256)
    }

    func testAPhotosBodyWithoutMetadataStreamsRatherThanLoadingWhole() throws {
        // A body larger than one chunk whose first chunk authenticates as a non-final message is
        // streamed; the same file truncated mid-way still fails, so the probe proves nothing alone.
        let c = try XCTUnwrap(Self.vectors.cases.first { $0.name == "photos-1mib" })
        let full = data(c.ciphertext)
        let source = temp("in"), destination = temp("out")
        try full.prefix(full.count - 3).write(to: source)
        XCTAssertThrowsError(try DriveFileCrypto.decrypt(from: source, to: destination, dek: dek))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testEveryRejectionFailsInMemoryAndStreaming() throws {
        XCTAssertEqual(Self.vectors.rejected.count, 13)
        for r in Self.vectors.rejected {
            let key = r.dek.map { Bytes(Data(base64Encoded: $0)!) } ?? dek
            XCTAssertThrowsError(try DriveFileCrypto.decrypt(data(r.ciphertext), dek: key, chunkSize: r.chunkSize),
                                 r.name)
            XCTAssertThrowsError(try DriveFileCrypto.decrypt(data(r.ciphertext), dek: key), "\(r.name), no metadata")
            let source = temp("in"), destination = temp("out")
            try data(r.ciphertext).write(to: source)
            XCTAssertThrowsError(try DriveFileCrypto.decrypt(from: source, to: destination, dek: key,
                                                             chunkSize: r.chunkSize), "\(r.name), streaming")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                           "\(r.name): a failed decrypt leaves no partial plaintext behind")
        }
    }

    // MARK: - NEB1 writer

    func testNEB1RoundTripsAtTheBoundarySizes() throws {
        for chunk in [DriveFileCrypto.neb1MinChunkSize, 65_536] {
            for size in [0, 1, chunk - 1, chunk, chunk + 1, 2 * chunk, 2 * chunk + 1] {
                let key = DriveFileCrypto.newDEK()
                let plain = plaintext(size)
                let blob = try DriveFileCrypto.encryptNEB1(plain, dek: key, chunkSize: chunk)
                XCTAssertEqual(blob.count, 44 + size + 17 * max(1, (size + chunk - 1) / chunk))
                XCTAssertTrue(blob.starts(with: DriveFileCrypto.neb1Magic))
                XCTAssertEqual(try DriveFileCrypto.decrypt(blob, dek: key), plain, "\(size) at \(chunk)")
            }
        }
    }

    func testTheStreamingWriterProducesWhatTheWebReads() throws {
        // Same shape and bytes as the in-memory writer, checked by structure (headers are random).
        let key = DriveFileCrypto.newDEK()
        let plain = plaintext(3 * 4096 + 5)
        let source = temp("plain"), encrypted = temp("enc"), decrypted = temp("dec")
        try plain.write(to: source)
        let written = try DriveFileCrypto.encryptNEB1(from: source, to: encrypted, dek: key, chunkSize: 4096)
        let blob = try Data(contentsOf: encrypted)
        XCTAssertEqual(written, blob.count)
        XCTAssertEqual(blob.count, 44 + plain.count + 17 * 4)
        XCTAssertEqual(Array(blob[0..<20]), DriveFileCrypto.neb1Prefix(chunkSize: 4096, plaintextLength: UInt64(plain.count)))
        try DriveFileCrypto.decrypt(from: encrypted, to: decrypted, dek: key)
        XCTAssertEqual(try Data(contentsOf: decrypted), plain)
    }

    func testTheChunkByChunkWriterMatchesTheWholeOne() throws {
        let key = DriveFileCrypto.newDEK()
        let plain = plaintext(10_000)
        var pieces: [Int] = []
        var blob = Data()
        let count = try DriveFileCrypto.encryptNEB1(plain, dek: key, chunkSize: 4096) { bytes in
            pieces.append(bytes.count)
            blob.append(contentsOf: bytes)
        }
        XCTAssertEqual(pieces, [44, 4096 + 17, 4096 + 17, 1808 + 17], "header, then one chunk at a time")
        XCTAssertEqual(count, blob.count)
        XCTAssertEqual(try DriveFileCrypto.decrypt(blob, dek: key), plain)
    }

    func testTheWriterRefusesAChunkSizeOutsideTheRange() {
        let key = DriveFileCrypto.newDEK()
        XCTAssertThrowsError(try DriveFileCrypto.encryptNEB1(plaintext(10), dek: key, chunkSize: 4095))
        XCTAssertThrowsError(try DriveFileCrypto.encryptNEB1(plaintext(10), dek: key,
                                                             chunkSize: DriveFileCrypto.neb1MaxChunkSize + 1))
    }

    func testATamperedNEB1BlobIsNotRetriedAsAnotherShape() throws {
        let key = DriveFileCrypto.newDEK()
        var blob = try DriveFileCrypto.encryptNEB1(plaintext(10_000), dek: key, chunkSize: 4096)
        blob[blob.count - 1] ^= 0x01
        XCTAssertThrowsError(try DriveFileCrypto.decrypt(blob, dek: key))
        XCTAssertThrowsError(try DriveFileCrypto.decryptNEB1(blob, dek: key)) { error in
            XCTAssertEqual(error as? DriveFileCrypto.ChunkedFailure, .authentication)
        }
    }

    func testAMalformedHeaderIsStructural() throws {
        let key = DriveFileCrypto.newDEK()
        var blob = try DriveFileCrypto.encryptNEB1(plaintext(100), dek: key)
        blob[4] = 0x09
        XCTAssertThrowsError(try DriveFileCrypto.decryptNEB1(blob, dek: key)) { error in
            XCTAssertEqual(error as? DriveFileCrypto.ChunkedFailure, .header)
        }
    }

    // MARK: - v0 unchanged

    func testV0StillRoundTrips() throws {
        let key = DriveFileCrypto.newDEK()
        for size in [1, 4096, 2 * 1024 * 1024 + 3] {
            let plain = plaintext(size)
            XCTAssertEqual(try DriveFileCrypto.decrypt(DriveFileCrypto.encrypt(plain, dek: key), dek: key), plain)
        }
    }
}
