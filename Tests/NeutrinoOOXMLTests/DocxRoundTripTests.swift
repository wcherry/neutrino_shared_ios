import XCTest
@testable import NeutrinoOOXML

// MARK: - DocxRoundTripTests

/// Writer and parser agree.
///
/// The property that matters is not "the writer emits a header" or "the parser reads one" — either
/// can be true while the pair still loses data. It is that `read(write(model))` is `model`. This
/// asserts that over each feature on its own, so a failure says which mapping broke, and then over a
/// document carrying one of everything.
///
/// The mirror of `web/apps/web/src/__tests__/ooxml/docxRoundTrip.test.ts`, which asserts the same
/// property over the same mapping in the other language.
final class DocxRoundTripTests: XCTestCase {

    // MARK: - Helpers

    func roundTrip(_ model: DocModel) throws -> DocModel {
        try DocxReader.read(DocxWriter.write(model, options: DocxWriteOptions(title: "RT")))
    }

    /// The body only, for what is not about layout metadata.
    func bodyRoundTrip(_ content: [DocNode]) throws -> [DocNode] {
        try roundTrip(DocModel(doc: DocNode(type: "doc", content: content),
                               meta: TestMeta.base())).doc.children
    }

    /// A paragraph with no attributes has none at all rather than an empty set — which is what the
    /// reader produces, and what the editors build.
    func paragraph(_ content: [DocNode], attrs: [String: DocValue] = [:]) -> DocNode {
        DocNode(type: "paragraph", attrs: attrs.isEmpty ? nil : attrs, content: content)
    }

    func text(_ string: String, _ marks: [DocMark]? = nil) -> DocNode {
        DocNode(type: "text", marks: marks, text: string)
    }

    // MARK: - Marks

    func testToggleMarksSurvive() throws {
        for type in ["bold", "italic", "underline", "strike", "superscript", "subscript", "code"] {
            let marks = [DocMark(type: type)]
            let out = try bodyRoundTrip([paragraph([text("x", marks)])])
            XCTAssertEqual(out.first?.children.first?.marks, marks, type)
        }
    }

    func testColourSizeAndFamilySurvive() throws {
        let marks = [DocMark(type: "textStyle", attrs: ["color": .string("#ff0000"),
                                                        "fontSize": .string("18pt"),
                                                        "fontFamily": .string("Georgia")])]
        let out = try bodyRoundTrip([paragraph([text("x", marks)])])
        XCTAssertEqual(out.first?.children.first?.marks, marks)
    }

    /// OOXML's highlight is a closed sixteen-colour list, so anything else is written as run shading
    /// — and has to come back as a highlight either way.
    func testHighlightOutsideTheEnumerationSurvives() throws {
        let marks = [DocMark(type: "highlight", attrs: ["color": .string("#abcdef")])]
        let out = try bodyRoundTrip([paragraph([text("x", marks)])])
        XCTAssertEqual(out.first?.children.first?.marks, marks)
    }

    func testHighlightInsideTheEnumerationSurvives() throws {
        let marks = [DocMark(type: "highlight", attrs: ["color": .string("#ffff00")])]
        let out = try bodyRoundTrip([paragraph([text("x", marks)])])
        XCTAssertEqual(out.first?.children.first?.marks, marks)
    }

    func testALinkSurvives() throws {
        let marks = [DocMark(type: "link", attrs: ["href": .string("https://example.com/a")])]
        let out = try bodyRoundTrip([paragraph([text("x", marks)])])
        XCTAssertEqual(out.first?.children.first?.marks, marks)
    }

    func testATrackedInsertionKeepsItsAuthor() throws {
        let marks = [DocMark(type: "trackedInsertion", attrs: ["author": .string("Ada")])]
        let out = try bodyRoundTrip([paragraph([text("x", marks)])])
        XCTAssertEqual(out.first?.children.first?.marks, marks)
    }

    /// Link and tracked change are both containers in OOXML rather than run properties —
    /// `w:hyperlink` and `w:del` — so they have to nest rather than one winning.
    func testALinkInsideATrackedDeletionKeepsBoth() throws {
        let marks = [DocMark(type: "link", attrs: ["href": .string("https://example.com/a")]),
                     DocMark(type: "trackedDeletion", attrs: ["author": .string("Grace")])]
        let out = try bodyRoundTrip([paragraph([text("x", marks)])])
        XCTAssertEqual(Set((out.first?.children.first?.marks ?? []).map(\.type)),
                       ["link", "trackedDeletion"])
    }

    // MARK: - Blocks

    func testHeadingsKeepTheirLevel() throws {
        let out = try bodyRoundTrip([DocNode(type: "heading", attrs: ["level": .int(3)],
                                             content: [text("H")])])
        XCTAssertEqual(out.first?.type, "heading")
        XCTAssertEqual(out.first?.attr("level")?.intValue, 3)
    }

    func testAlignmentAndIndentSurvive() throws {
        let out = try bodyRoundTrip([paragraph([text("x")],
                                               attrs: ["textAlign": .string("center"),
                                                       "indent": .int(3)])])
        XCTAssertEqual(out.first?.attr("textAlign")?.stringValue, "center")
        XCTAssertEqual(out.first?.attr("indent")?.intValue, 3)
    }

    func testABulletListKeepsItsGlyphStyle() throws {
        let list = DocNode(type: "bulletList", attrs: ["listStyleType": .string("square")],
                           content: [DocNode(type: "listItem",
                                             content: [paragraph([text("one")])])])
        let out = try bodyRoundTrip([list])
        XCTAssertEqual(out.first?.type, "bulletList")
        XCTAssertEqual(out.first?.attr("listStyleType")?.stringValue, "square")
    }

    func testAnOrderedListKeepsItsNumberingStyle() throws {
        let list = DocNode(type: "orderedList", attrs: ["listStyleType": .string("lower-roman")],
                           content: [DocNode(type: "listItem",
                                             content: [paragraph([text("first")])])])
        let out = try bodyRoundTrip([list])
        XCTAssertEqual(out.first?.type, "orderedList")
        XCTAssertEqual(out.first?.attr("listStyleType")?.stringValue, "lower-roman")
    }

    func testANestedListKeepsItsShape() throws {
        let inner = DocNode(type: "bulletList", attrs: ["listStyleType": .string("disc")],
                            content: [DocNode(type: "listItem", content: [paragraph([text("inner")])])])
        let outer = DocNode(type: "bulletList", attrs: ["listStyleType": .string("disc")],
                            content: [DocNode(type: "listItem",
                                              content: [paragraph([text("outer")]), inner])])
        let out = try bodyRoundTrip([outer])
        let nested = out.first?.children.first?.children.dropFirst().first
        XCTAssertEqual(nested?.type, "bulletList")
        XCTAssertEqual(nested?.plainText, "inner")
    }

    /// A numbered sub-list under a bulleted one. The two get different numbering definitions, so a
    /// parser that ends a list at the first change of `w:numId` unnests this into two sibling lists.
    func testANestedListOfADifferentKindStaysNested() throws {
        let inner = DocNode(type: "orderedList", attrs: ["listStyleType": .string("decimal")],
                            content: [DocNode(type: "listItem", content: [paragraph([text("inner")])])])
        let outer = DocNode(type: "bulletList", attrs: ["listStyleType": .string("disc")],
                            content: [DocNode(type: "listItem",
                                              content: [paragraph([text("outer")]), inner])])
        let out = try bodyRoundTrip([outer])
        XCTAssertEqual(out.count, 1)
        let nested = out.first?.children.first?.children.dropFirst().first
        XCTAssertEqual(nested?.type, "orderedList")
        XCTAssertEqual(nested?.attr("listStyleType")?.stringValue, "decimal")
    }

    func testATableKeepsItsCellShadingAndSpan() throws {
        let cell = DocNode(type: "tableCell",
                           attrs: ["backgroundColor": .string("#ddeeff"), "colspan": .int(2),
                                   "rowspan": .int(1), "colwidth": .null,
                                   "borderColor": .null, "borderWidth": .null],
                           content: [paragraph([text("cell")])])
        let table = DocNode(type: "table",
                            content: [DocNode(type: "tableRow", content: [cell])])
        let out = try bodyRoundTrip([table])
        XCTAssertEqual(out.first?.type, "table")
        XCTAssertEqual(out, [table])
    }

    func testABlockquoteSurvives() throws {
        let quote = DocNode(type: "blockquote", content: [paragraph([text("quoted")])])
        XCTAssertEqual(try bodyRoundTrip([quote]), [quote])
    }

    /// A quote is paragraphs carrying the quote style, so a multi-paragraph one arrives as several
    /// one-paragraph quotes unless they are folded back together.
    func testAMultiParagraphBlockquoteStaysOneBlockquote() throws {
        let quote = DocNode(type: "blockquote", content: [
            paragraph([text("first")], attrs: ["textAlign": .string("right")]),
            paragraph([text("second")]),
        ])
        XCTAssertEqual(try bodyRoundTrip([quote]), [quote])
    }

    func testACodeBlockSurvives() throws {
        let block = DocNode(type: "codeBlock", content: [text("const x = 1;")])
        XCTAssertEqual(try bodyRoundTrip([block]), [block])
    }

    func testASectionBreakSurvives() throws {
        let out = try bodyRoundTrip([paragraph([text("a")]), DocNode(type: "sectionBreak"),
                                     paragraph([text("b")])])
        XCTAssertEqual(out.map(\.type), ["paragraph", "sectionBreak", "paragraph"])
    }

    func testAHorizontalRuleSurvives() throws {
        let out = try bodyRoundTrip([paragraph([text("a")]), DocNode(type: "horizontalRule")])
        XCTAssertEqual(out.map(\.type), ["paragraph", "horizontalRule"])
    }

    func testATableOfContentsSurvives() throws {
        let out = try bodyRoundTrip([DocNode(type: "tableOfContents")])
        XCTAssertTrue(out.contains { $0.type == "tableOfContents" })
    }

    func testAColumnLayoutKeepsItsCountAndChildren() throws {
        let layout = DocNode(type: "columnLayout", attrs: ["columns": .int(3)],
                             content: [paragraph([text("a")]), paragraph([text("b")])])
        XCTAssertEqual(try bodyRoundTrip([layout]), [layout])
    }

    func testAHardBreakSurvives() throws {
        let out = try bodyRoundTrip([paragraph([text("a"), DocNode(type: "hardBreak"), text("b")])])
        XCTAssertEqual(out.first?.children.map(\.type), ["text", "hardBreak", "text"])
    }

    // MARK: - Nodes with no OOXML equivalent

    func testAFootnoteKeepsItsText() throws {
        let note = DocNode(type: "footnote", attrs: ["id": .string("fn-1"),
                                                     "text": .string("The note.")])
        let out = try bodyRoundTrip([paragraph([text("x"), note])])
        XCTAssertEqual(out.first?.children.last?.attr("text")?.stringValue, "The note.")
    }

    func testACrossReferenceKeepsItsTargetAndText() throws {
        let out = try bodyRoundTrip([
            DocNode(type: "heading", attrs: ["level": .int(1)], content: [text("Chapter One")]),
            paragraph([text("see it", [DocMark(type: "crossRef",
                                               attrs: ["headingText": .string("Chapter One")])])]),
        ])
        let reference = out.last?.children.first
        XCTAssertEqual(reference?.text, "see it")
        XCTAssertEqual(reference?.marks?.first,
                       DocMark(type: "crossRef", attrs: ["headingText": .string("Chapter One")]))
    }

    func testAFieldCodeStaysAField() throws {
        let field = DocNode(type: "docField", attrs: ["code": .string("page"), "arg": .null,
                                                      "showCode": .bool(false)])
        let out = try bodyRoundTrip([paragraph([field])])
        XCTAssertEqual(out.first?.children.first, field)
    }

    func testACustomFieldKeepsItsArgument() throws {
        let field = DocNode(type: "docField", attrs: ["code": .string("custom"),
                                                      "arg": .string("client"),
                                                      "showCode": .bool(true)])
        let out = try bodyRoundTrip([paragraph([field])])
        XCTAssertEqual(out.first?.children.first, field)
    }

    /// A resolved Drive reference is written as a real picture and comes back as the reference — not
    /// as the multi-megabyte data URL the bytes would inline to.
    func testAResolvedDriveImageComesBackAsAReference() throws {
        let image = DocNode(type: "image", attrs: ["src": .string("neutrino-drive:file-7"),
                                                   "width": .string("320"),
                                                   "shadow": .string("md"),
                                                   "caption": .string("Fig 1")])
        let model = DocModel(doc: DocNode(type: "doc", content: [paragraph([image])]),
                             meta: TestMeta.base())
        let bytes = try DocxWriter.write(model, options: DocxWriteOptions(
            title: "RT", images: ["neutrino-drive:file-7": TestMeta.pngBytes]))
        let out = try DocxReader.read(bytes)

        XCTAssertEqual(out.doc.children.first?.children.first, image)
        // The picture really is in the package, not a placeholder standing in for one.
        let archive = try ZipArchive(data: bytes)
        XCTAssertTrue(archive.contains("word/media/image1.png"))
    }

    /// Alt text is a real OOXML property, so it survives on a picture that was embedded — including
    /// one described in Word, which is where most alt text in a document comes from.
    func testAnEmbeddedPictureKeepsItsAltText() throws {
        let image = DocNode(type: "image", attrs: ["src": .string("neutrino-drive:file-7"),
                                                   "width": .string("320"),
                                                   "alt": .string("A cat on a wall")])
        let model = DocModel(doc: DocNode(type: "doc", content: [paragraph([image])]),
                             meta: TestMeta.base())
        let bytes = try DocxWriter.write(model, options: DocxWriteOptions(
            title: "RT", images: ["neutrino-drive:file-7": TestMeta.pngBytes]))

        XCTAssertEqual(try DocxReader.read(bytes).doc.children.first?.children.first, image)
    }

    /// An image the caller could not resolve — a save made offline — is written as a placeholder
    /// carrying the whole node, so nothing is lost and the next save with bytes in hand embeds it.
    func testAnUnresolvedDriveImageStillComesBackAsAnImage() throws {
        let image = DocNode(type: "image", attrs: ["src": .string("neutrino-drive:file-7"),
                                                   "width": .string("320")])
        let out = try bodyRoundTrip([paragraph([image])])
        XCTAssertEqual(out.first?.children.first, image)
    }

    func testASheetEmbedKeepsItsAttributes() throws {
        let embed = DocNode(type: "sheetEmbed", attrs: ["spreadsheetId": .string("s1"),
                                                        "sheetId": .string("sh1"),
                                                        "title": .string("Q1"),
                                                        "cachedData": .null])
        let out = try bodyRoundTrip([paragraph([text("before")]), embed])
        XCTAssertEqual(out.last, embed)
    }

    func testADiagramEmbedKeepsItsAttributes() throws {
        let embed = DocNode(type: "diagramEmbed", attrs: ["diagramId": .string("d1"),
                                                          "title": .string("Flow"),
                                                          "cachedSvg": .null])
        let out = try bodyRoundTrip([embed, paragraph([text("after")])])
        XCTAssertEqual(out.first, embed)
    }

    /// A placeholder is written as italic text, and so is the italic text a user typed next to it —
    /// which would make them one run in the package and lose every placeholder from there on. The
    /// placeholder character style is what keeps the two runs apart.
    func testAPlaceholderBesideItalicTextIsStillFound() throws {
        let image = DocNode(type: "image", attrs: ["src": .string("neutrino-drive:file-1"),
                                                   "width": .string("200")])
        let embed = DocNode(type: "sheetEmbed", attrs: ["spreadsheetId": .string("s9"),
                                                        "title": .string("Later")])
        let italic = text("about that", [DocMark(type: "italic")])
        let out = try bodyRoundTrip([paragraph([image, italic]), embed])

        XCTAssertEqual(out.first?.children.first, image)
        XCTAssertEqual(out.first?.children.last, italic)
        XCTAssertEqual(out.last, embed)
    }

    // MARK: - Layout metadata

    func testPageSetupSurvives() throws {
        let pageSetup: [String: DocValue] = ["pageSize": .string("a4"),
                                             "orientation": .string("landscape"),
                                             "marginTop": .int(90), "marginBottom": .int(54),
                                             "marginLeft": .int(108), "marginRight": .int(36)]
        let out = try roundTrip(DocModel(doc: DocNode(type: "doc", content: [paragraph([text("x")])]),
                                         meta: TestMeta.base(pageSetup: pageSetup)))
        XCTAssertEqual(out.meta?["pageSetup"], .object(pageSetup))
    }

    func testHeaderAndFooterSlotsSurviveWithFieldsLeftAsFields() throws {
        let meta = TestMeta.base(variants: [
            "default": TestMeta.band(header: ["Acme", "Report", "{{date}}"],
                                     footer: ["", "Page {{page}} of {{pages}}", "v2"]),
        ])
        let out = try roundTrip(DocModel(doc: DocNode(type: "doc", content: [paragraph([text("x")])]),
                                         meta: meta))
        let variants = out.meta?["headerFooter"]?["variants"]
        XCTAssertEqual(variants?["default"]?["header"],
                       TestMeta.slots(["Acme", "Report", "{{date}}"]))
        XCTAssertEqual(variants?["default"]?["footer"],
                       TestMeta.slots(["", "Page {{page}} of {{pages}}", "v2"]))
    }

    func testADifferentFirstPageSurvives() throws {
        let meta = TestMeta.base(differentFirstPage: true, variants: [
            "first": TestMeta.band(header: ["First", "", ""], footer: ["", "", ""]),
        ])
        let out = try roundTrip(DocModel(doc: DocNode(type: "doc", content: [paragraph([text("x")])]),
                                         meta: meta))
        XCTAssertEqual(out.meta?["headerFooter"]?["differentFirstPage"], .bool(true))
        XCTAssertEqual(out.meta?["headerFooter"]?["variants"]?["first"]?["header"]?["left"],
                       .string("First"))
    }

    func testDifferentOddAndEvenPagesSurvive() throws {
        let meta = TestMeta.base(differentEvenOdd: true, variants: [
            "even": TestMeta.band(header: ["Even", "", ""], footer: ["", "", ""]),
        ])
        let out = try roundTrip(DocModel(doc: DocNode(type: "doc", content: [paragraph([text("x")])]),
                                         meta: meta))
        XCTAssertEqual(out.meta?["headerFooter"]?["differentEvenOdd"], .bool(true))
        XCTAssertEqual(out.meta?["headerFooter"]?["variants"]?["even"]?["header"]?["left"],
                       .string("Even"))
    }

    func testHeaderAndFooterMarginsSurvive() throws {
        let meta = TestMeta.base(headerMargin: 54, footerMargin: 27, variants: [
            "default": TestMeta.band(header: ["x", "", ""], footer: ["", "", ""]),
        ])
        let out = try roundTrip(DocModel(doc: DocNode(type: "doc", content: [paragraph([text("x")])]),
                                         meta: meta))
        XCTAssertEqual(out.meta?["headerFooter"]?["headerMargin"], .int(54))
        XCTAssertEqual(out.meta?["headerFooter"]?["footerMargin"], .int(27))
    }

    func testAWatermarkSurvives() throws {
        let out = try roundTrip(DocModel(doc: DocNode(type: "doc", content: [paragraph([text("x")])]),
                                         meta: TestMeta.base(watermark: "CONFIDENTIAL")))
        XCTAssertEqual(out.meta?["watermarkText"], .string("CONFIDENTIAL"))
    }

    func testBackgroundColourSurvives() throws {
        let out = try roundTrip(DocModel(doc: DocNode(type: "doc", content: [paragraph([text("x")])]),
                                         meta: TestMeta.base(bgColor: "#fafafa")))
        XCTAssertEqual(out.meta?["bgColor"], .string("#fafafa"))
    }

    func testTheThemeNameSurvives() throws {
        let out = try roundTrip(DocModel(doc: DocNode(type: "doc", content: [paragraph([text("x")])]),
                                         meta: TestMeta.base(theme: "serif")))
        XCTAssertEqual(out.meta?["docTheme"], .string("serif"))
    }

    func testDocumentPropertiesSurvive() throws {
        let properties: [String: DocValue] = ["author": .string("Ada"), "subject": .string("Engines"),
                                              "company": .string(""), "category": .string("Notes"),
                                              "keywords": .string("a,b"), "manager": .string(""),
                                              "custom": .object([:])]
        let out = try roundTrip(DocModel(doc: DocNode(type: "doc", content: [paragraph([text("x")])]),
                                         meta: TestMeta.base(properties: properties)))
        XCTAssertEqual(out.meta?["properties"], .object(properties))
    }

    /// `docProps/core.xml` has nowhere to put a company, a manager or anything user-defined, so
    /// these go to `docProps/custom.xml` — which is also where a `DOCPROPERTY` field looks.
    func testCompanyManagerAndUserDefinedPropertiesSurvive() throws {
        let properties: [String: DocValue] = ["author": .string(""), "subject": .string(""),
                                              "company": .string("Acme"), "category": .string(""),
                                              "keywords": .string(""), "manager": .string("Grace"),
                                              "custom": .object(["client": .string("Initech"),
                                                                 "ref": .string("R-42")])]
        let out = try roundTrip(DocModel(doc: DocNode(type: "doc", content: [paragraph([text("x")])]),
                                         meta: TestMeta.base(properties: properties)))
        XCTAssertEqual(out.meta?["properties"], .object(properties))
    }

    /// A document with no author must not acquire one: a reader that finds no `dc:creator` is free
    /// to invent something, and then every document created here has an author nobody set.
    func testADocumentWithNoAuthorDoesNotAcquireOne() throws {
        let out = try roundTrip(DocModel(doc: DocNode(type: "doc", content: [paragraph([text("x")])]),
                                         meta: TestMeta.base()))
        XCTAssertEqual(out.meta?["properties"]?["author"], .string(""))
    }

    // MARK: - The whole thing at once

    /// Per-feature tests can all pass while the pair still loses data — a mapping that only works
    /// when its feature is alone is not a mapping. This is `read(write(m)) == m` in full.
    func testADocumentWithOneOfEverythingComesBackEqual() throws {
        let meta = TestMeta.base(
            watermark: "DRAFT",
            bgColor: "#fdfdfd",
            theme: "serif",
            properties: ["author": .string("Ada"), "subject": .string("Engines"),
                         "company": .string(""), "category": .string("Notes"),
                         "keywords": .string("a,b"), "manager": .string(""),
                         "custom": .object([:])],
            pageSetup: ["pageSize": .string("a4"), "orientation": .string("landscape"),
                        "marginTop": .int(90), "marginBottom": .int(54),
                        "marginLeft": .int(108), "marginRight": .int(36)],
            differentFirstPage: true,
            variants: [
                "default": TestMeta.band(header: ["Acme", "Report", "{{date}}"],
                                         footer: ["", "Page {{page}} of {{pages}}", "v2"]),
                "first": TestMeta.band(header: ["Cover", "", ""], footer: ["", "", ""]),
            ],
            headerText: "Report",
            footerText: "Page {{page}} of {{pages}}",
            showPageNumbers: true)

        let content: [DocNode] = [
            DocNode(type: "heading", attrs: ["level": .int(1)], content: [text("Chapter One")]),
            paragraph([
                text("plain "),
                text("bold", [DocMark(type: "bold")]),
                text(" and "),
                text("coloured", [DocMark(type: "textStyle",
                                          attrs: ["color": .string("#ff0000"),
                                                  "fontSize": .string("18pt"),
                                                  "fontFamily": .string("Georgia")])]),
                DocNode(type: "footnote", attrs: ["id": .string("fn-1"),
                                                  "text": .string("A note.")]),
            ], attrs: ["textAlign": .string("center"), "indent": .int(2)]),
            DocNode(type: "bulletList", attrs: ["listStyleType": .string("square")], content: [
                DocNode(type: "listItem", content: [paragraph([text("one")])]),
                DocNode(type: "listItem", content: [paragraph([text("two")])]),
            ]),
            DocNode(type: "orderedList", attrs: ["listStyleType": .string("upper-roman")], content: [
                DocNode(type: "listItem", content: [paragraph([text("first")])]),
            ]),
            DocNode(type: "blockquote", content: [paragraph([text("quoted")])]),
            DocNode(type: "codeBlock", content: [text("const x = 1;")]),
            DocNode(type: "table", content: [DocNode(type: "tableRow", content: [
                DocNode(type: "tableCell",
                        attrs: ["colspan": .int(1), "rowspan": .int(1), "colwidth": .null,
                                "backgroundColor": .string("#ddeeff"), "borderColor": .null,
                                "borderWidth": .null],
                        content: [paragraph([text("cell")])]),
            ])]),
            DocNode(type: "tableOfContents"),
            DocNode(type: "sectionBreak"),
            paragraph([
                text("see it", [DocMark(type: "crossRef",
                                        attrs: ["headingText": .string("Chapter One")])]),
                DocNode(type: "docField", attrs: ["code": .string("page"), "arg": .null,
                                                  "showCode": .bool(false)]),
            ]),
            DocNode(type: "sheetEmbed", attrs: ["spreadsheetId": .string("s1"),
                                                "title": .string("Q1")]),
        ]

        let out = try roundTrip(DocModel(doc: DocNode(type: "doc", content: content), meta: meta))
        XCTAssertEqual(out.doc.children, content)
        XCTAssertEqual(out.meta, meta)
    }

    // MARK: - The stored envelope

    func testTheJSONBoundaryRoundTripsToo() throws {
        let json = try DocModel(doc: DocNode(type: "doc", content: [paragraph([text("hello")])]),
                                meta: TestMeta.base()).toJSON()
        let bytes = try DocxCodec.encodeJSON(json, title: "Report")
        XCTAssertEqual(try DocxCodec.decodeToJSON(bytes), json)
    }

    /// Two encodes of the same document must produce the same bytes: the offline cache decides
    /// whether a document changed by comparing what it encoded.
    func testEncodingIsDeterministic() throws {
        let model = DocModel(doc: DocNode(type: "doc", content: [paragraph([text("hello")])]),
                             meta: TestMeta.base())
        XCTAssertEqual(try DocxCodec.encode(model, title: "R"),
                       try DocxCodec.encode(model, title: "R"))
    }

    func testAnEmptyDocumentIsAValidPackage() throws {
        let bytes = try DocxCodec.emptyDocument(title: "Untitled document")
        XCTAssertTrue(DocxCodec.isDocument(bytes))
        XCTAssertEqual(try DocxCodec.decode(bytes).doc.children, [])
    }

    func testImageSourcesAreReportedInOrderWithoutDuplicates() throws {
        let model = DocModel(doc: DocNode(type: "doc", content: [
            paragraph([DocNode(type: "image", attrs: ["src": .string("neutrino-drive:a")])]),
            paragraph([DocNode(type: "image", attrs: ["src": .string("neutrino-drive:b")]),
                       DocNode(type: "image", attrs: ["src": .string("neutrino-drive:a")])]),
        ]))
        XCTAssertEqual(DocxCodec.imageSources(in: model), ["neutrino-drive:a", "neutrino-drive:b"])
    }
}
