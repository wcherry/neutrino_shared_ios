import Foundation

// MARK: - DocxReader

/// A `.docx` → Neutrino's document model.
///
/// The other half of ``DocxWriter``. It reads the parts directly: `document.xml` for the body,
/// `numbering.xml` for what a list looks like, `footnotes.xml` for the notes, the header and footer
/// parts named by `sectPr`, `docProps/*` for the document properties, and the custom XML part for
/// the handful of things OOXML cannot say (see ``DocxMapping``).
///
/// Anything it does not recognise degrades to its text rather than vanishing. A `.docx` from Word is
/// a document written by software that knows constructs this does not, and losing a paragraph is
/// much worse than losing its styling.
///
/// ## Known gap: `styles.xml` is not resolved
///
/// A paragraph's style is read as an id — `Heading2` is a heading because it is spelled that way.
/// That covers what the writer emits and what Word emits in English, and misses two real cases: a
/// document whose heading styles are named in another language, and one using a custom style that is
/// `basedOn` a heading. Both read as body paragraphs with their text intact. The web reader has the
/// same gap, deliberately, so the two stay in step.
public enum DocxReader {

    // MARK: - Entry point

    /// `data` as the document model.
    ///
    /// Never throws for a document it only partly understands: an unreadable part yields its default
    /// rather than aborting the read, because the alternative — refusing to open a document because
    /// its `numbering.xml` is unusual — is worse than opening it with plain bullets.
    public static func read(_ data: Data) throws -> DocModel {
        let archive = try ZipArchive(data: data)
        guard let documentXML = archive.text(for: OOXMLPackage.documentPart),
              let document = XMLElement.parse(documentXML) else {
            throw DocxError.notADocument
        }

        let rels = relationships(in: archive, for: OOXMLPackage.documentPart)
        let context = ReadContext(
            numbering: numbering(in: archive),
            footnotes: footnotes(in: archive),
            extras: DocxExtras.read(from: archive),
            rels: rels,
            media: media(in: archive, rels: rels)
        )

        let body = document.element("body")
        var content = body.map { blocks(in: $0, context: context) } ?? []
        let sectPr = body?.element("sectPr")

        let bands = self.bands(in: archive, sectPr: sectPr, rels: rels)
        let background = DocxMapping.ooxmlToHex(document.element("background")?.attribute("color",
                                                                                          uri: OOXMLNamespace.w))

        // Placeholders last: these are nodes the writer had to replace with text, and they are
        // matched back by position.
        var cursor = 0
        restorePlaceholders(&content, extras: context.extras, cursor: &cursor)

        let meta = metaValue(bands: bands, background: background, extras: context.extras,
                             properties: properties(in: archive), pageSetup: pageSetup(sectPr))
        return DocModel(doc: DocNode(type: "doc", content: content), meta: meta)
    }

    /// Whether `data` could be a `.docx` at all — a zip that holds a `word/document.xml`.
    public static func isDocument(_ data: Data) -> Bool {
        guard ZipArchive.looksLikeArchive(data), let archive = try? ZipArchive(data: data) else {
            return false
        }
        return archive.contains(OOXMLPackage.documentPart)
    }
}

// MARK: - DocxError

public enum DocxError: Error, Equatable {
    /// The bytes are a zip, but not a Word document — no `word/document.xml`.
    case notADocument
}

// MARK: - ReadContext

/// What the body walk needs from the rest of the package.
final class ReadContext {

    struct ListStyle {
        let ordered: Bool
        let styleType: String
    }

    let numbering: [String: ListStyle]
    let footnotes: [String: String]
    let extras: DocxExtras
    let rels: [String: String]
    /// Relationship id → the `data:` URL its media part decodes to.
    let media: [String: String]

    private var counters: [String: Int] = [:]

    init(numbering: [String: ListStyle], footnotes: [String: String], extras: DocxExtras,
         rels: [String: String], media: [String: String]) {
        self.numbering = numbering
        self.footnotes = footnotes
        self.extras = extras
        self.rels = rels
        self.media = media
    }

    func nextIndex(_ kind: String) -> Int {
        let index = counters[kind] ?? 0
        counters[kind] = index + 1
        return index
    }
}

// MARK: - Package parts

extension DocxReader {

    /// A part's relationships, id → target.
    static func relationships(in archive: ZipArchive, for part: String) -> [String: String] {
        guard let xml = archive.text(for: OOXMLPackage.relsPart(for: part)),
              let root = XMLElement.parse(xml) else { return [:] }
        var out: [String: String] = [:]
        for relationship in root.elements("Relationship") {
            guard let id = relationship.attribute("Id"),
                  let target = relationship.attribute("Target") else { continue }
            out[id] = target
        }
        return out
    }

    /// Every image the document relates to, decoded to a `data:` URL keyed by relationship id.
    ///
    /// Inline rather than left in the package: the model stores an image as a `src`, and a caller
    /// that has already dropped the package has no way to resolve a part path.
    static func media(in archive: ZipArchive, rels: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (id, target) in rels {
            let path = OOXMLPackage.resolve(target: target, from: "word")
            guard path.hasPrefix("word/media/"), let data = archive.data(for: path) else { continue }
            out[id] = dataURL(path: path, data: data)
        }
        return out
    }

    private static func dataURL(path: String, data: Data) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png":         mime = "image/png"
        case "gif":         mime = "image/gif"
        case "svg":         mime = "image/svg+xml"
        case "bmp":         mime = "image/bmp"
        default:            mime = "image/jpeg"
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// `numId` → what the list looks like.
    ///
    /// Two hops, because a `w:num` is an instance of a `w:abstractNum` and it is the abstract
    /// definition that holds the format. Only level 0 is read: the editor's model has one style per
    /// list, and Word's nine levels collapse into it.
    static func numbering(in archive: ZipArchive) -> [String: ReadContext.ListStyle] {
        guard let xml = archive.text(for: OOXMLPackage.numberingPart),
              let root = XMLElement.parse(xml) else { return [:] }

        var abstract: [String: ReadContext.ListStyle] = [:]
        for definition in root.elements("abstractNum") {
            guard let id = definition.attribute("abstractNumId", uri: OOXMLNamespace.w) else { continue }
            let levels = definition.elements("lvl")
            let level = levels.first { $0.attribute("ilvl", uri: OOXMLNamespace.w) == "0" } ?? levels.first
            guard let level else { continue }
            let format = level.element("numFmt")?.val ?? "decimal"
            if format == "bullet" {
                let glyph = level.element("lvlText")?.val ?? "\u{25CF}"
                abstract[id] = ReadContext.ListStyle(
                    ordered: false, styleType: DocxMapping.glyphToBullet[glyph] ?? "disc")
            } else {
                abstract[id] = ReadContext.ListStyle(
                    ordered: true, styleType: DocxMapping.numFmtToOrderedStyle[format] ?? "decimal")
            }
        }

        var out: [String: ReadContext.ListStyle] = [:]
        for num in root.elements("num") {
            guard let numID = num.attribute("numId", uri: OOXMLNamespace.w),
                  let abstractID = num.element("abstractNumId")?.val,
                  let style = abstract[abstractID] else { continue }
            out[numID] = style
        }
        return out
    }

    static func footnotes(in archive: ZipArchive) -> [String: String] {
        guard let xml = archive.text(for: OOXMLPackage.footnotesPart),
              let root = XMLElement.parse(xml) else { return [:] }
        var out: [String: String] = [:]
        for note in root.elements("footnote") {
            guard let id = note.attribute("id", uri: OOXMLNamespace.w), (Int(id) ?? 0) >= 1 else {
                // Word reserves ids 0 and -1 for the separator marks; they are not notes.
                continue
            }
            out[id] = note.elements("p").map(paragraphText).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    /// A paragraph's text, tabs included and everything else ignored.
    private static func paragraphText(_ paragraph: XMLElement) -> String {
        var text = ""
        func walk(_ element: XMLElement) {
            for child in element.children {
                switch child.localName {
                case "t", "delText": text += child.textContent
                case "tab":          text += "\t"
                default:             walk(child)
                }
            }
        }
        walk(paragraph)
        return text
    }

    static func properties(in archive: ZipArchive) -> [String: DocValue] {
        var author = "", subject = "", keywords = "", category = ""
        var company = "", manager = ""
        var custom: [String: DocValue] = [:]

        if let xml = archive.text(for: OOXMLPackage.corePropsPart),
           let root = XMLElement.parse(xml) {
            author = root.descendant("creator")?.textContent ?? ""
            subject = root.descendant("subject")?.textContent ?? ""
            keywords = root.descendant("keywords")?.textContent ?? ""
            category = root.descendant("description")?.textContent ?? ""
        }
        if let xml = archive.text(for: OOXMLPackage.customPropsPart),
           let root = XMLElement.parse(xml) {
            for property in root.elements("property") {
                guard let name = property.attribute("name") else { continue }
                let value = property.children.first?.textContent ?? ""
                if name == "company" { company = value }
                else if name == "manager" { manager = value }
                else { custom[name] = .string(value) }
            }
        }

        return [
            "author": .string(author), "subject": .string(subject), "company": .string(company),
            "category": .string(category), "keywords": .string(keywords), "manager": .string(manager),
            "custom": .object(custom),
        ]
    }
}

// MARK: - Section properties, headers and footers

extension DocxReader {

    struct Bands {
        var differentFirstPage = false
        var differentEvenOdd = false
        var headerMargin: Double = 36
        var footerMargin: Double = 36
        var variants: [String: (header: DocxMeta.Slots, footer: DocxMeta.Slots)] = [:]
        var watermark = ""
    }

    static func pageSetup(_ sectPr: XMLElement?) -> [String: DocValue] {
        guard let sectPr else { return DocxMapping.defaultPageSetup }
        let size = sectPr.element("pgSz")
        let margins = sectPr.element("pgMar")

        let width = Int(size?.attribute("w", uri: OOXMLNamespace.w) ?? "") ?? 0
        let height = Int(size?.attribute("h", uri: OOXMLNamespace.w) ?? "") ?? 0
        let orientAttribute = size?.attribute("orient", uri: OOXMLNamespace.w)
        let landscape = orientAttribute == "landscape" || (orientAttribute == nil && width > height)

        func margin(_ name: String, _ fallback: Double) -> DocValue {
            guard let raw = margins?.attribute(name, uri: OOXMLNamespace.w), let twips = Double(raw) else {
                return .double(fallback)
            }
            let points = DocxMapping.twipToPt(twips)
            // Whole points re-encode as integers, so a document that has not been through Word
            // compares equal to the one that produced it.
            return points == points.rounded() ? .int(Int(points)) : .double(points)
        }

        return [
            "pageSize": .string(DocxMapping.pageSize(fromTwips: width, height) ?? "letter"),
            "orientation": .string(landscape ? "landscape" : "portrait"),
            "marginTop": margin("top", 72),
            "marginBottom": margin("bottom", 72),
            "marginLeft": margin("left", 72),
            "marginRight": margin("right", 72),
        ]
    }

    /// The header and footer parts a section points at, read back into slots.
    static func bands(in archive: ZipArchive, sectPr: XMLElement?, rels: [String: String]) -> Bands {
        var bands = Bands()
        guard let sectPr else { return bands }

        bands.differentFirstPage = sectPr.element("titlePg")?.isToggleOn ?? false
        if let margins = sectPr.element("pgMar") {
            if let header = margins.attribute("header", uri: OOXMLNamespace.w).flatMap(Double.init) {
                bands.headerMargin = DocxMapping.twipToPt(header)
            }
            if let footer = margins.attribute("footer", uri: OOXMLNamespace.w).flatMap(Double.init) {
                bands.footerMargin = DocxMapping.twipToPt(footer)
            }
        }
        if let xml = archive.text(for: OOXMLPackage.settingsPart), let root = XMLElement.parse(xml) {
            bands.differentEvenOdd = root.element("evenAndOddHeaders")?.isToggleOn ?? false
        }

        for kind in ["header", "footer"] {
            for reference in sectPr.elements("\(kind)Reference") {
                let variant = reference.attribute("type", uri: OOXMLNamespace.w) ?? "default"
                guard let relID = reference.attribute("id", uri: OOXMLNamespace.r),
                      let target = rels[relID],
                      let xml = archive.text(for: OOXMLPackage.resolve(target: target, from: "word")),
                      let root = XMLElement.parse(xml) else { continue }

                var pair = bands.variants[variant] ?? (header: DocxMeta.Slots(), footer: DocxMeta.Slots())
                if kind == "header" {
                    pair.header = slots(in: root)
                    if bands.watermark.isEmpty {
                        bands.watermark = root.descendant("textpath")?.attribute("string") ?? ""
                    }
                } else {
                    pair.footer = slots(in: root)
                }
                bands.variants[variant] = pair
            }
        }
        return bands
    }

    /// A header or footer part back into three slots.
    ///
    /// The band was written as one paragraph with a centre and a right tab stop, so splitting on
    /// tabs is what recovers the slots. A field goes back to the `{{token}}` the editor writes it as.
    private static func slots(in root: XMLElement) -> DocxMeta.Slots {
        // The watermark, when there is one, is a paragraph of its own before the band — so the band
        // is the first paragraph that is not it.
        guard let paragraph = root.elements("p").first(where: { $0.descendant("pict") == nil })
                ?? root.elements("p").first else {
            return DocxMeta.Slots()
        }

        var parts = [""]
        for element in paragraph.children {
            if element.localName == "fldSimple" {
                let instruction = (element.attribute("instr", uri: OOXMLNamespace.w) ?? "")
                    .trimmingCharacters(in: .whitespaces)
                if let code = fieldCode(instruction) { parts[parts.count - 1] += "{{\(code)}}" }
                continue
            }
            guard element.localName == "r" else { continue }
            for child in element.children {
                if child.localName == "tab" { parts.append("") }
                else if child.localName == "t" { parts[parts.count - 1] += child.textContent }
            }
        }

        return DocxMeta.Slots(left: parts.count > 0 ? parts[0] : "",
                              center: parts.count > 1 ? parts[1] : "",
                              right: parts.count > 2 ? parts[2] : "")
    }

    /// The `{{token}}` a field instruction came from, or nil when it is one nothing writes.
    static func fieldCode(_ instruction: String) -> String? {
        if instruction.uppercased().hasPrefix("DOCPROPERTY ") {
            let name = instruction.dropFirst("DOCPROPERTY ".count)
                .trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        let head = instruction.split(separator: " ").first.map(String.init) ?? instruction
        return DocxMapping.instructionToField[head]
    }

    /// The `_meta` block, in the shape every Neutrino client stores it in.
    static func metaValue(bands: Bands, background: String, extras: DocxExtras,
                          properties: [String: DocValue],
                          pageSetup: [String: DocValue]) -> DocValue {
        func slotsValue(_ slots: DocxMeta.Slots) -> DocValue {
            .object(["left": .string(slots.left), "center": .string(slots.center),
                     "right": .string(slots.right)])
        }

        var variants: [String: DocValue] = [:]
        for variant in DocxMeta.Variant.allCases {
            let pair = bands.variants[variant.rawValue]
                ?? (header: DocxMeta.Slots(), footer: DocxMeta.Slots())
            variants[variant.rawValue] = .object(["header": slotsValue(pair.header),
                                                  "footer": slotsValue(pair.footer)])
        }

        let headerFooter: DocValue = .object([
            "differentFirstPage": .bool(bands.differentFirstPage),
            "differentEvenOdd": .bool(bands.differentEvenOdd),
            "headerMargin": .int(Int(bands.headerMargin.rounded())),
            "footerMargin": .int(Int(bands.footerMargin.rounded())),
            "variants": .object(variants),
        ])

        let defaultBand = bands.variants["default"]
            ?? (header: DocxMeta.Slots(), footer: DocxMeta.Slots())
        let pageNumberSource = defaultBand.footer.center + defaultBand.header.right

        return .object([
            "headerFooter": headerFooter,
            // The flattened legacy view of the default variant, still written so a build without the
            // header/footer feature opens the document showing something rather than nothing.
            "headerText": .string(defaultBand.header.center),
            "footerText": .string(defaultBand.footer.center),
            "showPageNumbers": .bool(pageNumberSource.contains("{{page}}")),
            "watermarkText": .string(bands.watermark),
            "bgColor": .string(background),
            "docTheme": .string(extras.theme ?? "default"),
            "properties": .object(properties),
            "pageSetup": .object(pageSetup),
        ])
    }
}
