import Foundation
@testable import NeutrinoOOXML

// MARK: - TestMeta

/// The layout block a document is stored with, built the way the editors build it.
///
/// Every field is present and spelled as the web app spells it, because the round-trip property is
/// asserted against the whole block: a helper that omitted the fields it did not care about would
/// let the reader invent them and still pass.
enum TestMeta {

    static func slots(_ values: [String]) -> DocValue {
        .object(["left": .string(values[0]), "center": .string(values[1]),
                 "right": .string(values[2])])
    }

    static func band(header: [String], footer: [String]) -> DocValue {
        .object(["header": slots(header), "footer": slots(footer)])
    }

    static func emptyBand() -> DocValue {
        band(header: ["", "", ""], footer: ["", "", ""])
    }

    static func base(watermark: String = "",
                     bgColor: String = "",
                     theme: String = "default",
                     properties: [String: DocValue]? = nil,
                     pageSetup: [String: DocValue]? = nil,
                     differentFirstPage: Bool = false,
                     differentEvenOdd: Bool = false,
                     headerMargin: Int = 36,
                     footerMargin: Int = 36,
                     variants: [String: DocValue] = [:],
                     headerText: String = "",
                     footerText: String = "",
                     showPageNumbers: Bool = false) -> DocValue {
        var allVariants: [String: DocValue] = ["default": emptyBand(), "first": emptyBand(),
                                               "even": emptyBand()]
        for (name, value) in variants { allVariants[name] = value }

        return .object([
            "headerFooter": .object([
                "differentFirstPage": .bool(differentFirstPage),
                "differentEvenOdd": .bool(differentEvenOdd),
                "headerMargin": .int(headerMargin),
                "footerMargin": .int(footerMargin),
                "variants": .object(allVariants),
            ]),
            "headerText": .string(headerText),
            "footerText": .string(footerText),
            "showPageNumbers": .bool(showPageNumbers),
            "watermarkText": .string(watermark),
            "bgColor": .string(bgColor),
            "docTheme": .string(theme),
            "properties": .object(properties ?? [
                "author": .string(""), "subject": .string(""), "company": .string(""),
                "category": .string(""), "keywords": .string(""), "manager": .string(""),
                "custom": .object([:]),
            ]),
            "pageSetup": .object(pageSetup ?? [
                "marginTop": .int(72), "marginBottom": .int(72),
                "marginLeft": .int(72), "marginRight": .int(72),
                "orientation": .string("portrait"), "pageSize": .string("letter"),
            ]),
        ])
    }

    /// A one-pixel PNG — enough for the writer to sniff a format and embed a media part.
    static let pngBytes: Data = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
}
