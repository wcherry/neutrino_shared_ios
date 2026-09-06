import Foundation

// MARK: - DocxCodec

/// The one door in and out of the `.docx` a Neutrino document is stored as.
///
/// A native document is a real Word file (issue #127): the mime type is
/// ``mimeType``, the extension rides on the Drive file's *name* so a download lands on disk as
/// something the operating system can open, and every other office suite opens one directly.
///
/// Callers speak either the model (``DocModel``) or the stored JSON envelope the editors hold —
/// `{ doc, _meta }`. The JSON boundary exists so an app can keep its own document types: the phone's
/// editor works on its own ProseMirror tree, and handing it a string it already knows how to decode
/// is one conversion rather than two.
///
/// ## Images
///
/// A picture in a Neutrino document is a *reference* to another Drive file, and a `.docx` has to
/// carry the bytes. Only the client holding the key can fetch those, so writing is a two-step:
/// ``imageSources(in:)`` says what the document needs, the caller resolves what it can, and
/// ``encode(_:title:images:)`` embeds what it was given. An unresolved reference is written as a
/// placeholder that carries the whole image node, so nothing is lost when a save happens offline —
/// the picture comes back on the next read, and on the next save with bytes in hand it is a real
/// picture in the package again.
public enum DocxCodec {

    // MARK: - Identity

    /// What Drive stores a Neutrino document as.
    public static let mimeType =
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    public static let fileExtension = "docx"

    /// The scheme an image `src` uses to point at another Drive file.
    public static let driveReferenceScheme = "neutrino-drive:"

    // MARK: - Reading

    /// Reads `.docx` bytes into the document model.
    public static func decode(_ data: Data) throws -> DocModel {
        try DocxReader.read(data)
    }

    /// Reads `.docx` bytes into the stored JSON envelope, `{ doc, _meta }`.
    public static func decodeToJSON(_ data: Data) throws -> String {
        try DocxReader.read(data).toJSON()
    }

    /// Whether these bytes are a Word document.
    public static func isDocument(_ data: Data) -> Bool { DocxReader.isDocument(data) }

    // MARK: - Writing

    /// Renders the model as `.docx` bytes.
    ///
    /// - Parameters:
    ///   - title: the document's title, which is also what a `TITLE` field resolves to. It is the
    ///     Drive file's name with the extension stripped, not something stored in the body.
    ///   - images: bytes for the image sources ``imageSources(in:)`` reported. A `data:` URL needs
    ///     no entry — it already is the picture.
    public static func encode(_ model: DocModel, title: String,
                              images: [String: Data] = [:]) throws -> Data {
        try DocxWriter.write(model, options: DocxWriteOptions(title: title, images: images))
    }

    /// The same, starting from the stored JSON envelope.
    ///
    /// A string that is not a document at all yields an empty one rather than throwing: the caller
    /// is part-way through saving, and a body it cannot encode is a bug here rather than something
    /// the user can act on.
    public static func encodeJSON(_ json: String, title: String,
                                  images: [String: Data] = [:]) throws -> Data {
        try encode(DocModel.fromJSON(json) ?? .empty, title: title, images: images)
    }

    /// A valid, empty `.docx` — what a newly created document holds until its first save.
    public static func emptyDocument(title: String) throws -> Data {
        try encode(.empty, title: title)
    }

    /// Every image `src` a document references, in document order and without duplicates.
    public static func imageSources(in model: DocModel) -> [String] {
        DocxWriter.imageSources(in: model)
    }

    /// The same, for a caller holding the stored JSON rather than the model.
    public static func imageSources(inJSON json: String) -> [String] {
        guard let model = DocModel.fromJSON(json) else { return [] }
        return DocxWriter.imageSources(in: model)
    }

    // MARK: - Names

    /// `name` with `.docx` on the end, added only if it is not already there.
    ///
    /// The extension is part of the *file* name because a download has to land on disk as
    /// `Report.docx` to open on a double-click. Renaming "Report" twice must not produce
    /// `Report.docx.docx`.
    public static func withExtension(_ name: String) -> String {
        hasExtension(name) ? name : "\(name).\(fileExtension)"
    }

    /// `name` without a trailing `.docx` — the title to show for a file.
    ///
    /// A file genuinely called "Q3.report" keeps its name, and so does a legacy `.doc`: only the
    /// modern extension is stripped.
    public static func strippingExtension(_ name: String) -> String {
        hasExtension(name) ? String(name.dropLast(fileExtension.count + 1)) : name
    }

    private static func hasExtension(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".\(fileExtension)")
    }
}
