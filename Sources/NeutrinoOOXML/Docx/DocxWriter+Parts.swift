import Foundation

// MARK: - Band parts

extension DocxWriter {

    /// One header or footer part: where it lives, what refers to it, and what is in it.
    struct BandPart {
        let path: String
        let relID: String
        /// `header` or `footer` — which reference element points at it.
        let kind: String
        /// `default`, `first` or `even`.
        let variant: String
        let xml: String
    }

    /// The header and footer parts a document's bands call for.
    ///
    /// A variant with nothing in it gets no part at all: writing an empty `first` header would give
    /// page one a blank band where it should inherit the default one.
    static func bandParts(meta: DocxMeta, context: WriteContext) -> [BandPart] {
        var parts: [BandPart] = []
        var headers = 0
        var footers = 0
        let textWidth = self.textWidth(meta: meta)

        for variant in DocxMeta.Variant.allCases where meta.writes(variant) {
            let band = meta.band(variant)
            let watermark = variant == .default ? meta.watermarkText : ""

            if !band.header.isEmpty || !watermark.isEmpty {
                headers += 1
                let content = (watermark.isEmpty ? "" : watermarkXML(watermark))
                    + bandParagraphXML(band.header, width: textWidth)
                parts.append(BandPart(
                    path: OOXMLPackage.headerPart(headers),
                    relID: context.relationshipID(), kind: "header",
                    variant: variant.rawValue,
                    xml: bandPartXML(root: "w:hdr", content: content)))
            }
            if !band.footer.isEmpty {
                footers += 1
                parts.append(BandPart(
                    path: OOXMLPackage.footerPart(footers),
                    relID: context.relationshipID(), kind: "footer",
                    variant: variant.rawValue,
                    xml: bandPartXML(root: "w:ftr",
                                     content: bandParagraphXML(band.footer, width: textWidth))))
            }
        }
        return parts
    }

    /// The width of the text column, in twips — where the centre and right tab stops of a band go.
    private static func textWidth(meta: DocxMeta) -> Int {
        let size = DocxMapping.pageSizeTwips[meta.pageSize] ?? DocxMapping.pageSizeTwips["letter"]!
        let pageWidth = meta.isLandscape ? size.h : size.w
        return pageWidth - DocxMapping.ptToTwip(meta.margin("Left"))
            - DocxMapping.ptToTwip(meta.margin("Right"))
    }

    /// One band as a single centre-tabbed paragraph.
    ///
    /// The three slots are laid out with tab stops rather than a table, which is how Word's own
    /// header styles do it: a centre tab at the middle of the text width and a right tab at its end,
    /// so `left⇥centre⇥right` lands where the editor draws it.
    private static func bandParagraphXML(_ slots: DocxMeta.Slots, width: Int) -> String {
        var content = ""
        func push(_ text: String) {
            for part in splitFields(text) {
                if let field = part.field {
                    content += el("w:fldSimple", [("w:instr", field)])
                } else if !part.text.isEmpty {
                    content += runXML(RunStyle(), textEl(part.text))
                }
            }
        }
        // A tab is a run child (`w:r/w:tab`), never a paragraph child. Emitting it at paragraph
        // level produces XML Word rejects outright.
        func tab() { content += el("w:r", [], el("w:tab")) }

        push(slots.left)
        if !slots.center.isEmpty || !slots.right.isEmpty { tab() }
        push(slots.center)
        if !slots.right.isEmpty { tab() }
        push(slots.right)

        let tabs = el("w:tabs", [],
            el("w:tab", [("w:val", "center"), ("w:pos", String(width / 2))])
            + el("w:tab", [("w:val", "right"), ("w:pos", String(width))]))
        return el("w:p", [], el("w:pPr", [], tabs) + content)
    }

    /// Band text split into literal runs and field instructions.
    ///
    /// `{{page}}` in a footer has to become a `PAGE` field, not the text "1" — a footer that says 1
    /// on every page is the classic symptom of exporting the resolved value instead of the field.
    static func splitFields(_ text: String) -> [(text: String, field: String?)] {
        var out: [(text: String, field: String?)] = []
        var literal = ""
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index...].hasPrefix("{{"),
                  let close = text.range(of: "}}", range: index..<text.endIndex) else {
                literal.append(text[index])
                index = text.index(after: index)
                continue
            }
            let name = String(text[text.index(index, offsetBy: 2)..<close.lowerBound])
            // Only a bare token is a field. `{{ not a code }}` is text somebody typed.
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                literal.append(text[index])
                index = text.index(after: index)
                continue
            }
            if !literal.isEmpty { out.append((text: literal, field: nil)); literal = "" }
            let instruction = DocxMapping.fieldToInstruction[name]
                ?? DocxMapping.docPropertyInstruction(name)
            out.append((text: "", field: instruction))
            index = close.upperBound
        }
        if !literal.isEmpty { out.append((text: literal, field: nil)) }
        return out
    }

    private static func bandPartXML(root: String, content: String) -> String {
        XMLText.declaration
            + "<\(root) xmlns:w=\"\(OOXMLNamespace.w)\" xmlns:r=\"\(OOXMLNamespace.r)\" "
            + "xmlns:v=\"urn:schemas-microsoft-com:vml\" "
            + "xmlns:o=\"urn:schemas-microsoft-com:office:office\">"
            + content + "</\(root)>"
    }

    /// A watermark: Word draws one as a VML shape in the header, which has no DrawingML equivalent
    /// that Word will render behind the text.
    private static func watermarkXML(_ text: String) -> String {
        let style = "position:absolute;margin-left:0;margin-top:0;width:468pt;height:117pt;"
            + "rotation:315;z-index:-251654144;mso-position-horizontal:center;"
            + "mso-position-horizontal-relative:margin;mso-position-vertical:center;"
            + "mso-position-vertical-relative:margin"
        return el("w:p", [], el("w:r", [], el("w:pict", [],
            el("v:shape", [("id", "NeutrinoWatermark"), ("o:spid", "_x0000_s2049"),
                           ("type", "#_x0000_t136"), ("style", style),
                           ("fillcolor", "#c0c0c0"), ("stroked", "f")],
               el("v:textpath", [("style", "font-family:\"Calibri\";font-size:1pt"),
                                 ("string", text)])))))
    }
}

// MARK: - The document part

extension DocxWriter {

    static func documentPart(body: String, meta: DocxMeta, bands: [BandPart],
                             context: WriteContext) -> String {
        let background = meta.backgroundColor.isEmpty
            ? ""
            : el("w:background", [("w:color", DocxMapping.hexToOOXML(meta.backgroundColor))])

        return XMLText.declaration
            + "<w:document xmlns:w=\"\(OOXMLNamespace.w)\" xmlns:r=\"\(OOXMLNamespace.r)\" "
            + "xmlns:wp=\"\(OOXMLNamespace.wp)\" xmlns:a=\"\(OOXMLNamespace.a)\" "
            + "xmlns:pic=\"\(OOXMLNamespace.pic)\" xmlns:v=\"urn:schemas-microsoft-com:vml\" "
            + "xmlns:o=\"urn:schemas-microsoft-com:office:office\">"
            + background
            + el("w:body", [], body + sectionPropertiesXML(meta: meta, bands: bands))
            + "</w:document>"
    }

    /// The section properties every document ends with: its page, its margins and its bands.
    private static func sectionPropertiesXML(meta: DocxMeta, bands: [BandPart]) -> String {
        var out = ""
        for band in bands {
            out += el("w:\(band.kind)Reference", [("w:type", band.variant), ("r:id", band.relID)])
        }

        let size = DocxMapping.pageSizeTwips[meta.pageSize] ?? DocxMapping.pageSizeTwips["letter"]!
        // Landscape swaps the dimensions rather than only setting the attribute: a reader that
        // ignores `w:orient` still lays the page out the right way round.
        let width = meta.isLandscape ? size.h : size.w
        let height = meta.isLandscape ? size.w : size.h
        var pageAttributes = [("w:w", String(width)), ("w:h", String(height))]
        if meta.isLandscape { pageAttributes.append(("w:orient", "landscape")) }
        out += el("w:pgSz", pageAttributes)

        out += el("w:pgMar", [
            ("w:top", String(DocxMapping.ptToTwip(meta.margin("Top")))),
            ("w:right", String(DocxMapping.ptToTwip(meta.margin("Right")))),
            ("w:bottom", String(DocxMapping.ptToTwip(meta.margin("Bottom")))),
            ("w:left", String(DocxMapping.ptToTwip(meta.margin("Left")))),
            ("w:header", String(DocxMapping.ptToTwip(meta.headerMargin))),
            ("w:footer", String(DocxMapping.ptToTwip(meta.footerMargin))),
            ("w:gutter", "0"),
        ])

        if meta.differentFirstPage { out += el("w:titlePg") }
        return el("w:sectPr", [], out)
    }
}

// MARK: - Supporting parts

extension DocxWriter {

    /// Relationship ids for the parts every package has. Low and fixed — see
    /// ``WriteContext/relationshipID()`` for why nothing else can collide with them.
    private enum FixedRel {
        static let styles = "rId1"
        static let numbering = "rId2"
        static let settings = "rId3"
        static let footnotes = "rId4"
        static let extras = "rId5"
        static let document = "rId1"
        static let coreProps = "rId2"
        static let appProps = "rId3"
        static let customProps = "rId4"
        static let extrasProps = "rId1"
    }

    static func documentRelsPart(bands: [BandPart], context: WriteContext) -> String {
        var out = ""
        out += relationship(FixedRel.styles, OOXMLRelationship.styles, "styles.xml")
        out += relationship(FixedRel.numbering, OOXMLRelationship.numbering, "numbering.xml")
        out += relationship(FixedRel.settings, OOXMLRelationship.settings, "settings.xml")
        out += relationship(FixedRel.footnotes, OOXMLRelationship.footnotes, "footnotes.xml")
        if !context.extras.isEmpty {
            out += relationship(FixedRel.extras, OOXMLRelationship.customXml,
                                "../\(DocxMapping.extrasPart)")
        }
        for band in bands {
            let type = band.kind == "header" ? OOXMLRelationship.header : OOXMLRelationship.footer
            out += relationship(band.relID, type, String(band.path.dropFirst("word/".count)))
        }
        for image in context.imageParts {
            out += relationship(image.relID, OOXMLRelationship.image,
                                String(image.path.dropFirst("word/".count)))
        }
        for link in context.hyperlinks {
            out += relationship(link.relID, OOXMLRelationship.hyperlink, link.target,
                                external: true)
        }
        return relationshipsPart(out)
    }

    static func rootRelsPart(hasCustomProps: Bool) -> String {
        var out = relationship(FixedRel.document, OOXMLRelationship.officeDocument, "word/document.xml")
        out += relationship(FixedRel.coreProps, OOXMLRelationship.coreProperties, "docProps/core.xml")
        out += relationship(FixedRel.appProps, OOXMLRelationship.extendedProperties, "docProps/app.xml")
        if hasCustomProps {
            out += relationship(FixedRel.customProps, OOXMLRelationship.customProperties,
                                "docProps/custom.xml")
        }
        return relationshipsPart(out)
    }

    /// The extras part's own relationship to its properties part.
    ///
    /// Without it Word treats the custom XML item as an orphan and drops it on the first save,
    /// which is the one thing the extras part exists to survive.
    static func extrasRelsPart() -> String {
        relationshipsPart(relationship(FixedRel.extrasProps, OOXMLRelationship.customXmlProps,
                                       "itemProps1.xml"))
    }

    private static func relationshipsPart(_ relationships: String) -> String {
        XMLText.declaration
            + "<Relationships xmlns=\"\(OOXMLNamespace.packageRels)\">\(relationships)</Relationships>"
    }

    private static func relationship(_ id: String, _ type: String, _ target: String,
                                     external: Bool = false) -> String {
        var attributes = [("Id", id), ("Type", type), ("Target", target)]
        if external { attributes.append(("TargetMode", "External")) }
        return el("Relationship", attributes)
    }

    static func contentTypesPart(bands: [BandPart], context: WriteContext, meta: DocxMeta) -> String {
        let wordML = "application/vnd.openxmlformats-officedocument.wordprocessingml"
        var out = el("Default", [("Extension", "rels"),
                                 ("ContentType", "application/vnd.openxmlformats-package.relationships+xml")])
        out += el("Default", [("Extension", "xml"), ("ContentType", "application/xml")])

        // Only the image types actually in the package: a Default for an extension nothing uses is
        // harmless, and one that is missing makes the package invalid.
        var extensions = Set(context.imageParts.map { $0.path.split(separator: ".").last.map(String.init) ?? "png" })
        // `jpg` and `jpeg` are two extensions for one type; the writer only ever emits the latter.
        extensions.remove("")
        for ext in extensions.sorted() {
            out += el("Default", [("Extension", ext), ("ContentType", "image/\(ext)")])
        }

        out += override(OOXMLPackage.documentPart, "\(wordML).document.main+xml")
        out += override(OOXMLPackage.stylesPart, "\(wordML).styles+xml")
        out += override(OOXMLPackage.numberingPart, "\(wordML).numbering+xml")
        out += override(OOXMLPackage.settingsPart, "\(wordML).settings+xml")
        out += override(OOXMLPackage.footnotesPart, "\(wordML).footnotes+xml")
        for band in bands {
            out += override(band.path, "\(wordML).\(band.kind)+xml")
        }
        out += override(OOXMLPackage.corePropsPart,
                        "application/vnd.openxmlformats-package.core-properties+xml")
        out += override(OOXMLPackage.appPropsPart,
                        "application/vnd.openxmlformats-officedocument.extended-properties+xml")
        if meta.hasCustomProperties {
            out += override(OOXMLPackage.customPropsPart,
                            "application/vnd.openxmlformats-officedocument.custom-properties+xml")
        }
        if !context.extras.isEmpty {
            out += override(DocxMapping.extrasPart, "application/xml")
            out += override(DocxMapping.extrasPropsPart,
                            "application/vnd.openxmlformats-officedocument.customXmlProperties+xml")
        }
        return XMLText.declaration
            + "<Types xmlns=\"\(OOXMLNamespace.contentTypes)\">\(out)</Types>"
    }

    private static func override(_ part: String, _ contentType: String) -> String {
        el("Override", [("PartName", "/\(part)"), ("ContentType", contentType)])
    }

    static func settingsPart(meta: DocxMeta) -> String {
        var out = ""
        if meta.differentEvenOdd { out += el("w:evenAndOddHeaders") }
        // Word ignores `w:background` unless the document asks for it to be drawn.
        if !meta.backgroundColor.isEmpty { out += el("w:displayBackgroundShape") }
        out += el("w:footnotePr", [], el("w:footnote", [("w:id", "-1")])
                  + el("w:footnote", [("w:id", "0")]))
        return XMLText.declaration
            + "<w:settings xmlns:w=\"\(OOXMLNamespace.w)\">\(out)</w:settings>"
    }

    static func footnotesPart(context: WriteContext) -> String {
        // Ids below 1 are the separator marks Word draws above a note, not notes; the reader skips
        // them for exactly that reason.
        var out = el("w:footnote", [("w:id", "-1"), ("w:type", "separator")],
                     el("w:p", [], el("w:r", [], el("w:separator"))))
        out += el("w:footnote", [("w:id", "0"), ("w:type", "continuationSeparator")],
                  el("w:p", [], el("w:r", [], el("w:continuationSeparator"))))
        for note in context.footnotes {
            let paragraph = el("w:p", [],
                el("w:pPr", [], valEl("w:pStyle", "FootnoteText"))
                + el("w:r", [], el("w:rPr", [], valEl("w:rStyle", "FootnoteReference"))
                     + el("w:footnoteRef"))
                + runXML(RunStyle(), textEl(" " + note.text)))
            out += el("w:footnote", [("w:id", String(note.id))], paragraph)
        }
        return XMLText.declaration
            + "<w:footnotes xmlns:w=\"\(OOXMLNamespace.w)\">\(out)</w:footnotes>"
    }

    static func numberingPart(context: WriteContext) -> String {
        var out = ""
        for definition in context.numbering {
            let abstractID = definition.numID - 1
            var levels = ""
            for level in 0..<5 {
                let format = definition.ordered
                    ? (DocxMapping.orderedStyleToNumFmt[definition.styleType] ?? "decimal")
                    : "bullet"
                let text = definition.ordered
                    ? "%\(level + 1)."
                    : (DocxMapping.bulletGlyph[definition.styleType] ?? "\u{25CF}")
                levels += el("w:lvl", [("w:ilvl", String(level))],
                    valEl("w:start", "1")
                    + valEl("w:numFmt", format)
                    + valEl("w:lvlText", text)
                    + valEl("w:lvlJc", "left")
                    + el("w:pPr", [], el("w:ind", [("w:left", String(720 * (level + 1))),
                                                   ("w:hanging", "360")])))
            }
            out += el("w:abstractNum", [("w:abstractNumId", String(abstractID))],
                      valEl("w:multiLevelType", "hybridMultilevel") + levels)
        }
        for definition in context.numbering {
            out += el("w:num", [("w:numId", String(definition.numID))],
                      valEl("w:abstractNumId", String(definition.numID - 1)))
        }
        return XMLText.declaration
            + "<w:numbering xmlns:w=\"\(OOXMLNamespace.w)\">\(out)</w:numbering>"
    }

    static func corePropsPart(title: String, meta: DocxMeta) -> String {
        // The author is written even when it is empty, rather than omitted: a reader that finds no
        // `dc:creator` is free to invent one, and a document would then acquire an author it never
        // had the first time anything else opened it.
        let out = "<dc:title>\(XMLText.escape(title))</dc:title>"
            + "<dc:subject>\(XMLText.escape(meta.subject))</dc:subject>"
            + "<dc:creator>\(XMLText.escape(meta.author))</dc:creator>"
            + "<cp:keywords>\(XMLText.escape(meta.keywords))</cp:keywords>"
            + "<dc:description>\(XMLText.escape(meta.category))</dc:description>"
            + "<cp:lastModifiedBy>\(XMLText.escape(meta.author))</cp:lastModifiedBy>"
        return XMLText.declaration
            + "<cp:coreProperties xmlns:cp=\"\(OOXMLNamespace.cp)\" xmlns:dc=\"\(OOXMLNamespace.dc)\" "
            + "xmlns:dcterms=\"\(OOXMLNamespace.dcterms)\" xmlns:xsi=\"\(OOXMLNamespace.xsi)\">"
            + out + "</cp:coreProperties>"
    }

    static func appPropsPart() -> String {
        XMLText.declaration
            + "<Properties xmlns=\"\(OOXMLNamespace.customProps)\">"
            + "<Application>Neutrino Docs</Application>"
            + "</Properties>"
    }

    /// `docProps/custom.xml`, or nil when the document has no properties that belong there.
    ///
    /// `docProps/core.xml` has no element for company or manager, and none at all for a user-defined
    /// property, so those go here — which is also where a `DOCPROPERTY` field looks for them, so a
    /// `{{whatever}}` field in the document resolves in Word rather than reading `!Undefined`.
    static func customPropsPart(meta: DocxMeta) -> String? {
        guard meta.hasCustomProperties else { return nil }
        var entries: [(String, String)] = []
        if !meta.company.isEmpty { entries.append(("company", meta.company)) }
        if !meta.manager.isEmpty { entries.append(("manager", meta.manager)) }
        entries += meta.customProperties.map { ($0.name, $0.value) }

        var out = ""
        for (index, entry) in entries.enumerated() {
            // Property ids start at 2 — 0 and 1 are reserved by the format.
            out += el("property", [("fmtid", "{D5CDD505-2E9C-101B-9397-08002B2CF9AE}"),
                                   ("pid", String(index + 2)), ("name", entry.0)],
                      "<vt:lpwstr>\(XMLText.escape(entry.1))</vt:lpwstr>")
        }
        return XMLText.declaration
            + "<Properties xmlns=\"\(OOXMLNamespace.customProperties)\" "
            + "xmlns:vt=\"\(OOXMLNamespace.vt)\">\(out)</Properties>"
    }

    /// `word/styles.xml`.
    ///
    /// Everything the mapping refers to by style id is defined here, because a style id that names
    /// nothing is a paragraph Word draws as body text — and, on the way back in, a heading that is
    /// no longer a heading.
    static func stylesPart() -> String {
        let defaults = el("w:docDefaults", [],
            el("w:rPrDefault", [], el("w:rPr", [],
                el("w:rFonts", [("w:ascii", "Calibri"), ("w:hAnsi", "Calibri")])
                + valEl("w:sz", "22")))
            + el("w:pPrDefault", [], el("w:pPr", [],
                el("w:spacing", [("w:after", "160"), ("w:line", "259"), ("w:lineRule", "auto")]))))

        var styles = el("w:style", [("w:type", "paragraph"), ("w:default", "1"),
                                    ("w:styleId", "Normal")],
                        valEl("w:name", "Normal"))
        styles += el("w:style", [("w:type", "character"), ("w:default", "1"),
                                 ("w:styleId", "DefaultParagraphFont")],
                     valEl("w:name", "Default Paragraph Font"))

        // Heading sizes step down the way Word's own do, so a document opened in either looks like
        // the same document.
        let headingSizes = [32, 26, 24, 22, 22, 22]
        for level in 1...6 {
            styles += el("w:style", [("w:type", "paragraph"),
                                     ("w:styleId", DocxMapping.headingStyleID(level))],
                valEl("w:name", "heading \(level)")
                + valEl("w:basedOn", "Normal")
                + valEl("w:next", "Normal")
                + el("w:pPr", [], el("w:spacing", [("w:before", "240"), ("w:after", "120")])
                     + valEl("w:outlineLvl", String(level - 1)))
                + el("w:rPr", [], el("w:b")
                     + valEl("w:sz", String(headingSizes[level - 1]))
                     + valEl("w:szCs", String(headingSizes[level - 1]))))
        }

        styles += el("w:style", [("w:type", "character"), ("w:styleId", "Hyperlink")],
            valEl("w:name", "Hyperlink")
            + el("w:rPr", [], valEl("w:color", "0563C1") + valEl("w:u", "single")))

        styles += el("w:style", [("w:type", "character"), ("w:styleId", "FootnoteReference")],
            valEl("w:name", "footnote reference")
            + el("w:rPr", [], valEl("w:vertAlign", "superscript")))

        styles += el("w:style", [("w:type", "paragraph"), ("w:styleId", "FootnoteText")],
            valEl("w:name", "footnote text")
            + valEl("w:basedOn", "Normal")
            + el("w:rPr", [], valEl("w:sz", "20")))

        styles += el("w:style", [("w:type", "paragraph"), ("w:styleId", DocxMapping.quoteStyleID)],
            valEl("w:name", "Neutrino Quote")
            + valEl("w:basedOn", "Normal")
            + valEl("w:next", "Normal")
            + el("w:pPr", [], el("w:spacing", [("w:before", "120"), ("w:after", "120")])
                 + el("w:ind", [("w:left", "720")]))
            + el("w:rPr", [], el("w:i") + valEl("w:color", "555555")))

        styles += el("w:style", [("w:type", "paragraph"),
                                 ("w:styleId", DocxMapping.codeBlockStyleID)],
            valEl("w:name", "Neutrino Code Block")
            + valEl("w:basedOn", "Normal")
            + valEl("w:next", "Normal")
            + el("w:pPr", [], el("w:spacing", [("w:before", "120"), ("w:after", "120")]))
            // The tint is a run property: `w:pPr` has no shading, and putting one there is silently
            // dropped rather than rejected.
            + el("w:rPr", [], el("w:rFonts", [("w:ascii", "Consolas"), ("w:hAnsi", "Consolas")])
                 + valEl("w:sz", "20")
                 + el("w:shd", [("w:val", "clear"), ("w:color", "auto"), ("w:fill", "F5F5F5")])))

        styles += el("w:style", [("w:type", "character"), ("w:styleId", DocxMapping.codeStyleID)],
            valEl("w:name", "Neutrino Code")
            + valEl("w:basedOn", "DefaultParagraphFont")
            + el("w:rPr", [], el("w:rFonts", [("w:ascii", "Consolas"), ("w:hAnsi", "Consolas")])
                 + el("w:shd", [("w:val", "clear"), ("w:color", "auto"), ("w:fill", "F5F5F5")])))

        styles += el("w:style", [("w:type", "character"),
                                 ("w:styleId", DocxMapping.placeholderStyleID)],
            // Italic, because that is how a placeholder should read in Word; a named style, because
            // that is how it is found again.
            valEl("w:name", "Neutrino Placeholder")
            + valEl("w:basedOn", "DefaultParagraphFont")
            + el("w:rPr", [], el("w:i")))

        return XMLText.declaration
            + "<w:styles xmlns:w=\"\(OOXMLNamespace.w)\">\(defaults)\(styles)</w:styles>"
    }
}
