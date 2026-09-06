import Foundation

// MARK: - DocxExtras

/// Node-level data with no OOXML home, addressed by the node's index in document order among nodes
/// of the same kind.
///
/// Indices rather than ids because the ids would have to be written into the document to be found
/// again, and every mechanism for that (bookmarks, content controls) is one Word is free to
/// renumber. An index degrades predictably instead: edit the document in Word and the extras for
/// anything after the edit stop matching, so they are dropped and the base content — which is all
/// real OOXML — still reads. Full fidelity is a Neutrino-to-Neutrino property; it cannot be anything
/// else once another editor has had the file.
///
/// Serialised as JSON inside ``DocxMapping/extrasPart``. The shape is shared with the web app's
/// `DocExtras`, so the keys here are the keys there.
public struct DocxExtras: Codable, Equatable {

    // MARK: - ImageExtra

    /// Per-image data OOXML has no element for.
    public struct ImageExtra: Codable, Equatable {
        public var shadow: String?
        public var filter: String?
        public var caption: String?
        /// The `neutrino-drive:` reference the editor stores, which cannot travel in a package.
        public var driveRef: String?

        public var isEmpty: Bool {
            shadow == nil && filter == nil && caption == nil && driveRef == nil
        }

        public init(shadow: String? = nil, filter: String? = nil,
                    caption: String? = nil, driveRef: String? = nil) {
            self.shadow = shadow
            self.filter = filter
            self.caption = caption
            self.driveRef = driveRef
        }
    }

    // MARK: - Placeholder

    /// An inline or block node written as a text placeholder, in document order.
    ///
    /// One list rather than one per kind, because the reader matches placeholders by position and
    /// cannot tell an embed's `[Q1 sales]` from an unresolvable image's `[Figure 1]` by looking at
    /// it. A single ordered channel makes the question "which node was this" answerable instead of a
    /// guess.
    public struct Placeholder: Codable, Equatable {
        public var kind: String
        public var attrs: [String: DocValue]

        public init(kind: String, attrs: [String: DocValue]) {
            self.kind = kind
            self.attrs = attrs
        }
    }

    // MARK: - ColumnLayout

    /// A `columnLayout` node's shape: how many columns, and how many blocks it covered.
    ///
    /// CSS columns are a section-level concept in OOXML, so the children are written in order and
    /// this is what the reader regroups them from.
    public struct ColumnLayout: Codable, Equatable {
        public var columns: Int
        public var blockCount: Int

        public init(columns: Int, blockCount: Int) {
            self.columns = columns
            self.blockCount = blockCount
        }
    }

    // MARK: - Properties

    /// `docTheme`, the preset name no interchange format models.
    public var theme: String?
    /// Per-image extras, keyed by the image's index in document order.
    public var images: [String: ImageExtra]?
    /// Cross-reference target headings, keyed by the reference's index in document order.
    public var crossRefs: [String: String]?
    public var placeholders: [Placeholder]?
    /// `showCode` on a field, by field index — a display toggle Word has no notion of.
    public var fieldShowCode: [Int]?
    public var columnLayouts: [ColumnLayout]?

    public init() {}

    public var isEmpty: Bool {
        theme == nil && (images?.isEmpty ?? true) && (crossRefs?.isEmpty ?? true)
            && (placeholders?.isEmpty ?? true) && (fieldShowCode?.isEmpty ?? true)
            && (columnLayouts?.isEmpty ?? true)
    }

    // MARK: - Accessors

    public func image(at index: Int) -> ImageExtra? { images?[String(index)] }

    public func crossRef(at index: Int) -> String? { crossRefs?[String(index)] }

    public func placeholder(at index: Int) -> Placeholder? {
        guard let placeholders, index >= 0, index < placeholders.count else { return nil }
        return placeholders[index]
    }

    public func showsCode(fieldAt index: Int) -> Bool {
        fieldShowCode?.contains(index) ?? false
    }

    // MARK: - Collection, while writing

    mutating func addImage(_ extra: ImageExtra, at index: Int) {
        guard !extra.isEmpty else { return }
        images = (images ?? [:]).merging([String(index): extra]) { _, new in new }
    }

    mutating func addCrossRef(_ headingText: String, at index: Int) {
        crossRefs = (crossRefs ?? [:]).merging([String(index): headingText]) { _, new in new }
    }

    mutating func addPlaceholder(kind: String, attrs: [String: DocValue]) {
        placeholders = (placeholders ?? []) + [Placeholder(kind: kind, attrs: attrs)]
    }

    mutating func addFieldShowCode(_ index: Int) {
        fieldShowCode = (fieldShowCode ?? []) + [index]
    }

    mutating func addColumnLayout(columns: Int, blockCount: Int) {
        columnLayouts = (columnLayouts ?? []) + [ColumnLayout(columns: columns, blockCount: blockCount)]
    }

    // MARK: - The part

    /// Reads the extras out of a package, or an empty set when the part is missing or unreadable.
    static func read(from archive: ZipArchive) -> DocxExtras {
        guard let xml = archive.text(for: DocxMapping.extrasPart),
              let root = XMLElement.parse(xml) else { return DocxExtras() }
        let json = root.textContent
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let extras = try? JSONDecoder().decode(DocxExtras.self, from: data) else {
            return DocxExtras()
        }
        return extras
    }

    /// The two parts that carry the extras, ready to add to a package.
    ///
    /// A custom XML part needs its `itemProps` sibling and a schema reference, or Word treats it as
    /// an orphan and drops it on the first save — which is the whole reason this is a custom XML
    /// part rather than a loose file.
    func parts() throws -> (item: String, props: String)? {
        guard !isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(self), as: UTF8.self)

        let item = XMLText.declaration
            + "<neutrino xmlns=\"\(DocxMapping.extrasNamespace)\">\(XMLText.escape(json))</neutrino>"
        let props = XMLText.declaration
            + "<ds:datastoreItem xmlns:ds=\"\(OOXMLNamespace.customXml)\" "
            + "ds:itemID=\"{4E4A2B37-7C21-4F1E-9C55-3F5B0E2A1D90}\">"
            + "<ds:schemaRefs><ds:schemaRef ds:uri=\"\(DocxMapping.extrasNamespace)\"/></ds:schemaRefs>"
            + "</ds:datastoreItem>"
        return (item, props)
    }
}
