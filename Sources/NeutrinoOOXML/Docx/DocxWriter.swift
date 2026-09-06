import Foundation

// MARK: - DocxWriteOptions

/// What the caller supplies that the model itself cannot carry.
public struct DocxWriteOptions {

    /// Document title, which is also what the `TITLE` field resolves to.
    public var title: String

    /// Bytes for each image `src` in the document.
    ///
    /// A `neutrino-drive:` reference must be resolved by the caller — this module cannot reach
    /// Drive, and an unresolved reference is written as a placeholder carrying the whole image node
    /// rather than as a broken picture.
    public var images: [String: Data]

    /// Fixed timestamp for revision marks, so a write is deterministic.
    public var revisionDate: String

    public init(title: String, images: [String: Data] = [:],
                revisionDate: String = "2000-01-01T00:00:00Z") {
        self.title = title
        self.images = images
        self.revisionDate = revisionDate
    }
}

// MARK: - DocxWriter

/// Neutrino's document model → a real `.docx`.
///
/// Everything the editor can hold is written as the OOXML element that means it: page setup as
/// `w:sectPr`, header and footer bands as `word/header*.xml` with `w:titlePg`/`w:evenAndOddHeaders`,
/// footnotes as `word/footnotes.xml`, field codes as `w:fldSimple`, the table of contents as a `TOC`
/// field, cross-references as bookmarks and `REF` fields, tracked changes as `w:ins`/`w:del`,
/// document properties as `docProps/core.xml` and `docProps/custom.xml`. Word does not see an
/// approximation of the document; it sees the document.
///
/// The things OOXML has no way to express — the two embed nodes, Drive image references, the theme
/// name and a few presentational attributes — go into the custom XML part described in
/// ``DocxMapping``.
///
/// Read this together with ``DocxReader``: they are two halves of one mapping, and the round-trip
/// tests assert they agree. A change here with no counterpart there is a change that loses data.
///
/// ## Why the XML is written as text
///
/// Every part has a fixed shape, and a string template says what that shape is far more legibly
/// than a tree of builder calls. Everything that comes from a document goes through
/// ``XMLText/escape(_:)`` on the way in — that is the invariant this file keeps, and the only one a
/// DOM would have kept for it.
public enum DocxWriter {

    // MARK: - Entry point

    /// `model` as `.docx` bytes.
    public static func write(_ model: DocModel, options: DocxWriteOptions) throws -> Data {
        let meta = DocxMeta(model.meta)
        let context = WriteContext(images: options.images, revisionDate: options.revisionDate)

        // The body first: writing it is what discovers the footnotes, bookmarks, numbering
        // definitions, images, hyperlinks and extras every other part below depends on.
        let body = model.doc.children
            .flatMap { blockXML($0, context: context) }
            .joined()

        if let theme = meta.docTheme, theme != "default" { context.extras.theme = theme }
        for layout in context.columnLayouts {
            context.extras.addColumnLayout(columns: layout.columns, blockCount: layout.blockCount)
        }

        var archive = ZipArchive()
        let bands = bandParts(meta: meta, context: context)
        archive.set(OOXMLPackage.documentPart, text: documentPart(body: body, meta: meta, bands: bands,
                                                                  context: context))
        for band in bands { archive.set(band.path, text: band.xml) }
        for image in context.imageParts { archive.set(image.path, data: image.data) }

        archive.set(OOXMLPackage.stylesPart, text: stylesPart())
        archive.set(OOXMLPackage.numberingPart, text: numberingPart(context: context))
        archive.set(OOXMLPackage.settingsPart, text: settingsPart(meta: meta))
        archive.set(OOXMLPackage.footnotesPart, text: footnotesPart(context: context))
        archive.set(OOXMLPackage.documentRelsPart, text: documentRelsPart(bands: bands, context: context))

        archive.set(OOXMLPackage.corePropsPart, text: corePropsPart(title: options.title, meta: meta))
        archive.set(OOXMLPackage.appPropsPart, text: appPropsPart())
        if let custom = customPropsPart(meta: meta) {
            archive.set(OOXMLPackage.customPropsPart, text: custom)
        }

        if let extras = try context.extras.parts() {
            archive.set(DocxMapping.extrasPart, text: extras.item)
            archive.set(DocxMapping.extrasPropsPart, text: extras.props)
            archive.set(OOXMLPackage.relsPart(for: DocxMapping.extrasPart), text: extrasRelsPart())
        }

        archive.set(OOXMLPackage.rootRelsPart, text: rootRelsPart(hasCustomProps: meta.hasCustomProperties))
        archive.set(OOXMLPackage.contentTypesPart,
                    text: contentTypesPart(bands: bands, context: context, meta: meta))
        return try archive.serialized()
    }

    /// Every image `src` the document references, in document order and without duplicates.
    ///
    /// The caller resolves these to bytes before writing — a `neutrino-drive:` reference names a
    /// Drive file, which only the client holding the key can fetch.
    public static func imageSources(in model: DocModel) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func walk(_ node: DocNode) {
            if node.type == "image", let src = node.attr("src")?.stringValue, !src.isEmpty,
               seen.insert(src).inserted {
                out.append(src)
            }
            node.children.forEach(walk)
        }
        walk(model.doc)
        return out
    }
}

// MARK: - WriteContext

/// Everything the body walk accumulates that the rest of the package needs afterwards.
final class WriteContext {

    struct ImagePart {
        let path: String
        let data: Data
        let relID: String
    }

    struct NumberingDefinition {
        let numID: Int
        let ordered: Bool
        let styleType: String
    }

    let images: [String: Data]
    let revisionDate: String

    var extras = DocxExtras()
    var columnLayouts: [(columns: Int, blockCount: Int)] = []
    var footnotes: [(id: Int, text: String)] = []
    var numbering: [NumberingDefinition] = []
    var imageParts: [ImagePart] = []
    var hyperlinks: [(relID: String, target: String)] = []

    private var numberingKeys: [String: Int] = [:]
    private var imageRels: [String: String] = [:]
    private var hyperlinkRels: [String: String] = [:]
    private var bookmarks: [String: String] = [:]
    private var counters: [String: Int] = [:]
    private var nextRelID = 100
    private var nextRevision = 0
    private var nextBookmarkID = 0
    private var nextDrawingID = 0

    init(images: [String: Data], revisionDate: String) {
        self.images = images
        self.revisionDate = revisionDate
    }

    /// The next index for a kind of node, which is how the extras address it — see ``DocxExtras``.
    func nextIndex(_ kind: String) -> Int {
        let index = counters[kind] ?? 0
        counters[kind] = index + 1
        return index
    }

    func nextRevisionID() -> Int {
        nextRevision += 1
        return nextRevision
    }

    func nextBookmark() -> Int {
        nextBookmarkID += 1
        return nextBookmarkID
    }

    func nextDrawing() -> Int {
        nextDrawingID += 1
        return nextDrawingID
    }

    /// A fresh relationship id.
    ///
    /// Numbered from 100 so the parts every package has — styles, numbering, settings, footnotes —
    /// can keep the fixed low ids they are written with without ever colliding with an image, a
    /// hyperlink or a header discovered while walking the body.
    func relationshipID() -> String {
        nextRelID += 1
        return "rId\(nextRelID)"
    }

    /// The bookmark name a heading carries, and the one a reference to it points at. Same name for
    /// the same heading text, which is what makes a `REF` field resolve in Word.
    func bookmark(for headingText: String) -> String {
        let key = headingText.trimmingCharacters(in: .whitespaces).isEmpty
            ? "_top"
            : headingText.trimmingCharacters(in: .whitespaces)
        if let existing = bookmarks[key] { return existing }
        let name = "_Nx\(bookmarks.count)"
        bookmarks[key] = name
        return name
    }

    /// The footnote number for a node's text, assigned in the order the notes are met.
    func footnoteNumber(text: String) -> Int {
        let id = footnotes.count + 1
        footnotes.append((id: id, text: text))
        return id
    }

    /// The numbering definition for a list style, shared by every list that looks the same.
    func numberingID(ordered: Bool, styleType: String) -> Int {
        let key = "\(ordered ? "o" : "b"):\(styleType)"
        if let existing = numberingKeys[key] { return existing }
        let numID = numbering.count + 1
        numberingKeys[key] = numID
        numbering.append(NumberingDefinition(numID: numID, ordered: ordered, styleType: styleType))
        return numID
    }

    /// The relationship id for an image, adding the media part the first time a `src` is seen.
    func imageRelationship(for src: String, data: Data) -> String {
        if let existing = imageRels[src] { return existing }
        let relID = relationshipID()
        let path = "word/media/image\(imageParts.count + 1).\(Self.extension(for: data))"
        imageParts.append(ImagePart(path: path, data: data, relID: relID))
        imageRels[src] = relID
        return relID
    }

    /// The relationship id for an external link, one per distinct target.
    func hyperlinkRelationship(for target: String) -> String {
        if let existing = hyperlinkRels[target] { return existing }
        let relID = relationshipID()
        hyperlinkRels[target] = relID
        hyperlinks.append((relID: relID, target: target))
        return relID
    }

    /// The image format `data` is in, read from its own leading bytes.
    ///
    /// The format decides the extension and content type of the media part, so guessing wrong puts
    /// JPEG bytes in `image1.png`. Word sniffs and renders it anyway; strict consumers do not. The
    /// `src` cannot answer this — a Drive reference has no extension and a data URL's mime type is
    /// whatever the uploader claimed.
    static func `extension`(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(4))
        guard bytes.count >= 3 else { return "png" }
        if bytes[0] == 0xFF && bytes[1] == 0xD8 { return "jpeg" }
        if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 { return "gif" }
        if bytes[0] == 0x42 && bytes[1] == 0x4D { return "bmp" }
        return "png"
    }
}
