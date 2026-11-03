import XCTest
@testable import NeutrinoCore

/// When an app's Drive preview is redrawn: only when page one changed, or when the file has none.
final class DocumentPreviewGateTests: XCTestCase {

    /// Counts renders and uploads; `failUploads` makes every upload throw.
    actor Recorder {
        var renders = 0
        var uploads = 0
        var failUploads = false
        func rendered() { renders += 1 }
        func uploaded() throws {
            if failUploads { throw URLError(.notConnectedToInternet) }
            uploads += 1
        }
        func setFailUploads(_ value: Bool) { failUploads = value }
    }

    private func makeGate(_ recorder: Recorder, image: Data? = Data([0xFF, 0xD8, 0xFF])) -> DocumentPreviewGate {
        DocumentPreviewGate(
            render: { await recorder.rendered(); return image },
            upload: { _ in try await recorder.uploaded() }
        )
    }

    func testLoadWithAPreviewDrawsNothing() async {
        let recorder = Recorder()
        let gate = makeGate(recorder)
        await gate.loaded(signature: "p1", hasPreview: true)
        await gate.idle()
        let renders = await recorder.renders
        XCTAssertEqual(renders, 0)
    }

    func testLoadWithoutAPreviewDrawsOne() async {
        let recorder = Recorder()
        let gate = makeGate(recorder)
        await gate.loaded(signature: "p1", hasPreview: false)
        await gate.idle()
        let uploads = await recorder.uploads
        XCTAssertEqual(uploads, 1)
    }

    func testSavesThatLeavePageOneAloneDrawNothing() async {
        let recorder = Recorder()
        let gate = makeGate(recorder)
        await gate.loaded(signature: "p1", hasPreview: true)
        await gate.saved(signature: "p1", hasPreview: true)
        await gate.saved(signature: "p1", hasPreview: true)
        await gate.idle()
        let renders = await recorder.renders
        XCTAssertEqual(renders, 0)
    }

    func testAChangedPageOneIsDrawnOnce() async {
        let recorder = Recorder()
        let gate = makeGate(recorder)
        await gate.loaded(signature: "p1", hasPreview: true)
        await gate.saved(signature: "p1 edited", hasPreview: true)
        await gate.idle()
        await gate.saved(signature: "p1 edited", hasPreview: true)
        await gate.idle()
        let uploads = await recorder.uploads
        XCTAssertEqual(uploads, 1)
    }

    func testAFailedUploadIsRetriedOnTheNextSave() async {
        let recorder = Recorder()
        await recorder.setFailUploads(true)
        let gate = makeGate(recorder)
        await gate.loaded(signature: "p1", hasPreview: true)
        await gate.saved(signature: "p1 edited", hasPreview: true)
        await gate.idle()
        await recorder.setFailUploads(false)
        await gate.saved(signature: "p1 edited", hasPreview: true)
        await gate.idle()
        let (renders, uploads) = (await recorder.renders, await recorder.uploads)
        XCTAssertEqual(renders, 2)
        XCTAssertEqual(uploads, 1)
    }

    func testNothingToDrawStoresNothing() async {
        let recorder = Recorder()
        let gate = makeGate(recorder, image: nil)
        await gate.loaded(signature: "p1", hasPreview: false)
        await gate.idle()
        let (renders, uploads) = (await recorder.renders, await recorder.uploads)
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(uploads, 0)
    }

    func testTheUploadRequestCarriesTheImage() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.test" + DriveThumbnail.path(fileID: "f1"))))
        DriveThumbnail.prepare(&request, jpeg: Data([1, 2, 3]))
        XCTAssertEqual(request.url?.path, "/api/v1/drive/files/f1/thumbnail")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(request.httpBody, Data([1, 2, 3]))
    }
}
