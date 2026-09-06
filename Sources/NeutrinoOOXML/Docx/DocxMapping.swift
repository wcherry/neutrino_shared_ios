import Foundation

// MARK: - DocxMapping

/// The one place Neutrino's document model and OOXML are mapped to each other.
///
/// ``DocxWriter`` and ``DocxReader`` both read from here and neither hard-codes a correspondence of
/// its own. That is the point: a writer and a parser maintained independently drift, and drift in
/// this pair is silent — the document still opens, it has just quietly lost its margins. A shared
/// table plus the round-trip tests in `DocxRoundTripTests` turns "lossless" into something that
/// stays true rather than something that was true once.
///
/// This is the Swift half of `web/apps/web/src/lib/ooxml/docx/mapping.ts`. The two are one wire
/// format: a document written on a phone is opened on the web and the other way round, so a change
/// to either belongs in both.
///
/// ## Units
///
/// OOXML measures in twips (1/20 pt, so 1440 to the inch), half-points for font size, and EMUs
/// (914400 to the inch) for anything in a drawing. The editor measures in points for page setup and
/// CSS pixels for everything else. Every conversion lives here so no call site invents its own
/// factor.
///
/// ## What OOXML cannot hold
///
/// Four things in the model have no OOXML equivalent, and they are all the same shape — a live
/// pointer at another Drive file, which no interchange format models: `neutrino-drive:` image
/// references, sheet embeds, diagram embeds, and the `docTheme` preset name. A handful of
/// presentational attributes (image shadow/filter/caption, cross-reference target text) have no home
/// either. Those go in ``extrasPart``.
public enum DocxMapping {

    // MARK: - Units

    /// Points to twips. Page setup is in points; OOXML wants twentieths of one.
    public static func ptToTwip(_ pt: Double) -> Int { Int((pt * 20).rounded()) }
    public static func twipToPt(_ twip: Double) -> Double { twip / 20 }

    /// CSS pixels (96dpi) to twips. 1px = 0.75pt = 15 twips.
    public static func pxToTwip(_ px: Double) -> Int { Int((px * 15).rounded()) }
    public static func twipToPx(_ twip: Double) -> Double { twip / 15 }

    /// CSS pixels to EMUs, for image extents. 1px = 9525 EMU.
    public static func pxToEmu(_ px: Double) -> Int { Int((px * 9525).rounded()) }
    public static func emuToPx(_ emu: Double) -> Double { emu / 9525 }

    /// One indent level in the editor is 24px of left margin.
    public static let indentPxPerLevel: Double = 24

    // MARK: - Page size

    /// Portrait dimensions in twips. Landscape swaps them.
    public static let pageSizeTwips: [String: (w: Int, h: Int)] = [
        "letter":    (12240, 15840),
        "legal":     (12240, 20160),
        "tabloid":   (15840, 24480),
        "executive": (10440, 15120),
        "a3":        (16838, 23814),
        "a4":        (11906, 16838),
        "a5":        (8391, 11906),
    ]

    /// The page setup a document with none stored lays out to. The client's own default: page setup
    /// lives in the body's `_meta`, so there is no server copy to keep in step with.
    public static let defaultPageSetup: [String: DocValue] = [
        "marginTop": .int(72), "marginBottom": .int(72),
        "marginLeft": .int(72), "marginRight": .int(72),
        "orientation": .string("portrait"), "pageSize": .string("letter"),
    ]

    /// The page size whose portrait dimensions match `w`×`h`, or nil.
    ///
    /// Matched with a tolerance because a document that has been through Word comes back with its
    /// A4 height as 16840 rather than 16838 — Word rounds through whole millimetres. Falling through
    /// to `letter` on a two-twip difference would resize every A4 document that visited Word.
    public static func pageSize(fromTwips w: Int, _ h: Int) -> String? {
        let (pw, ph) = w > h ? (h, w) : (w, h)
        // Sorted so the answer cannot depend on dictionary order when two sizes are within
        // tolerance of the same page — they are not, but the ordering is free.
        for name in pageSizeTwips.keys.sorted() {
            guard let dimensions = pageSizeTwips[name] else { continue }
            if abs(dimensions.w - pw) <= 20 && abs(dimensions.h - ph) <= 20 { return name }
        }
        return nil
    }

    // MARK: - Enumerations

    /// Tiptap `textAlign` → `w:jc/@w:val`.
    public static let alignmentToOOXML: [String: String] = [
        "left": "left", "center": "center", "right": "right", "justify": "both",
    ]

    public static let ooxmlToAlignment: [String: String] = [
        "left": "left", "start": "left", "center": "center", "right": "right",
        "end": "right", "both": "justify", "distribute": "justify",
    ]

    /// CSS `list-style-type` → the glyph a bullet level shows.
    ///
    /// `disc`/`circle`/`square` are all `bullet` in OOXML — the shape lives in the level's
    /// `w:lvlText` glyph instead, which is why the bullet character is carried alongside.
    public static let bulletGlyph: [String: String] = [
        "disc": "\u{25CF}", "circle": "\u{25CB}", "square": "\u{25A0}",
    ]

    public static let glyphToBullet: [String: String] = [
        "\u{25CF}": "disc", "\u{25CB}": "circle", "\u{25A0}": "square",
        "\u{2022}": "disc", "o": "circle", "\u{25AA}": "square",
    ]

    public static let orderedStyleToNumFmt: [String: String] = [
        "decimal": "decimal",
        "lower-alpha": "lowerLetter",
        "upper-alpha": "upperLetter",
        "lower-roman": "lowerRoman",
        "upper-roman": "upperRoman",
    ]

    public static let numFmtToOrderedStyle: [String: String] = {
        var out: [String: String] = [:]
        for (style, fmt) in orderedStyleToNumFmt { out[fmt] = style }
        return out
    }()

    /// Highlight colours → `w:highlight/@w:val`.
    ///
    /// OOXML's highlight is a fixed sixteen-colour enumeration, not a free colour, so an arbitrary
    /// highlight has to be matched to a name. Anything that does not match is written as a shaded
    /// run (`w:shd`) instead, which is a free colour — see ``DocxWriter``.
    public static let highlightNames: [String: String] = [
        "#ffff00": "yellow", "#00ff00": "green", "#00ffff": "cyan", "#ff00ff": "magenta",
        "#0000ff": "blue", "#ff0000": "red", "#000080": "darkBlue", "#008080": "darkCyan",
        "#008000": "darkGreen", "#800080": "darkMagenta", "#800000": "darkRed",
        "#808000": "darkYellow", "#808080": "darkGray", "#c0c0c0": "lightGray",
        "#000000": "black", "#ffffff": "white",
    ]

    public static let nameToHighlight: [String: String] = {
        var out: [String: String] = [:]
        for (hex, name) in highlightNames { out[name] = hex }
        return out
    }()

    // MARK: - Field codes

    /// `docField` node codes → Word field instructions.
    ///
    /// These are real Word fields (`w:fldSimple`), not text: a `{{page}}` written as `PAGE` updates
    /// itself in Word, and comes back as a field rather than as the number it happened to show when
    /// it was exported.
    ///
    /// The codes with no Word equivalent (`company`, `manager`, and any custom `{{whatever}}`) go
    /// out as `DOCPROPERTY <name>`, which is how Word reads a custom document property — so they
    /// resolve there too.
    public static let fieldToInstruction: [String: String] = [
        "page": "PAGE", "pages": "NUMPAGES", "title": "TITLE", "date": "DATE", "time": "TIME",
        "author": "AUTHOR", "subject": "SUBJECT", "keywords": "KEYWORDS", "filename": "FILENAME",
    ]

    public static let instructionToField: [String: String] = {
        var out: [String: String] = [:]
        for (code, instruction) in fieldToInstruction { out[instruction] = code }
        return out
    }()

    /// The `DOCPROPERTY` name for a code with no built-in Word field.
    public static func docPropertyInstruction(_ code: String) -> String { "DOCPROPERTY \(code)" }

    // MARK: - The extras part

    /// Where the handful of model attributes OOXML cannot express are stored.
    ///
    /// A custom XML part rather than a loose file at the package root: Word keeps `customXml/` parts
    /// across an edit-and-save, and discards parts it does not recognise. So a document that goes
    /// through Word comes back with its extras intact.
    public static let extrasPart = "customXml/item1.xml"
    public static let extrasPropsPart = "customXml/itemProps1.xml"
    public static let extrasNamespace = "https://neutrino.app/ns/doc-extras"

    /// Placeholder kinds that stood in for a *block* node rather than an inline one.
    ///
    /// A block placeholder is written as a paragraph of its own, so the reader has to replace that
    /// whole paragraph; an inline one replaces a run inside a paragraph that has other content.
    /// Getting it backwards puts a block node in an inline position, which the editor's schema then
    /// discards.
    public static let blockPlaceholderKinds: Set<String> = ["sheetEmbed", "diagramEmbed"]

    /// The character style every placeholder run carries.
    ///
    /// The placeholder has to be findable again, and looking for italic text in square brackets is
    /// not a way of finding it: an italic run written next to one has the same properties, so the
    /// two are one run by the time the package is read and the match fails — taking every *later*
    /// placeholder with it, since they are restored in order. A style of its own gives the run a
    /// `w:rPr` no ordinary italic shares.
    public static let placeholderStyleID = "NeutrinoPlaceholder"

    /// The run style id used for the `code` mark, defined in `styles.xml` by the writer.
    public static let codeStyleID = "NeutrinoCode"
    /// The paragraph style id used for `codeBlock`.
    public static let codeBlockStyleID = "NeutrinoCodeBlock"
    /// The paragraph style id used for `blockquote`.
    public static let quoteStyleID = "NeutrinoQuote"

    // MARK: - Marks

    /// The marks that are a plain on/off toggle in `w:rPr`, both ways.
    ///
    /// `code` maps to a run *style* rather than a toggle, and `link`, `textStyle`, `highlight`,
    /// `crossRef` and the tracked-change pair all carry values, so none of them are here — the
    /// writer and the reader handle those explicitly.
    public static let toggleMarks: [(mark: String, element: String)] = [
        ("bold", "b"), ("italic", "i"), ("underline", "u"), ("strike", "strike"),
    ]

    public static let ooxmlToToggleMark: [String: String] = [
        "b": "bold", "i": "italic", "u": "underline", "strike": "strike",
    ]

    // MARK: - Heading levels

    /// `heading` level → the `Heading1`…`Heading6` paragraph style id.
    public static func headingStyleID(_ level: Int) -> String { "Heading\(min(6, max(1, level)))" }

    /// The level a paragraph style id denotes, or nil when it is not a heading.
    public static func headingLevel(fromStyle styleID: String?) -> Int? {
        guard let styleID else { return nil }
        let normalized = styleID.replacingOccurrences(of: " ", with: "").lowercased()
        guard normalized.hasPrefix("heading"), normalized.count == "heading".count + 1,
              let last = normalized.last, let level = Int(String(last)), (1...6).contains(level) else {
            return nil
        }
        return level
    }

    // MARK: - Colour

    private static let namedColors: [String: String] = [
        "black": "#000000", "white": "#ffffff", "red": "#ff0000", "green": "#008000",
        "blue": "#0000ff", "yellow": "#ffff00", "cyan": "#00ffff", "magenta": "#ff00ff",
        "gray": "#808080", "grey": "#808080", "transparent": "",
    ]

    /// A CSS colour as `#rrggbb`, or `""` when it is not a colour at all.
    ///
    /// Accepts the three spellings the editor can produce — hex (3 or 6 digit), `rgb()`, and the
    /// handful of names a paste can bring in — because OOXML has only one, and a run whose colour
    /// did not normalise would be written without one at all.
    public static func normalizeColor(_ input: String?) -> String {
        guard let input, !input.isEmpty else { return "" }
        let value = input.trimmingCharacters(in: .whitespaces).lowercased()
        if let named = namedColors[value] { return named }

        if value.hasPrefix("#") {
            let digits = String(value.dropFirst())
            let isHex = digits.allSatisfy { $0.isHexDigit }
            if isHex, digits.count == 6 { return "#\(digits)" }
            if isHex, digits.count == 3 {
                return "#" + digits.map { String(repeating: String($0), count: 2) }.joined()
            }
            return ""
        }

        if value.hasPrefix("rgb") {
            let numbers = value
                .drop { $0 != "(" }
                .dropFirst()
                .prefix { $0 != ")" }
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count >= 3 else { return "" }
            return "#" + numbers.prefix(3).map { String(format: "%02x", min(255, max(0, $0))) }.joined()
        }
        return ""
    }

    /// `#rrggbb` as the bare `RRGGBB` OOXML wants in `w:val`.
    public static func hexToOOXML(_ hex: String) -> String {
        hex.replacingOccurrences(of: "#", with: "").uppercased()
    }

    /// `RRGGBB` back to `#rrggbb`. `auto` means "the theme decides" and has no value.
    public static func ooxmlToHex(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.lowercased() != "auto" else { return "" }
        return "#" + value.replacingOccurrences(of: "#", with: "").lowercased()
    }

    // MARK: - Font size

    /// A CSS font size as OOXML half-points, or nil when it cannot be read.
    ///
    /// `px` is converted at the CSS ratio (1px = 0.75pt) rather than treated as points — a 16px run
    /// written as 16pt is a third larger than it was on screen.
    public static func fontSizeToHalfPoints(_ input: String?) -> Int? {
        guard let input else { return nil }
        let value = input.trimmingCharacters(in: .whitespaces)
        let isPx = value.hasSuffix("px")
        let number = value.hasSuffix("px") || value.hasSuffix("pt") ? String(value.dropLast(2)) : value
        guard let points = Double(number), points.isFinite else { return nil }
        return Int(((isPx ? points * 0.75 : points) * 2).rounded())
    }

    /// Half-points back to the `pt` string the editor stores.
    public static func halfPointsToFontSize(_ half: Int) -> String {
        half % 2 == 0 ? "\(half / 2)pt" : "\(Double(half) / 2)pt"
    }
}
