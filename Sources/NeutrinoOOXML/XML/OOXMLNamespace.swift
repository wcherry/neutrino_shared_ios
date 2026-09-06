import Foundation

// MARK: - OOXMLNamespace

/// The namespace URIs an OOXML package is written in.
///
/// Prefixes vary between producers; these do not. Everything that reads an attribute out of a
/// package resolves it against one of these rather than against the `w:`/`r:` spelling Word happens
/// to use — see ``XMLElement/attribute(_:uri:)``.
public enum OOXMLNamespace {
    /// WordprocessingML — the body, its paragraphs, runs and properties.
    public static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    /// Relationships, as referenced *from* a part (`r:id`, `r:embed`).
    public static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    /// The relationship parts themselves (`_rels/*.rels`).
    public static let packageRels = "http://schemas.openxmlformats.org/package/2006/relationships"
    /// DrawingML — pictures.
    public static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    /// The drawing wrapper that positions a picture in a word-processing document.
    public static let wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
    public static let pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
    public static let contentTypes = "http://schemas.openxmlformats.org/package/2006/content-types"
    /// Dublin Core and the OPC property parts, for `docProps/core.xml`.
    public static let dc = "http://purl.org/dc/elements/1.1/"
    public static let cp = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
    public static let dcterms = "http://purl.org/dc/terms/"
    public static let xsi = "http://www.w3.org/2001/XMLSchema-instance"
    /// `docProps/custom.xml`, and the variant types its values are written as.
    public static let customProps =
        "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
    public static let customProperties =
        "http://schemas.openxmlformats.org/officeDocument/2006/custom-properties"
    public static let vt = "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"
    /// The custom XML store Word preserves across an edit — where the extras part lives.
    public static let customXml = "http://schemas.openxmlformats.org/officeDocument/2006/customXml"
}

// MARK: - OOXMLRelationship

/// Relationship types, which is how a package says what a part *is* rather than where it sits.
public enum OOXMLRelationship {
    private static let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    public static let officeDocument = "\(base)/officeDocument"
    public static let styles = "\(base)/styles"
    public static let numbering = "\(base)/numbering"
    public static let settings = "\(base)/settings"
    public static let footnotes = "\(base)/footnotes"
    public static let header = "\(base)/header"
    public static let footer = "\(base)/footer"
    public static let image = "\(base)/image"
    public static let hyperlink = "\(base)/hyperlink"
    public static let customXml = "\(base)/customXml"
    public static let customXmlProps = "\(base)/customXmlProps"
    public static let coreProperties =
        "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
    public static let extendedProperties = "\(base)/extended-properties"
    public static let customProperties = "\(base)/custom-properties"
}

// MARK: - OOXMLPackage

/// The part paths a `.docx` is made of.
public enum OOXMLPackage {
    public static let contentTypesPart = "[Content_Types].xml"
    public static let rootRelsPart = "_rels/.rels"
    public static let documentPart = "word/document.xml"
    public static let documentRelsPart = "word/_rels/document.xml.rels"
    public static let stylesPart = "word/styles.xml"
    public static let numberingPart = "word/numbering.xml"
    public static let settingsPart = "word/settings.xml"
    public static let footnotesPart = "word/footnotes.xml"
    public static let footnotesRelsPart = "word/_rels/footnotes.xml.rels"
    public static let corePropsPart = "docProps/core.xml"
    public static let appPropsPart = "docProps/app.xml"
    public static let customPropsPart = "docProps/custom.xml"

    /// Where a header or footer part for `name` lives.
    public static func headerPart(_ index: Int) -> String { "word/header\(index).xml" }
    public static func footerPart(_ index: Int) -> String { "word/footer\(index).xml" }

    /// The `_rels` part that describes `path`'s own relationships.
    public static func relsPart(for path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "_rels/\(path).rels" }
        let directory = path[..<slash]
        let file = path[path.index(after: slash)...]
        return "\(directory)/_rels/\(file).rels"
    }

    /// A relationship target resolved against the directory of the part that declared it.
    public static func resolve(target: String, from directory: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var out: [String] = []
        for segment in "\(directory)/\(target)".split(separator: "/") {
            if segment == "." { continue }
            if segment == ".." { out.removeLast(out.isEmpty ? 0 : 1) } else { out.append(String(segment)) }
        }
        return out.joined(separator: "/")
    }
}

// MARK: - XML text

/// Escaping and small builders for the XML the writer emits.
///
/// The writer produces XML as text rather than through a DOM: every part it writes has a fixed
/// shape, and a string template says what that shape is far more legibly than a tree of builder
/// calls would. Everything that reaches a document goes through ``escape(_:)`` or
/// ``attributeValue(_:)`` — a stray `&` in a user's paragraph is enough to make Word declare the
/// file corrupt.
public enum XMLText {

    public static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    /// Character data, with the five predefined entities replaced.
    public static func escape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for character in string.unicodeScalars {
            switch character {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "'":  out += "&apos;"
            // XML 1.0 cannot carry most control characters at all, escaped or not, and a document
            // that contains one is a document Word refuses to open. They are dropped rather than
            // passed through: tab, newline and carriage return are the three that are legal.
            case "\u{09}", "\u{0A}", "\u{0D}": out.unicodeScalars.append(character)
            case let scalar where scalar.value < 0x20: continue
            default: out.unicodeScalars.append(character)
            }
        }
        return out
    }

    public static func attributeValue(_ string: String) -> String { escape(string) }
}
