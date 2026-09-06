import Foundation

// MARK: - Element helpers

extension DocxWriter {

    /// One XML element, self-closing when it has no children.
    static func el(_ name: String, _ attributes: [(String, String)] = [],
                   _ children: String? = nil) -> String {
        let attrs = attributes
            .map { " \($0.0)=\"\(XMLText.attributeValue($0.1))\"" }
            .joined()
        guard let children, !children.isEmpty else { return "<\(name)\(attrs)/>" }
        return "<\(name)\(attrs)>\(children)</\(name)>"
    }

    /// `w:val="…"`, which is how OOXML spells nearly every simple property.
    static func valEl(_ name: String, _ value: String) -> String {
        el(name, [("w:val", value)])
    }
}

// MARK: - Run properties

extension DocxWriter {

    /// Marks on a text node collapsed into the run properties that express them.
    ///
    /// `highlight` is the one that needs a decision: OOXML's `w:highlight` is a closed sixteen-colour
    /// list, so a highlight that is not one of them is written as run shading (`w:shd`) instead,
    /// which takes any colour. Both come back as a highlight mark on the way in.
    struct RunStyle {
        var styleID: String?
        var font: String?
        var bold = false
        var italic = false
        var strike = false
        var color: String?
        var halfPoints: Int?
        var highlight: String?
        var underline = false
        var shadingFill: String?
        var vertAlign: String?

        var isEmpty: Bool {
            styleID == nil && font == nil && !bold && !italic && !strike && color == nil
                && halfPoints == nil && highlight == nil && !underline && shadingFill == nil
                && vertAlign == nil
        }
    }

    static func runStyle(for marks: [DocMark]?) -> RunStyle {
        var style = RunStyle()
        for mark in marks ?? [] {
            switch mark.type {
            case "bold":        style.bold = true
            case "italic":      style.italic = true
            case "underline":   style.underline = true
            case "strike":      style.strike = true
            case "superscript": style.vertAlign = "superscript"
            case "subscript":   style.vertAlign = "subscript"
            case "code":        style.styleID = DocxMapping.codeStyleID
            case "highlight":
                let hex = DocxMapping.normalizeColor(mark.attr("color")?.stringValue)
                if let name = DocxMapping.highlightNames[hex] {
                    style.highlight = name
                } else if !hex.isEmpty {
                    style.shadingFill = DocxMapping.hexToOOXML(hex)
                }
            case "textStyle":
                let color = DocxMapping.normalizeColor(mark.attr("color")?.stringValue)
                if !color.isEmpty { style.color = DocxMapping.hexToOOXML(color) }
                if let size = DocxMapping.fontSizeToHalfPoints(mark.attr("fontSize")?.stringValue) {
                    style.halfPoints = size
                }
                if let family = mark.attr("fontFamily")?.stringValue, !family.isEmpty {
                    style.font = family
                }
            default: break
            }
        }
        return style
    }

    /// `w:rPr`, with its children in the order the schema declares them — Word is tolerant of a
    /// different one and the validators other suites run are not.
    static func runPropertiesXML(_ style: RunStyle) -> String {
        guard !style.isEmpty else { return "" }
        var out = ""
        if let styleID = style.styleID { out += valEl("w:rStyle", styleID) }
        if let font = style.font {
            out += el("w:rFonts", [("w:ascii", font), ("w:hAnsi", font), ("w:cs", font)])
        }
        if style.bold { out += el("w:b") }
        if style.italic { out += el("w:i") }
        if style.strike { out += el("w:strike") }
        if let color = style.color { out += valEl("w:color", color) }
        if let half = style.halfPoints {
            out += valEl("w:sz", String(half))
            out += valEl("w:szCs", String(half))
        }
        if let highlight = style.highlight { out += valEl("w:highlight", highlight) }
        if style.underline { out += valEl("w:u", "single") }
        if let fill = style.shadingFill {
            out += el("w:shd", [("w:val", "clear"), ("w:color", "auto"), ("w:fill", fill)])
        }
        if let vertAlign = style.vertAlign { out += valEl("w:vertAlign", vertAlign) }
        return el("w:rPr", [], out)
    }

    /// One run: its properties, then its content.
    static func runXML(_ style: RunStyle, _ content: String) -> String {
        el("w:r", [], runPropertiesXML(style) + content)
    }

    /// `w:t`, always with `xml:space="preserve"` — a run whose text begins or ends with a space is
    /// ordinary, and without this Word eats it.
    static func textEl(_ text: String, deleted: Bool = false) -> String {
        let name = deleted ? "w:delText" : "w:t"
        return "<\(name) xml:space=\"preserve\">\(XMLText.escape(text))</\(name)>"
    }
}

// MARK: - Inline content

extension DocxWriter {

    /// One paragraph's children.
    ///
    /// Tracked insertions and deletions become `w:ins`/`w:del` runs — Word's own revision marks, so
    /// a suggestion made in Neutrino is a suggestion Word can accept or reject. Both carry the
    /// author and a date, which OOXML requires.
    static func inlineXML(_ nodes: [DocNode], context: WriteContext) -> String {
        var out = ""
        for node in nodes {
            switch node.type {
            case "text":
                out += textRunsXML(node, context: context)
            case "hardBreak":
                out += el("w:r", [], el("w:br"))
            case "image":
                out += imageXML(node, context: context)
            case "footnote":
                let number = context.footnoteNumber(text: node.attr("text")?.stringValue ?? "")
                out += el("w:r", [],
                          el("w:rPr", [], valEl("w:rStyle", "FootnoteReference"))
                          + el("w:footnoteReference", [("w:id", String(number))]))
            case "docField":
                out += fieldXML(node, context: context)
            case "sheetEmbed", "diagramEmbed":
                out += embedXML(node, context: context)
            default:
                // An inline node the mapping does not know. Its text still belongs in the document —
                // dropping it silently is the failure mode this whole module exists to avoid.
                if let content = node.content { out += inlineXML(content, context: context) }
            }
        }
        return out
    }

    /// A text node as one or more runs.
    ///
    /// Three of the marks a run can carry are not run properties in OOXML but elements that
    /// *contain* the run — `w:hyperlink` for a link, `w:ins`/`w:del` for a tracked change,
    /// `w:fldSimple` for a cross-reference. They nest, and the nesting order is the one Word writes:
    /// the hyperlink outermost, since a link is a property of the text's position in the document
    /// rather than of the revision that put it there.
    private static func textRunsXML(_ node: DocNode, context: WriteContext) -> String {
        var style = runStyle(for: node.marks)
        let text = node.text ?? ""

        let link = node.mark("link")
        let crossRef = node.mark("crossRef")
        let inserted = node.mark("trackedInsertion")
        let deleted = node.mark("trackedDeletion")
        // The hyperlink style has to be on the run inside the `w:hyperlink`, whatever kind of run
        // that turns out to be.
        if link != nil { style.styleID = "Hyperlink" }

        var run: String
        if let crossRef {
            let index = context.nextIndex("crossRef")
            let headingText = crossRef.attr("headingText")?.stringValue ?? ""
            context.extras.addCrossRef(headingText, at: index)
            // A REF field pointed at the bookmark the matching heading carries. Word resolves and
            // updates it; the reader restores the mark from the extras. The cached result matters:
            // a field with none loses the text the reference was written on until Word is asked to
            // update fields, and on the way back in there would be nothing to put the mark on.
            let instruction = "REF \(context.bookmark(for: headingText)) \\h"
            run = el("w:fldSimple", [("w:instr", instruction)], runXML(style, textEl(text)))
        } else if inserted != nil || deleted != nil {
            let mark = inserted ?? deleted
            let attributes: [(String, String)] = [
                ("w:id", String(context.nextRevisionID())),
                ("w:author", mark?.attr("author")?.stringValue ?? "Unknown"),
                ("w:date", context.revisionDate),
            ]
            run = el(deleted != nil ? "w:del" : "w:ins", attributes,
                     runXML(style, textEl(text, deleted: deleted != nil)))
        } else {
            run = runXML(style, textEl(text))
        }

        guard let link else { return run }
        let href = link.attr("href")?.stringValue ?? ""
        let relID = context.hyperlinkRelationship(for: href)
        return el("w:hyperlink", [("r:id", relID)], run)
    }

    /// A `docField` node as a real Word field, so it stays live in Word.
    private static func fieldXML(_ node: DocNode, context: WriteContext) -> String {
        let code = node.attr("code")?.stringValue ?? "title"
        let argument = node.attr("arg")?.stringValue
        let index = context.nextIndex("docField")
        if node.attr("showCode")?.boolValue == true { context.extras.addFieldShowCode(index) }

        let instruction: String
        if code == "custom", let argument, !argument.isEmpty {
            instruction = DocxMapping.docPropertyInstruction(argument)
        } else if let builtIn = DocxMapping.fieldToInstruction[code] {
            instruction = builtIn
        } else {
            instruction = DocxMapping.docPropertyInstruction(argument ?? code)
        }
        return el("w:fldSimple", [("w:instr", instruction)])
    }

    /// An embed as the only thing OOXML can honestly carry: its title as text.
    ///
    /// A sheet or diagram embed is a live view onto another Drive file. Word has no such concept —
    /// an OLE object would be a dead snapshot pretending otherwise — so what goes into the document
    /// is a legible placeholder, and the embed's attributes ride in the extras where the reader
    /// picks them back up intact.
    static func embedXML(_ node: DocNode, context: WriteContext) -> String {
        context.extras.addPlaceholder(kind: node.type, attrs: node.attrs ?? [:])
        let fallback = node.type == "sheetEmbed" ? "Embedded sheet" : "Embedded diagram"
        let label = node.attr("title")?.stringValue ?? fallback
        return placeholderRunXML("[\(label)]")
    }

    /// The run every placeholder is written as: italic, and in a character style of its own so it
    /// can be found again — see ``DocxMapping/placeholderStyleID``.
    static func placeholderRunXML(_ text: String) -> String {
        var style = RunStyle()
        style.styleID = DocxMapping.placeholderStyleID
        style.italic = true
        return runXML(style, textEl(text))
    }

    /// An image as a real `w:drawing`.
    ///
    /// A `neutrino-drive:` reference cannot travel — it names a file in this Drive — so the caller
    /// resolves it to bytes before we get here, and the reference itself is kept in the extras so
    /// reopening in Neutrino restores a reference rather than a multi-megabyte inline copy.
    static func imageXML(_ node: DocNode, context: WriteContext) -> String {
        let src = node.attr("src")?.stringValue ?? ""
        guard let bytes = imageData(for: src, context: context) else {
            // The caller could not resolve the image — a `neutrino-drive:` reference saved from a
            // session that could not reach Drive, most often. It goes out as a placeholder carrying
            // its whole attribute set, so reopening in Neutrino restores the image node rather than
            // a line of italic text. It deliberately does *not* consume an image index: the reader
            // counts those off `w:drawing` elements, and an entry with no drawing behind it would
            // shift every later image's extras onto the wrong picture.
            context.extras.addPlaceholder(kind: "image", attrs: node.attrs ?? [:])
            let caption = node.attr("caption")?.stringValue
            return placeholderRunXML(caption.map { "[\($0)]" } ?? "[image]")
        }

        let index = context.nextIndex("image")
        let width = node.attr("width")?.doubleValue ?? 480
        let height = (width * 0.6).rounded()

        var extra = DocxExtras.ImageExtra()
        if let shadow = node.attr("shadow")?.stringValue, shadow != "none" { extra.shadow = shadow }
        if let filter = node.attr("imageFilter")?.stringValue, filter != "none" { extra.filter = filter }
        if let caption = node.attr("caption")?.stringValue, !caption.isEmpty { extra.caption = caption }
        if src.hasPrefix(DocxCodec.driveReferenceScheme) { extra.driveRef = src }
        context.extras.addImage(extra, at: index)

        let relID = context.imageRelationship(for: src, data: bytes)
        let drawingID = context.nextDrawing()
        let alt = node.attr("alt")?.stringValue ?? ""
        let cx = DocxMapping.pxToEmu(width)
        let cy = DocxMapping.pxToEmu(height)

        let picture = el("pic:pic", [("xmlns:pic", OOXMLNamespace.pic)],
            el("pic:nvPicPr", [],
               el("pic:cNvPr", [("id", "0"), ("name", "image\(drawingID)"), ("descr", alt)])
               + el("pic:cNvPicPr"))
            + el("pic:blipFill", [],
                 el("a:blip", [("r:embed", relID)])
                 + el("a:stretch", [], el("a:fillRect")))
            + el("pic:spPr", [],
                 el("a:xfrm", [],
                    el("a:off", [("x", "0"), ("y", "0")])
                    + el("a:ext", [("cx", String(cx)), ("cy", String(cy))]))
                 + el("a:prstGeom", [("prst", "rect")], el("a:avLst"))))

        let inline = el("wp:inline", [("distT", "0"), ("distB", "0"), ("distL", "0"), ("distR", "0")],
            el("wp:extent", [("cx", String(cx)), ("cy", String(cy))])
            + el("wp:effectExtent", [("l", "0"), ("t", "0"), ("r", "0"), ("b", "0")])
            + el("wp:docPr", [("id", String(drawingID)), ("name", "Picture \(drawingID)"),
                              ("descr", alt)])
            + el("wp:cNvGraphicFramePr", [],
                 el("a:graphicFrameLocks", [("xmlns:a", OOXMLNamespace.a), ("noChangeAspect", "1")]))
            + el("a:graphic", [("xmlns:a", OOXMLNamespace.a)],
                 el("a:graphicData", [("uri", OOXMLNamespace.pic)], picture)))

        return el("w:r", [], el("w:drawing", [], inline))
    }

    /// The bytes for an image `src`: what the caller resolved, or the payload of a `data:` URL,
    /// which needs no resolving because it is already the picture.
    private static func imageData(for src: String, context: WriteContext) -> Data? {
        if let supplied = context.images[src] { return supplied }
        guard src.hasPrefix("data:"), let comma = src.firstIndex(of: ","),
              src[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(src[src.index(after: comma)...]))
    }
}

// MARK: - Block content

extension DocxWriter {

    /// Where a paragraph sits in a list, when it sits in one.
    struct ListPosition {
        let numID: Int
        let level: Int
    }

    /// One block node as the docx elements that mean it.
    static func blockXML(_ node: DocNode, context: WriteContext,
                         list: ListPosition? = nil) -> [String] {
        switch node.type {
        case "paragraph":
            return [paragraphXML(
                // Inside a list the indentation belongs to the numbering level, which already sets
                // `w:ind` for it. Writing our own on top would override it — a level-2 item
                // indented back to where level 1 sits — so the level wins. The reader declines to
                // read `w:ind` off a numbered paragraph for the same reason, from the other side.
                properties: paragraphPropertiesXML(node, list: list, indented: list == nil),
                content: inlineXML(node.children, context: context))]

        case "heading":
            let level = node.attr("level")?.intValue ?? 1
            let text = node.plainText
            // A bookmark on every heading is what makes REF cross-references resolvable in Word;
            // `bookmark(for:)` hands out the same name to the reference that points at it.
            let name = context.bookmark(for: text)
            let bookmarkID = context.nextBookmark()
            let content = el("w:bookmarkStart", [("w:id", String(bookmarkID)), ("w:name", name)])
                + inlineXML(node.children, context: context)
                + el("w:bookmarkEnd", [("w:id", String(bookmarkID))])
            return [paragraphXML(
                properties: paragraphPropertiesXML(node, style: DocxMapping.headingStyleID(level)),
                content: content)]

        case "bulletList", "orderedList":
            return listXML(node, context: context)

        case "blockquote":
            // OOXML has no quote element; a quote is paragraphs carrying the quote style, which is
            // where the left rule and the base indent come from. Only paragraphs take it — a list
            // inside a quote is still a list, and putting a paragraph style on it would lose the
            // numbering.
            return node.children.flatMap { child -> [String] in
                guard child.type == "paragraph" else { return blockXML(child, context: context) }
                return [paragraphXML(
                    properties: paragraphPropertiesXML(child, style: DocxMapping.quoteStyleID),
                    content: inlineXML(child.children, context: context))]
            }

        case "codeBlock":
            // The text goes out verbatim, newlines included, in one run. Word draws a line break as
            // a space, which is a display loss; splitting it into `w:br` elements would be a *data*
            // loss the moment another Neutrino client read it back, since a break carries no text.
            return [paragraphXML(
                properties: paragraphPropertiesXML(node, style: DocxMapping.codeBlockStyleID),
                content: runXML(RunStyle(), textEl(node.plainText)))]

        case "sheetEmbed", "diagramEmbed":
            // Both are block nodes in the editor's schema, so the placeholder gets a paragraph of
            // its own — the reader replaces that paragraph rather than its contents, which is what
            // keeps a block node out of an inline position on the way back.
            return [paragraphXML(properties: "", content: embedXML(node, context: context))]

        case "horizontalRule":
            let border = el("w:pBdr", [], el("w:bottom", [("w:val", "single"), ("w:sz", "6"),
                                                          ("w:space", "1"), ("w:color", "auto")]))
            return [paragraphXML(properties: el("w:pPr", [], border), content: "")]

        case "sectionBreak", "pageBreak":
            return [paragraphXML(properties: "",
                                 content: el("w:r", [], el("w:br", [("w:type", "page")])))]

        case "tableOfContents":
            return [tableOfContentsXML()]

        case "columnLayout":
            // CSS columns are a section-level concept in OOXML. Writing them as a real continuous
            // section (`w:cols`) means splitting the body into sections, which is the right mapping
            // and the one to move to; until then the children are written in order and the node's
            // shape — column count and how many blocks it covered — is recorded in the extras,
            // which is what the reader regroups from.
            let blocks = node.children.flatMap { blockXML($0, context: context) }
            context.columnLayouts.append((columns: node.attr("columns")?.intValue ?? 2,
                                          blockCount: blocks.count))
            return blocks

        case "table":
            return [tableXML(node, context: context)]

        case "image":
            return [paragraphXML(properties: "", content: imageXML(node, context: context))]

        default:
            // Unknown block: keep its text rather than dropping the node.
            return [paragraphXML(properties: "",
                                 content: inlineXML(node.children, context: context))]
        }
    }

    static func paragraphXML(properties: String, content: String) -> String {
        el("w:p", [], properties + content)
    }

    /// `w:pPr`, with its children in schema order.
    static func paragraphPropertiesXML(_ node: DocNode, style: String? = nil,
                                       list: ListPosition? = nil,
                                       indented: Bool = true) -> String {
        var out = ""
        if let style { out += valEl("w:pStyle", style) }
        if let list {
            out += el("w:numPr", [], valEl("w:ilvl", String(list.level))
                      + valEl("w:numId", String(list.numID)))
        }
        if indented, let level = node.attr("indent")?.intValue, level > 0 {
            let twips = DocxMapping.pxToTwip(Double(level) * DocxMapping.indentPxPerLevel)
            out += el("w:ind", [("w:left", String(twips))])
        }
        if let align = node.attr("textAlign")?.stringValue,
           let jc = DocxMapping.alignmentToOOXML[align] {
            out += valEl("w:jc", jc)
        }
        return out.isEmpty ? "" : el("w:pPr", [], out)
    }

    /// A list as paragraphs bound to a numbering definition.
    ///
    /// Each distinct list style gets its own `w:num`, because the glyph for a bullet and the format
    /// for an ordered list are properties of the numbering definition rather than of the paragraph.
    static func listXML(_ node: DocNode, context: WriteContext, level: Int = 0) -> [String] {
        let ordered = node.type == "orderedList"
        let styleType = node.attr("listStyleType")?.stringValue ?? (ordered ? "decimal" : "disc")
        let numID = context.numberingID(ordered: ordered, styleType: styleType)

        var out: [String] = []
        for item in node.children {
            for child in item.children {
                if child.type == "bulletList" || child.type == "orderedList" {
                    out += listXML(child, context: context, level: level + 1)
                } else {
                    out += blockXML(child, context: context,
                                    list: ListPosition(numID: numID, level: level))
                }
            }
        }
        return out
    }

    /// A real TOC field: Word offers to update it, and it comes back as this node rather than as the
    /// frozen list of headings it happened to show.
    static func tableOfContentsXML() -> String {
        let properties = el("w:sdtPr", [],
            valEl("w:alias", "Table of Contents")
            + el("w:docPartObj", [], valEl("w:docPartGallery", "Table of Contents")
                 + el("w:docPartUnique")))
        let field = el("w:p", [],
            el("w:r", [], el("w:fldChar", [("w:fldCharType", "begin"), ("w:dirty", "true")]))
            + el("w:r", [], "<w:instrText xml:space=\"preserve\">TOC \\o &quot;1-6&quot; \\h</w:instrText>")
            + el("w:r", [], el("w:fldChar", [("w:fldCharType", "separate")]))
            + el("w:r", [], textEl("Right-click and update this table of contents."))
            + el("w:r", [], el("w:fldChar", [("w:fldCharType", "end")])))
        return el("w:sdt", [], properties + el("w:sdtContent", [], field))
    }

    static func tableXML(_ node: DocNode, context: WriteContext) -> String {
        let properties = el("w:tblPr", [],
            el("w:tblW", [("w:w", "5000"), ("w:type", "pct")])
            + el("w:tblLayout", [("w:type", "autofit")]))

        let rows = node.children.map { row -> String in
            let cells = row.children.map { cell in tableCellXML(cell, context: context) }.joined()
            return el("w:tr", [], cells)
        }.joined()

        // `w:tblGrid` is required, and its column count is the widest row's: a table whose grid is
        // narrower than a row has cells Word cannot place.
        let columns = node.children.map { $0.children.count }.max() ?? 1
        let grid = el("w:tblGrid", [],
                      String(repeating: el("w:gridCol"), count: max(1, columns)))
        return el("w:tbl", [], properties + grid + rows)
    }

    private static func tableCellXML(_ cell: DocNode, context: WriteContext) -> String {
        var properties = ""

        if let widths = cell.attr("colwidth")?.arrayValue,
           let first = widths.first?.doubleValue, first > 0 {
            properties += el("w:tcW", [("w:w", String(DocxMapping.pxToTwip(first))), ("w:type", "dxa")])
        }
        if let colspan = cell.attr("colspan")?.intValue, colspan > 1 {
            properties += valEl("w:gridSpan", String(colspan))
        }
        if let rowspan = cell.attr("rowspan")?.intValue, rowspan > 1 {
            properties += valEl("w:vMerge", "restart")
        }

        let borderColor = DocxMapping.normalizeColor(cell.attr("borderColor")?.stringValue)
        let borderWidth = cell.attr("borderWidth").flatMap { value -> Double? in
            guard let text = value.text else { return nil }
            return Double(text.replacingOccurrences(of: "px", with: ""))
        }
        if !borderColor.isEmpty || borderWidth != nil {
            let size = String(Int(((borderWidth ?? 1) * 8).rounded()))
            let color = DocxMapping.hexToOOXML(borderColor.isEmpty ? "#000000" : borderColor)
            let edges = ["w:top", "w:left", "w:bottom", "w:right"].map {
                el($0, [("w:val", "single"), ("w:sz", size), ("w:space", "0"), ("w:color", color)])
            }.joined()
            properties += el("w:tcBorders", [], edges)
        }

        let background = DocxMapping.normalizeColor(cell.attr("backgroundColor")?.stringValue)
        if !background.isEmpty {
            properties += el("w:shd", [("w:val", "clear"), ("w:color", "auto"),
                                       ("w:fill", DocxMapping.hexToOOXML(background))])
        }

        var content = cell.children.flatMap { blockXML($0, context: context) }.joined()
        // A cell must hold at least one block-level element, or Word declares the file corrupt.
        if content.isEmpty { content = el("w:p") }
        return el("w:tc", [], (properties.isEmpty ? "" : el("w:tcPr", [], properties)) + content)
    }
}
