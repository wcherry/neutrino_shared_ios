import XCTest
@testable import NeutrinoOOXML

// MARK: - DocxForeignDocumentTests

/// A `.docx` written by something that has never heard of Neutrino.
///
/// The requirement here is not fidelity, which is impossible, but that nothing is *lost*: an
/// unrecognised construct degrades to its text instead of vanishing, which is the failure mode that
/// makes a parser worse than no parser.
final class DocxForeignDocumentTests: XCTestCase {

    /// A package in the shape Word writes: no extras part, prefixes and attribute spellings chosen
    /// by somebody else, and a paragraph style this codebase never emits.
    private func foreignDocument() throws -> Data {
        let body = """
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>\
        <w:r><w:t>Foreign Title</w:t></w:r></w:p>\
        <w:p><w:r><w:rPr><w:b/></w:rPr><w:t>body text</w:t></w:r></w:p>\
        <w:p><w:pPr><w:pStyle w:val="IntenseQuote"/></w:pPr>\
        <w:r><w:t>styled oddly</w:t></w:r></w:p>\
        <w:tbl><w:tr>\
        <w:tc><w:p><w:r><w:t>c1</w:t></w:r></w:p></w:tc>\
        <w:tc><w:p><w:r><w:t>c2</w:t></w:r></w:p></w:tc>\
        </w:tr></w:tbl>\
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="7"/></w:numPr></w:pPr>\
        <w:r><w:t>a bullet</w:t></w:r></w:p>\
        <w:sectPr><w:pgSz w:w="15840" w:h="12240" w:orient="landscape"/>\
        <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>
        """
        let document = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<w:document xmlns:w=\"\(OOXMLNamespace.w)\" xmlns:r=\"\(OOXMLNamespace.r)\">"
            + "<w:body>\(body)</w:body></w:document>"

        // Word's own numbering, with the bullet glyph it uses rather than the one we write.
        let numbering = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<w:numbering xmlns:w=\"\(OOXMLNamespace.w)\">"
            + "<w:abstractNum w:abstractNumId=\"3\"><w:lvl w:ilvl=\"0\">"
            + "<w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\u{2022}\"/></w:lvl></w:abstractNum>"
            + "<w:num w:numId=\"7\"><w:abstractNumId w:val=\"3\"/></w:num></w:numbering>"

        var archive = ZipArchive()
        archive.set(OOXMLPackage.contentTypesPart, text: "<Types/>")
        archive.set(OOXMLPackage.documentPart, text: document)
        archive.set(OOXMLPackage.numberingPart, text: numbering)
        return try archive.serialized()
    }

    func testReadsItsStructureWithoutAnExtrasPart() throws {
        let model = try DocxReader.read(try foreignDocument())
        let types = model.doc.children.map(\.type)

        XCTAssertTrue(types.contains("heading"))
        XCTAssertTrue(types.contains("table"))
        XCTAssertTrue(types.contains("bulletList"))
        XCTAssertEqual(model.meta?["pageSetup"]?["orientation"], .string("landscape"))
        XCTAssertEqual(model.meta?["docTheme"], .string("default"))
    }

    func testKeepsTheTextOfAParagraphWhoseStyleItDoesNotKnow() throws {
        let model = try DocxReader.read(try foreignDocument())
        let text = model.doc.plainText

        XCTAssertTrue(text.contains("Foreign Title"))
        XCTAssertTrue(text.contains("styled oddly"))
        XCTAssertTrue(text.contains("c1"))
        XCTAssertTrue(text.contains("c2"))
    }

    func testKeepsRunFormattingAForeignWriterApplied() throws {
        let model = try DocxReader.read(try foreignDocument())
        let body = model.doc.children.first { $0.children.first?.text == "body text" }
        XCTAssertEqual(body?.children.first?.marks, [DocMark(type: "bold")])
    }

    /// Word's bullet glyph is not the one this writer uses, and a list whose glyph is unrecognised
    /// is still a list.
    func testReadsAListWrittenWithWordsOwnNumbering() throws {
        let model = try DocxReader.read(try foreignDocument())
        let list = model.doc.children.first { $0.type == "bulletList" }
        XCTAssertEqual(list?.attr("listStyleType")?.stringValue, "disc")
        XCTAssertEqual(list?.plainText, "a bullet")
    }

    /// A document with no `word/document.xml` is not a Word document, however good a zip it is.
    func testRejectsAZipThatIsNotADocument() throws {
        var archive = ZipArchive()
        archive.set("hello.txt", text: "not a document")
        let bytes = try archive.serialized()

        XCTAssertFalse(DocxCodec.isDocument(bytes))
        XCTAssertThrowsError(try DocxReader.read(bytes)) { error in
            XCTAssertEqual(error as? DocxError, .notADocument)
        }
    }

    /// A Word document that has been edited elsewhere comes back with its extras stale or gone.
    /// The base content is all real OOXML, so it still reads — that is the whole point of not
    /// storing the model in the package.
    func testAPackageWithNoExtrasStillReadsItsImages() throws {
        let model = DocModel(doc: DocNode(type: "doc", content: [
            DocNode(type: "paragraph", attrs: [:], content: [
                DocNode(type: "image", attrs: ["src": .string("neutrino-drive:file-1"),
                                               "width": .string("200")]),
            ]),
        ]), meta: TestMeta.base())
        let bytes = try DocxWriter.write(model, options: DocxWriteOptions(
            title: "RT", images: ["neutrino-drive:file-1": TestMeta.pngBytes]))

        // What another editor does to a package it does not understand: drop the custom part.
        var archive = try ZipArchive(data: bytes)
        archive.remove(DocxMapping.extrasPart)
        let stripped = try DocxReader.read(try archive.serialized())

        let image = stripped.doc.children.first?.children.first
        XCTAssertEqual(image?.type, "image")
        // The Drive reference is gone with the extras, but the picture itself is not: it comes back
        // as the bytes that are actually in the package.
        XCTAssertTrue(image?.attr("src")?.stringValue?.hasPrefix("data:image/png;base64,") ?? false)
    }
}
