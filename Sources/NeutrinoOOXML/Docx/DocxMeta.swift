import Foundation

// MARK: - DocxMeta

/// A typed view over the layout block stored beside a document.
///
/// The block itself stays a ``DocValue`` — every client keeps it verbatim so that a field one of
/// them has not learned about survives the round trip — and this is the reading end of it. Every
/// accessor has a default, because a document written before a field existed simply does not have
/// it, and a `nil` margin laid out as NaN is not an improvement on 72 points.
///
/// The shape is the web app's `LayoutMeta` (`web/apps/web/src/lib/docBody.ts`).
struct DocxMeta {

    // MARK: - Slots

    /// One band: three independently aligned slots on a single line.
    struct Slots: Equatable {
        var left = ""
        var center = ""
        var right = ""

        var isEmpty: Bool { left.isEmpty && center.isEmpty && right.isEmpty }
    }

    /// The header and footer of one variant.
    struct Band: Equatable {
        var header = Slots()
        var footer = Slots()
    }

    /// The three variants Word can give a section: every page, page one, and even pages.
    enum Variant: String, CaseIterable {
        case `default`
        case first
        case even
    }

    // MARK: - Properties

    let raw: DocValue?

    init(_ raw: DocValue?) {
        self.raw = raw
    }

    // MARK: - Page setup

    var pageSize: String { pageSetup["pageSize"]?.stringValue ?? "letter" }

    var isLandscape: Bool { pageSetup["orientation"]?.stringValue == "landscape" }

    func margin(_ edge: String) -> Double {
        pageSetup["margin\(edge)"]?.doubleValue ?? 72
    }

    private var pageSetup: [String: DocValue] {
        raw?["pageSetup"]?.objectValue ?? DocxMapping.defaultPageSetup
    }

    // MARK: - Bands

    var differentFirstPage: Bool { headerFooter["differentFirstPage"]?.boolValue ?? false }
    var differentEvenOdd: Bool { headerFooter["differentEvenOdd"]?.boolValue ?? false }

    /// 0.5in, the word-processor default, in points.
    var headerMargin: Double { headerFooter["headerMargin"]?.doubleValue ?? 36 }
    var footerMargin: Double { headerFooter["footerMargin"]?.doubleValue ?? 36 }

    /// The header and footer of one variant, or an empty pair when the document has none.
    func band(_ variant: Variant) -> Band {
        guard let object = headerFooter["variants"]?[variant.rawValue]?.objectValue else { return Band() }
        return Band(header: slots(object["header"]), footer: slots(object["footer"]))
    }

    /// Whether a variant is written at all. `first` and `even` exist only when the document asked
    /// for them — writing an empty `first` header would give page one a blank band where it should
    /// inherit the default one.
    func writes(_ variant: Variant) -> Bool {
        switch variant {
        case .default: return true
        case .first:   return differentFirstPage
        case .even:    return differentEvenOdd
        }
    }

    private var headerFooter: [String: DocValue] {
        raw?["headerFooter"]?.objectValue ?? [:]
    }

    private func slots(_ value: DocValue?) -> Slots {
        guard let object = value?.objectValue else { return Slots() }
        return Slots(left: object["left"]?.stringValue ?? "",
                     center: object["center"]?.stringValue ?? "",
                     right: object["right"]?.stringValue ?? "")
    }

    // MARK: - Decoration

    var watermarkText: String { raw?["watermarkText"]?.stringValue ?? "" }

    /// The page background, normalised — the model accepts three spellings of a colour and OOXML
    /// has one.
    var backgroundColor: String { DocxMapping.normalizeColor(raw?["bgColor"]?.stringValue) }

    var docTheme: String? { raw?["docTheme"]?.stringValue }

    // MARK: - Document properties

    var author: String { property("author") }
    var subject: String { property("subject") }
    var keywords: String { property("keywords") }
    var category: String { property("category") }
    var company: String { property("company") }
    var manager: String { property("manager") }

    /// Anything else the user has named, reachable as `{{whatever}}`.
    var customProperties: [(name: String, value: String)] {
        let custom = properties["custom"]?.objectValue ?? [:]
        return custom.keys.sorted().compactMap { key in
            guard let value = custom[key]?.text else { return nil }
            return (name: key, value: value)
        }
    }

    /// Whether `docProps/custom.xml` has anything to say. Company and manager live there too:
    /// `docProps/core.xml` has no element for either, and `DOCPROPERTY` looks for them there.
    var hasCustomProperties: Bool {
        !company.isEmpty || !manager.isEmpty || !customProperties.isEmpty
    }

    private var properties: [String: DocValue] {
        raw?["properties"]?.objectValue ?? [:]
    }

    private func property(_ name: String) -> String {
        properties[name]?.stringValue ?? ""
    }
}
