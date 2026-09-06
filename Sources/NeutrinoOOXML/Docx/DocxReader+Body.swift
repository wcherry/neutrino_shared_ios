import Foundation

// MARK: - Sentinels

/// Node types that exist only between parsing and regrouping.
///
/// A page break and a placeholder are both discovered inside a run and both mean something about the
/// paragraph that holds them, which is a decision that cannot be made until the paragraph is
/// complete. They never reach the model: ``DocxReader`` resolves every one of them.
enum DocxSentinel {
    static let pageBreak = "__pageBreak"
    static let placeholder = "__placeholder"
}

// MARK: - Runs and marks

extension DocxReader {

    /// `w:rPr` → the marks that produced it.
    static func marks(fromRunProperties rPr: XMLElement?) -> [DocMark] {
        guard let rPr else { return [] }
        var marks: [DocMark] = []

        for (element, mark) in [("b", "bold"), ("i", "italic"), ("u", "underline"),
                                ("strike", "strike")] {
            guard let node = rPr.element(element) else { continue }
            if element == "u" {
                // `w:u` is not a toggle — it names an underline style, and `none` means off.
                if (node.val ?? "single") != "none" { marks.append(DocMark(type: mark)) }
                continue
            }
            if node.isToggleOn { marks.append(DocMark(type: mark)) }
        }

        switch rPr.element("vertAlign")?.val {
        case "superscript": marks.append(DocMark(type: "superscript"))
        case "subscript":   marks.append(DocMark(type: "subscript"))
        default:            break
        }

        if rPr.element("rStyle")?.val == DocxMapping.codeStyleID {
            marks.append(DocMark(type: "code"))
        }

        var textStyle: [String: DocValue] = [:]
        let color = DocxMapping.ooxmlToHex(rPr.element("color")?.val)
        if !color.isEmpty { textStyle["color"] = .string(color) }
        if let size = rPr.element("sz")?.val, let half = Int(size), half > 0 {
            textStyle["fontSize"] = .string(DocxMapping.halfPointsToFontSize(half))
        }
        if let fonts = rPr.element("rFonts"),
           let family = fonts.attribute("ascii", uri: OOXMLNamespace.w)
            ?? fonts.attribute("hAnsi", uri: OOXMLNamespace.w) {
            textStyle["fontFamily"] = .string(family)
        }
        if !textStyle.isEmpty { marks.append(DocMark(type: "textStyle", attrs: textStyle)) }

        // A highlight is either the closed enumeration or, for a colour outside it, run shading —
        // the writer picks whichever fits and both come back here.
        if let highlight = rPr.element("highlight")?.val, highlight != "none" {
            marks.append(DocMark(type: "highlight",
                                 attrs: ["color": .string(DocxMapping.nameToHighlight[highlight]
                                                          ?? highlight)]))
        } else {
            let fill = DocxMapping.ooxmlToHex(rPr.element("shd")?.attribute("fill",
                                                                            uri: OOXMLNamespace.w))
            if !fill.isEmpty, fill != "#ffffff" {
                marks.append(DocMark(type: "highlight", attrs: ["color": .string(fill)]))
            }
        }

        return marks
    }

    /// Inline children of a paragraph, in order.
    static func inline(in parent: XMLElement, context: ReadContext,
                       extraMarks: [DocMark] = []) -> [DocNode] {
        var out: [DocNode] = []

        func pushText(_ text: String, _ marks: [DocMark]) {
            guard !text.isEmpty else { return }
            // Adjacent runs with identical marks are one text node in the model, and Word splits
            // runs freely (a spell-check pass alone will do it). Without this, a round trip
            // fragments every paragraph a little more each time.
            if let last = out.last, last.type == "text", (last.marks ?? []) == marks {
                out[out.count - 1].text = (last.text ?? "") + text
                return
            }
            out.append(DocNode.text(text, marks: marks.isEmpty ? nil : marks))
        }

        for element in parent.children {
            switch element.localName {
            case "r":
                let rPr = element.element("rPr")
                let marks = self.marks(fromRunProperties: rPr) + extraMarks
                // A placeholder run is kept as a node of its own rather than as text, so it cannot
                // merge into an adjacent italic run and lose the shape the restore matches on.
                let isPlaceholder = rPr?.element("rStyle")?.val == DocxMapping.placeholderStyleID

                for child in element.children {
                    switch child.localName {
                    case "t", "delText":
                        if isPlaceholder {
                            out.append(DocNode(type: DocxSentinel.placeholder, text: child.textContent))
                        } else {
                            pushText(child.textContent, marks)
                        }
                    case "tab":
                        pushText("\t", marks)
                    case "br":
                        if child.attribute("type", uri: OOXMLNamespace.w) == "page" {
                            out.append(DocNode(type: DocxSentinel.pageBreak))
                        } else {
                            out.append(DocNode(type: "hardBreak"))
                        }
                    case "footnoteReference":
                        let id = child.attribute("id", uri: OOXMLNamespace.w) ?? ""
                        out.append(DocNode(type: "footnote",
                                           attrs: ["id": .string("fn-\(id)"),
                                                   "text": .string(context.footnotes[id] ?? "")]))
                    case "drawing":
                        out.append(image(from: child, context: context))
                    default:
                        break
                    }
                }

            case "hyperlink":
                let href: String
                if let relID = element.attribute("id", uri: OOXMLNamespace.r) {
                    href = context.rels[relID] ?? ""
                } else {
                    href = "#\(element.attribute("anchor", uri: OOXMLNamespace.w) ?? "")"
                }
                for var node in inline(in: element, context: context, extraMarks: extraMarks) {
                    if node.type == "text" {
                        node.marks = (node.marks ?? []) + [DocMark(type: "link",
                                                                   attrs: ["href": .string(href)])]
                    }
                    out.append(node)
                }

            case "ins", "del":
                let type = element.localName == "ins" ? "trackedInsertion" : "trackedDeletion"
                let author = element.attribute("author", uri: OOXMLNamespace.w)
                let mark = DocMark(type: type,
                                   attrs: ["author": author.map { DocValue.string($0) } ?? .null])
                out += inline(in: element, context: context, extraMarks: extraMarks + [mark])

            case "fldSimple":
                out.append(field(from: element, context: context))

            case "bookmarkStart", "bookmarkEnd", "proofErr":
                break

            default:
                // Something the mapping does not model — a content control, a smart tag. Its runs
                // are still content, so descend rather than drop it.
                if !element.children.isEmpty {
                    out += inline(in: element, context: context, extraMarks: extraMarks)
                }
            }
        }
        return out
    }

    /// A `w:fldSimple` back to what it came from.
    ///
    /// A `REF` field is a cross-reference: the mark goes back on the field's cached result, which
    /// the writer stores precisely so the text survives. Everything else is a `docField`.
    private static func field(from element: XMLElement, context: ReadContext) -> DocNode {
        let instruction = (element.attribute("instr", uri: OOXMLNamespace.w) ?? "")
            .trimmingCharacters(in: .whitespaces)
        let cached = inline(in: element, context: context).map { $0.text ?? "" }.joined()

        if instruction.hasPrefix("REF ") {
            let index = context.nextIndex("crossRef")
            let headingText = context.extras.crossRef(at: index) ?? ""
            return DocNode.text(cached, marks: [DocMark(type: "crossRef",
                                                        attrs: ["headingText": .string(headingText)])])
        }

        let index = context.nextIndex("docField")
        let showCode = context.extras.showsCode(fieldAt: index)
        if instruction.uppercased().hasPrefix("DOCPROPERTY ") {
            let name = instruction.dropFirst("DOCPROPERTY ".count).trimmingCharacters(in: .whitespaces)
            return DocNode(type: "docField", attrs: ["code": .string("custom"),
                                                     "arg": .string(name),
                                                     "showCode": .bool(showCode)])
        }
        let head = instruction.split(separator: " ").first.map(String.init) ?? instruction
        let code = DocxMapping.instructionToField[head] ?? "title"
        return DocNode(type: "docField", attrs: ["code": .string(code), "arg": .null,
                                                 "showCode": .bool(showCode)])
    }

    /// A `w:drawing` back to an image node, with its extras reapplied.
    private static func image(from element: XMLElement, context: ReadContext) -> DocNode {
        let index = context.nextIndex("image")
        let extra = context.extras.image(at: index)

        let relID = element.descendant("blip")?.attribute("embed", uri: OOXMLNamespace.r)
        let media = relID.flatMap { context.media[$0] }
        let cx = element.descendant("extent")?.attribute("cx")

        var attrs: [String: DocValue] = [
            // The Drive reference wins over the embedded bytes: it is what the editor stores, and
            // re-inlining a resolved image would turn a reference into a multi-megabyte data URL on
            // every open.
            "src": .string(extra?.driveRef ?? media ?? ""),
        ]
        if let cx, let emu = Double(cx) {
            attrs["width"] = .string(String(Int(DocxMapping.emuToPx(emu).rounded())))
        }
        // Alt text is a real OOXML property (`wp:docPr/@descr`), so it is read from the package
        // rather than from the extras — which means a picture described in Word arrives described.
        if let alt = element.descendant("docPr")?.attribute("descr"), !alt.isEmpty {
            attrs["alt"] = .string(alt)
        }
        if let shadow = extra?.shadow { attrs["shadow"] = .string(shadow) }
        if let filter = extra?.filter { attrs["imageFilter"] = .string(filter) }
        if let caption = extra?.caption { attrs["caption"] = .string(caption) }
        return DocNode(type: "image", attrs: attrs)
    }
}

// MARK: - Paragraphs and blocks

extension DocxReader {

    /// A block, with the list membership that decides how it is later regrouped.
    struct ParsedBlock {
        var node: DocNode
        /// Set when the paragraph belonged to a list.
        var list: (numID: String, level: Int)?
    }

    static func paragraph(from element: XMLElement, context: ReadContext) -> [ParsedBlock] {
        let pPr = element.element("pPr")
        let styleID = pPr?.element("pStyle")?.val
        let content = inline(in: element, context: context)

        // A paragraph whose only content is a page break is a section break node, not an empty
        // paragraph containing one.
        let breaks = content.filter { $0.type == DocxSentinel.pageBreak }
        if !breaks.isEmpty, breaks.count == content.count {
            return breaks.map { _ in ParsedBlock(node: DocNode(type: "sectionBreak")) }
        }
        let cleaned = content.filter { $0.type != DocxSentinel.pageBreak }

        // An empty paragraph carrying a bottom border is a horizontal rule — which is the only way
        // OOXML has of drawing one.
        if cleaned.isEmpty, pPr?.element("pBdr")?.element("bottom") != nil {
            return [ParsedBlock(node: DocNode(type: "horizontalRule"))]
        }

        var attrs: [String: DocValue] = [:]
        if let jc = pPr?.element("jc")?.val, let align = DocxMapping.ooxmlToAlignment[jc] {
            attrs["textAlign"] = .string(align)
        }

        let numPr = pPr?.element("numPr")
        // Indentation is not read off a numbered paragraph: there, `w:ind` is the numbering level's
        // own indentation, which Word restates on every list paragraph. Reading it would give every
        // second-level bullet in every Word document an `indent` of 2 on top of the nesting that
        // already says so.
        if numPr == nil,
           let left = pPr?.element("ind")?.attribute("left", uri: OOXMLNamespace.w),
           let twips = Double(left) {
            let level = Int((DocxMapping.twipToPx(twips) / DocxMapping.indentPxPerLevel).rounded())
            if level > 0 { attrs["indent"] = .int(level) }
        }

        if styleID == DocxMapping.codeBlockStyleID {
            let text = cleaned.map { $0.text ?? "" }.joined()
            return [ParsedBlock(node: DocNode(type: "codeBlock",
                                              content: text.isEmpty ? [] : [DocNode.text(text)]))]
        }
        if styleID == DocxMapping.quoteStyleID {
            let paragraph = DocNode(type: "paragraph", attrs: attrs.isEmpty ? nil : attrs,
                                    content: cleaned)
            return [ParsedBlock(node: DocNode(type: "blockquote", content: [paragraph]))]
        }

        let node: DocNode
        if let level = DocxMapping.headingLevel(fromStyle: styleID) {
            var headingAttrs = attrs
            headingAttrs["level"] = .int(level)
            node = DocNode(type: "heading", attrs: headingAttrs, content: cleaned)
        } else {
            // No attributes at all rather than an empty set: a plain paragraph is the node the
            // editor builds when somebody presses return, and one carrying `attrs: {}` compares
            // unequal to it — which the editor reads as an unsaved change it then uploads.
            node = DocNode(type: "paragraph", attrs: attrs.isEmpty ? nil : attrs, content: cleaned)
        }

        let list = numPr.map { (numID: $0.element("numId")?.val ?? "",
                                level: Int($0.element("ilvl")?.val ?? "0") ?? 0) }
        return [ParsedBlock(node: node, list: list)]
    }

    static func table(from element: XMLElement, context: ReadContext) -> DocNode {
        let rows = element.elements("tr").map { row -> DocNode in
            let cells = row.elements("tc").map { cell -> DocNode in
                let tcPr = cell.element("tcPr")
                // Every attribute the cell node declares, present whether or not the package said
                // anything about it. The editor's cell defaults all three presentational ones to
                // `null` and serialises defaults, so a cell with no fill is `backgroundColor: null`
                // in the model — omitting the key would make a plain cell read back as a different
                // node from the one that was written.
                var attrs: [String: DocValue] = [
                    "colspan": .int(Int(tcPr?.element("gridSpan")?.val ?? "1") ?? 1),
                    "rowspan": .int(1),
                    "colwidth": .null,
                    "backgroundColor": .null,
                    "borderColor": .null,
                    "borderWidth": .null,
                ]

                if let width = tcPr?.element("tcW"),
                   width.attribute("type", uri: OOXMLNamespace.w) == "dxa",
                   let twips = Double(width.attribute("w", uri: OOXMLNamespace.w) ?? "") {
                    attrs["colwidth"] = .array([.int(Int(DocxMapping.twipToPx(twips).rounded()))])
                }
                let fill = DocxMapping.ooxmlToHex(tcPr?.element("shd")?.attribute("fill",
                                                                                   uri: OOXMLNamespace.w))
                if !fill.isEmpty { attrs["backgroundColor"] = .string(fill) }
                if let top = tcPr?.element("tcBorders")?.element("top") {
                    let color = DocxMapping.ooxmlToHex(top.attribute("color", uri: OOXMLNamespace.w))
                    if !color.isEmpty { attrs["borderColor"] = .string(color) }
                    if let size = Double(top.attribute("sz", uri: OOXMLNamespace.w) ?? "") {
                        let px = size / 8
                        attrs["borderWidth"] = .string(px == px.rounded()
                                                       ? "\(Int(px))px" : "\(px)px")
                    }
                }
                return DocNode(type: "tableCell", attrs: attrs,
                               content: blocks(in: cell, context: context))
            }
            return DocNode(type: "tableRow", content: cells)
        }
        return DocNode(type: "table", content: rows)
    }

    /// Every block child of `parent`, with lists regrouped and extras reapplied.
    static func blocks(in parent: XMLElement, context: ReadContext) -> [DocNode] {
        var parsed: [ParsedBlock] = []

        for element in parent.children {
            switch element.localName {
            case "p":
                parsed += paragraph(from: element, context: context)
            case "tbl":
                parsed.append(ParsedBlock(node: table(from: element, context: context)))
            case "sdt":
                // The only structured document tag the writer emits is the table of contents;
                // anything else is content some other editor wrapped, and its blocks belong in the
                // document either way.
                if element.element("sdtPr")?.element("alias")?.val == "Table of Contents" {
                    parsed.append(ParsedBlock(node: DocNode(type: "tableOfContents")))
                } else if let content = element.element("sdtContent") {
                    parsed += blocks(in: content, context: context).map { ParsedBlock(node: $0) }
                }
            default:
                break
            }
        }

        return groupColumnLayouts(mergeQuotes(groupLists(parsed, context: context)), context: context)
    }

    /// Consecutive quote paragraphs folded into one blockquote.
    ///
    /// Same shape of problem as lists: OOXML has no quote element, only paragraphs carrying the
    /// quote style, so a three-paragraph quote arrives as three one-paragraph quotes. Two
    /// blockquotes written back to back in the editor are indistinguishable from one with two
    /// paragraphs by the time they are in the package, so merging is the only answer either way —
    /// and it is the one that keeps a quote from splintering a little more with every save.
    static func mergeQuotes(_ blocks: [DocNode]) -> [DocNode] {
        var out: [DocNode] = []
        for node in blocks {
            if node.type == "blockquote", let last = out.last, last.type == "blockquote" {
                out[out.count - 1].content = last.children + node.children
                continue
            }
            out.append(node)
        }
        return out
    }

    /// Consecutive list paragraphs folded back into `bulletList`/`orderedList`.
    ///
    /// OOXML has no list element — a list is a run of paragraphs that happen to share a numbering id
    /// — so this is where the shape the editor stores gets rebuilt, including nesting, which is
    /// carried by `w:ilvl`.
    ///
    /// A sub-list is free to be a different *kind* of list from the one it sits in: a numbered list
    /// under a bulleted one is ordinary, and each gets its own numbering definition and so its own
    /// `w:numId`. So the run cannot end at the first change of `w:numId` — a paragraph deeper than
    /// the run's own level continues it whatever numbering it uses, and only a paragraph back at
    /// that level under different numbering starts a new list.
    static func groupLists(_ blocks: [ParsedBlock], context: ReadContext) -> [DocNode] {
        var out: [DocNode] = []
        var index = 0
        while index < blocks.count {
            guard let list = blocks[index].list else {
                out.append(blocks[index].node)
                index += 1
                continue
            }
            let baseLevel = list.level
            let numID = list.numID
            var run: [ParsedBlock] = []
            while index < blocks.count, let current = blocks[index].list {
                if current.level <= baseLevel && current.numID != numID { break }
                run.append(blocks[index])
                index += 1
            }
            out += buildLists(run, level: baseLevel, context: context)
        }
        return out
    }

    /// The lists a run of list paragraphs at `level` or deeper describes.
    ///
    /// Plural because one run can hold several sibling lists — a bulleted list followed by a
    /// numbered one, both nested inside the same item — and because returning them separately is
    /// what lets each take its style from its own numbering definition rather than inheriting the
    /// outermost one.
    static func buildLists(_ run: [ParsedBlock], level: Int, context: ReadContext) -> [DocNode] {
        var out: [DocNode] = []
        var index = 0

        while index < run.count {
            let numID = run[index].list?.numID ?? ""
            let style = context.numbering[numID]
            var items: [DocNode] = []

            while index < run.count, let current = run[index].list,
                  current.numID == numID, current.level <= level {
                var children = [run[index].node]
                index += 1
                // Anything deeper than this level belongs inside the item just added.
                var nested: [ParsedBlock] = []
                while index < run.count, (run[index].list?.level ?? 0) > level {
                    nested.append(run[index])
                    index += 1
                }
                if !nested.isEmpty { children += buildLists(nested, level: level + 1, context: context) }
                items.append(DocNode(type: "listItem", content: children))
            }

            if items.isEmpty {
                // Only reachable from a document whose levels do not descend — a `w:ilvl` of 3 with
                // no 2 above it. Taking the paragraph as an item of its own keeps it in the document
                // and, more to the point, guarantees `index` moves.
                items.append(DocNode(type: "listItem", content: [run[index].node]))
                index += 1
            }

            let ordered = style?.ordered ?? false
            out.append(DocNode(type: ordered ? "orderedList" : "bulletList",
                               attrs: ["listStyleType": .string(style?.styleType
                                                                ?? (ordered ? "decimal" : "disc"))],
                               content: items))
        }
        return out
    }

    /// Column layouts rebuilt from the extras.
    ///
    /// The writer records how many blocks each layout covered because OOXML models columns as a
    /// section property, not as a container. A document edited elsewhere will not match, and then
    /// the blocks stay where they are, which is the right way for this to fail.
    static func groupColumnLayouts(_ blocks: [DocNode], context: ReadContext) -> [DocNode] {
        guard let layouts = context.extras.columnLayouts, !layouts.isEmpty else { return blocks }

        var out: [DocNode] = []
        var index = 0
        var layout = 0
        while index < blocks.count {
            if layout < layouts.count {
                let spec = layouts[layout]
                if spec.blockCount > 0, index + spec.blockCount <= blocks.count {
                    out.append(DocNode(type: "columnLayout",
                                       attrs: ["columns": .int(spec.columns)],
                                       content: Array(blocks[index..<(index + spec.blockCount)])))
                    index += spec.blockCount
                    layout += 1
                    continue
                }
            }
            out.append(blocks[index])
            index += 1
        }
        return out
    }

    /// Placeholder runs turned back into the nodes they stood in for.
    ///
    /// The writer emits `[Title]` in the placeholder character style for the three nodes OOXML
    /// cannot carry — a sheet embed, a diagram embed, and an image whose Drive reference could not
    /// be resolved to bytes. All three go into one ordered list in the extras, and are matched back
    /// in document order, because the placeholders are indistinguishable from each other in the
    /// document itself.
    ///
    /// A document edited elsewhere will have placeholders that no longer line up. Whatever is left
    /// over stays as the italic text it looks like, which is legible and wrong in an obvious way —
    /// better than restoring an embed onto a paragraph that has nothing to do with it.
    static func restorePlaceholders(_ nodes: inout [DocNode], extras: DocxExtras, cursor: inout Int) {
        for index in nodes.indices {
            let node = nodes[index]
            let entry = extras.placeholder(at: cursor)

            // A block placeholder was given a paragraph to itself, so the paragraph is what stands
            // in for the node and the paragraph is what gets replaced.
            if let entry, DocxMapping.blockPlaceholderKinds.contains(entry.kind),
               node.type == "paragraph", node.children.count == 1,
               node.children[0].type == DocxSentinel.placeholder {
                nodes[index] = DocNode(type: entry.kind, attrs: entry.attrs)
                cursor += 1
                continue
            }

            if node.type == DocxSentinel.placeholder {
                if let entry {
                    nodes[index] = DocNode(type: entry.kind, attrs: entry.attrs)
                    cursor += 1
                } else {
                    // No extras entry to match: the run stays as what it reads as.
                    nodes[index] = DocNode.text(node.text ?? "", marks: [DocMark(type: "italic")])
                }
                continue
            }

            if var content = nodes[index].content {
                restorePlaceholders(&content, extras: extras, cursor: &cursor)
                nodes[index].content = content
            }
        }
    }
}
