import XCTest
@testable import NeutrinoOOXML

// MARK: - ZipArchiveTests

/// The container half of the format: a `.docx` Word refuses to open is not a document, however good
/// the XML inside it is.
final class ZipArchiveTests: XCTestCase {

    func testRoundTripsPartsInOrder() throws {
        var archive = ZipArchive()
        archive.set("[Content_Types].xml", text: "<Types/>")
        archive.set("word/document.xml", text: "<w:document>hello</w:document>")
        archive.set("word/media/image1.png", data: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]))

        let reopened = try ZipArchive(data: try archive.serialized())

        XCTAssertEqual(reopened.names,
                       ["[Content_Types].xml", "word/document.xml", "word/media/image1.png"])
        XCTAssertEqual(reopened.text(for: "word/document.xml"), "<w:document>hello</w:document>")
        XCTAssertEqual(reopened.data(for: "word/media/image1.png"),
                       Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]))
    }

    /// Big, compressible content is the case deflate exists for, and the case a wrong CRC or size
    /// field shows up in.
    func testRoundTripsCompressibleContent() throws {
        let text = String(repeating: "<w:p><w:r><w:t>paragraph</w:t></w:r></w:p>", count: 500)
        var archive = ZipArchive()
        archive.set("word/document.xml", text: text)

        let bytes = try archive.serialized()
        XCTAssertLessThan(bytes.count, text.utf8.count / 4, "compressible content should deflate")
        XCTAssertEqual(try ZipArchive(data: bytes).text(for: "word/document.xml"), text)
    }

    /// Random bytes cannot be deflated smaller; the writer stores those instead, and the reader has
    /// to handle both methods.
    func testRoundTripsIncompressibleContent() throws {
        let random = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        var archive = ZipArchive()
        archive.set("word/media/image1.jpeg", data: random)

        XCTAssertEqual(try ZipArchive(data: try archive.serialized())
            .data(for: "word/media/image1.jpeg"), random)
    }

    /// The offline cache compares stored ciphertext to decide whether a document changed, so an
    /// archive that embedded the current time would make every no-op save look like an edit.
    func testTwoWritesOfTheSamePartsAreIdentical() throws {
        var archive = ZipArchive()
        archive.set("word/document.xml", text: "<w:document/>")
        archive.set("word/styles.xml", text: "<w:styles/>")

        XCTAssertEqual(try archive.serialized(), try archive.serialized())
    }

    func testContentTypesIsWrittenFirstWhateverOrderItWasAddedIn() throws {
        var archive = ZipArchive()
        archive.set("word/document.xml", text: "<w:document/>")
        archive.set("[Content_Types].xml", text: "<Types/>")

        XCTAssertEqual(try ZipArchive(data: try archive.serialized()).names.first,
                       "[Content_Types].xml")
    }

    func testReplacingAPartKeepsItsPosition() throws {
        var archive = ZipArchive()
        archive.set("a.xml", text: "<a/>")
        archive.set("b.xml", text: "<b/>")
        archive.set("a.xml", text: "<a2/>")

        XCTAssertEqual(archive.names, ["a.xml", "b.xml"])
        XCTAssertEqual(archive.text(for: "a.xml"), "<a2/>")
    }

    func testRejectsBytesThatAreNotAnArchive() {
        XCTAssertThrowsError(try ZipArchive(data: Data("not a zip".utf8))) { error in
            XCTAssertEqual(error as? ZipError, .notAnArchive)
        }
        XCTAssertFalse(ZipArchive.looksLikeArchive(Data("not a zip".utf8)))
    }

    func testRecognisesAnArchiveByItsHeader() throws {
        var archive = ZipArchive()
        archive.set("word/document.xml", text: "<w:document/>")
        XCTAssertTrue(ZipArchive.looksLikeArchive(try archive.serialized()))
    }
}
