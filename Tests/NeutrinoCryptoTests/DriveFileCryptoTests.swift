import XCTest
import Sodium
@testable import NeutrinoCrypto

final class DriveFileCryptoTests: XCTestCase {

    private let sodium = Sodium()

    private func bytes(_ base64URL: String) -> Bytes {
        sodium.utils.base642bin(base64URL, variant: .URLSAFE_NO_PADDING)!
    }

    /// Written by the web's own `crypto.ts` (`generateKeyPair`, `encryptFileKey`, `encryptFile`,
    /// `encryptMetadata`). If this stops opening, files uploaded on the web stop opening on iOS.
    private enum Web {
        static let publicKey = "vPjHlNHlr_h7QbhzgDgWkWA9hCObw2DIHUUDCp8olwY"
        static let secretKey = "6dRCdLRpJyfBdwze5eK1P2F2ZTRe4trt5pmSQ7aB4OA"
        static let sealedDEK = "uu20w15mE1P7rYF9Y9qFUauqQmyVTqtE47Xoo_JUZkGbwyub3GZpTtWbvYN6ZQx9i1NXtXwbWdpqVEhjX6EIomS1_AfvtOMdLwLcxK5F2LI"
        static let content = "G72q518cp9-LmBq-Hwnw80i72JBR6wdyaIdX4MiDzH6guMLFcOh7m63LG-Zwc8P6jZ_Ly_nWfZEFGVYMjxgiCPWQHDiOFYWzLBEHISzZfefUHZY"
        static let metadata = "-5rAIYIgLKL_uLcez7xLevkmFOUOcvhjfv687s89nBwkEULZDH1HNJDnBpmLWue6O_YRJl2ccY4Qx8kmViYt_775JFtGvg15TUciDemX0SXYVKceL9A"
        static let plaintext = "Agenda for the offsite — ünïcødé ✓"
    }

    func testAFileWrittenByTheWebOpens() throws {
        let dek = try DriveFileCrypto.openDEK(Web.sealedDEK, publicKey: bytes(Web.publicKey),
                                              secretKey: bytes(Web.secretKey))
        let metadata = try DriveFileCrypto.decryptMetadata(Web.metadata, dek: dek)
        XCTAssertEqual(metadata, .init(name: "Agenda.txt", mimeType: "text/plain"))
        let plaintext = try DriveFileCrypto.decrypt(Data(bytes(Web.content)), dek: dek,
                                                    chunkSize: metadata.chunkSize)
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), Web.plaintext)
    }

    func testRoundTripAndTheWebsSinglePushShape() throws {
        let dek = DriveFileCrypto.newDEK()
        let original = Data("hello, calendar".utf8)
        let sealed = try DriveFileCrypto.encrypt(original, dek: dek)
        XCTAssertEqual(sealed.count, original.count + DriveFileCrypto.headerBytes + DriveFileCrypto.chunkOverheadBytes)
        XCTAssertEqual(try DriveFileCrypto.decrypt(sealed, dek: dek), original)
    }

    func testTheDEKOpensOnlyWithTheRightKey() throws {
        let mine = sodium.box.keyPair()!, theirs = sodium.box.keyPair()!
        let dek = DriveFileCrypto.newDEK()
        let sealed = try DriveFileCrypto.seal(dek: dek, toPublicKey: mine.publicKey)
        XCTAssertEqual(try DriveFileCrypto.openDEK(sealed, publicKey: mine.publicKey, secretKey: mine.secretKey), dek)
        XCTAssertThrowsError(try DriveFileCrypto.openDEK(sealed, publicKey: theirs.publicKey, secretKey: theirs.secretKey))
    }

    /// Photos writes large originals in 1 MiB pushes and records the size in the metadata.
    func testAChunkedFileOpensWithItsChunkSize() throws {
        let dek = DriveFileCrypto.newDEK()
        let stream = sodium.secretStream.xchacha20poly1305.initPush(secretKey: dek)!
        let parts = [Bytes(repeating: 1, count: 8), Bytes(repeating: 2, count: 8), Bytes(repeating: 3, count: 5)]
        var data = Data(stream.header())
        for (i, part) in parts.enumerated() {
            data.append(contentsOf: stream.push(message: part, tag: i == parts.count - 1 ? .FINAL : .MESSAGE)!)
        }
        XCTAssertEqual(try DriveFileCrypto.decrypt(data, dek: dek, chunkSize: 8), Data(parts.joined()))
        XCTAssertThrowsError(try DriveFileCrypto.decrypt(data, dek: dek), "read as one push, it fails")
        XCTAssertThrowsError(try DriveFileCrypto.decrypt(data.dropLast(21), dek: dek, chunkSize: 8),
                             "a stream cut short has no FINAL tag")
    }

    func testTamperingIsCaught() throws {
        let dek = DriveFileCrypto.newDEK()
        var sealed = try DriveFileCrypto.encrypt(Data("x".utf8), dek: dek)
        sealed[sealed.count - 1] ^= 0x01
        XCTAssertThrowsError(try DriveFileCrypto.decrypt(sealed, dek: dek))
        XCTAssertThrowsError(try DriveFileCrypto.decrypt(Data([1, 2, 3]), dek: dek))
    }

    /// A single-push file's metadata is exactly the web's `{ mimeType, name }`: no extra field.
    func testMetadataIsTheWebsShape() throws {
        let dek = DriveFileCrypto.newDEK()
        let encoded = try DriveFileCrypto.encryptMetadata(.init(name: "Plan.pdf", mimeType: "application/pdf"), dek: dek)
        let json = try DriveFileCrypto.decrypt(Data(bytes(encoded)), dek: dek)
        XCTAssertEqual(String(decoding: json, as: UTF8.self), #"{"mimeType":"application\/pdf","name":"Plan.pdf"}"#)
        XCTAssertEqual(try DriveFileCrypto.decryptMetadata(encoded, dek: dek).chunkSize, nil)
    }
}
