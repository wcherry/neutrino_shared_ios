import Foundation

// MARK: - DocumentPreviewGate

/// Keeps a document's Drive preview in step with its first page.
///
/// Every app's content is end-to-end encrypted, so the server cannot draw a preview of it: the app
/// holding the plaintext renders page one and stores it with `PUT /api/v1/drive/files/{id}/thumbnail`
/// (``DriveThumbnail``). This decides *when*, and is the same rule the web editors follow
/// (`useDocumentPreview` in `neutrino/web`).
///
/// An editor describes its first page as a **signature** — a string built from its model, cheap to
/// compute, equal whenever page one would look the same — and hands it over when the document has
/// loaded and after each successful save. The page is redrawn and uploaded only when the signature
/// moved, or when the file has no preview yet, so an edit on page nine never re-renders page one
/// and an autosave loop does not upload a JPEG every few seconds.
///
/// One render runs at a time: a signature that changes again while one is in flight is picked up
/// by one more render after it, never by two at once. A preview is a nicety, so a failure is
/// swallowed and the signature rolled back, and the next save tries again.
public actor DocumentPreviewGate {

    /// Draws page one as a JPEG, or `nil` when there is nothing to draw yet. Called off the main
    /// actor; a renderer that needs UIKit hops to it itself.
    public typealias Render = @Sendable () async -> Data?
    /// Stores the JPEG as the file's preview.
    public typealias Upload = @Sendable (Data) async throws -> Void

    private let render: Render
    private let upload: Upload

    /// What the stored preview shows; `nil` until the editor says.
    private var shown: String?
    private var running: Task<Void, Never>?
    /// The newest signature asked for while a render was in flight.
    private var pending: String?

    public init(render: @escaping Render, upload: @escaping Upload) {
        self.render = render
        self.upload = upload
    }

    /// The document is on screen. Records `signature` as what the stored preview shows — or draws
    /// one now, when the file has none, which is how documents written before previews existed get
    /// one without waiting for an edit.
    public func loaded(signature: String, hasPreview: Bool) {
        guard shown == nil else { return }
        if hasPreview {
            shown = signature
        } else {
            draw(signature)
        }
    }

    /// A save landed. Redraws when page one changed, or when there is no preview.
    public func saved(signature: String, hasPreview: Bool) {
        if hasPreview && signature == shown { return }
        draw(signature)
    }

    /// Waits for the render in flight, and any it queued, to finish. For tests.
    public func idle() async {
        while let running {
            await running.value
        }
    }

    private func draw(_ signature: String) {
        if running != nil {
            pending = signature
            return
        }
        let previous = shown
        // Claimed up front so a save landing mid-render does not queue a second render of the
        // same page.
        shown = signature
        running = Task { [render, upload] in
            var stored = false
            if let jpeg = await render() {
                stored = (try? await upload(jpeg)) != nil
            }
            self.finish(stored: stored, previous: previous)
        }
    }

    private func finish(stored: Bool, previous: String?) {
        if !stored { shown = previous }
        running = nil
        let next = pending
        pending = nil
        if let next, next != shown { draw(next) }
    }
}

// MARK: - DriveThumbnail

/// The request that stores a file's preview, shared so every app sends the same thing.
public enum DriveThumbnail {

    /// The longest edge of a stored preview, in pixels — the size the web and the uploads use.
    public static let maxEdge: Double = 512

    /// `PUT /api/v1/drive/files/{id}/thumbnail`, relative to the API base.
    public static func path(fileID: String) -> String {
        "/api/v1/drive/files/\(fileID)/thumbnail"
    }

    /// Turns `request` — already pointed at ``path(fileID:)`` and authorised — into the upload of
    /// `jpeg`. The body is the image itself; the server tells JPEG, PNG and WebP apart by its bytes.
    public static func prepare(_ request: inout URLRequest, jpeg: Data) {
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpeg
    }
}
