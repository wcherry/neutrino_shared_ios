import PDFKit
import UIKit
import XCTest
@testable import NeutrinoPrint

final class NeutrinoPrintTests: XCTestCase {

    // MARK: - Helpers

    private func paragraphs(_ count: Int) -> NSAttributedString {
        let line = "The quick brown fox jumps over the lazy dog, again and again and again.\n"
        return NSAttributedString(string: String(repeating: line, count: count),
                                  attributes: [.font: UIFont.systemFont(ofSize: 12)])
    }

    private func pageCount(of pdf: Data) -> Int {
        PDFDocument(data: pdf)?.pageCount ?? -1
    }

    // MARK: - PrintJob

    func testHeaderDefaultsToTheName() {
        let job = PrintJob(name: "Quarterly report", content: .attributedText(paragraphs(1)))
        XCTAssertEqual(job.header, "Quarterly report")
    }

    func testHeaderCanBeReplacedOrTurnedOff() {
        let custom = PrintJob(name: "a", content: .markup(""), header: "Custom")
        XCTAssertEqual(custom.header, "Custom")

        let none = PrintJob(name: "a", content: .markup(""), showsHeader: false)
        XCTAssertNil(none.header)
    }

    // MARK: - AttributedTextPageSource

    func testShortTextIsOnePage() {
        let source = AttributedTextPageSource(text: paragraphs(3))
        XCTAssertEqual(source.pageCount(for: CGSize(width: 500, height: 700)), 1)
    }

    func testEmptyTextIsStillOnePage() {
        let source = AttributedTextPageSource(text: NSAttributedString())
        XCTAssertEqual(source.pageCount(for: CGSize(width: 500, height: 700)), 1)
    }

    func testLongTextFlowsOntoMorePages() {
        let source = AttributedTextPageSource(text: paragraphs(400))
        let tall = source.pageCount(for: CGSize(width: 500, height: 700))
        let short = source.pageCount(for: CGSize(width: 500, height: 350))

        XCTAssertGreaterThan(tall, 1)
        // Re-laid out when the paper changes: half the height, about twice the pages.
        XCTAssertGreaterThanOrEqual(short, tall * 2 - 1)
    }

    func testEveryGlyphLandsOnExactlyOnePage() {
        let text = paragraphs(200)
        let source = AttributedTextPageSource(text: text)
        let size = CGSize(width: 400, height: 500)
        let count = source.pageCount(for: size)

        var ranges: [NSRange] = []
        source.drawBehindText = { ranges.append($0.glyphRange) }
        UIGraphicsImageRenderer(size: size).image { _ in
            for index in 0..<count {
                source.drawPage(at: index, in: CGRect(origin: .zero, size: size))
            }
        }

        XCTAssertEqual(ranges.count, count)
        XCTAssertEqual(ranges.first?.location, 0)
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(NSMaxRange(previous), next.location)
        }
        XCTAssertEqual(ranges.last.map(NSMaxRange), (text.string as NSString).length)
    }

    func testPageGeometryIsInDrawingCoordinates() {
        let source = AttributedTextPageSource(text: paragraphs(2))
        let rect = CGRect(x: 40, y: 60, width: 400, height: 500)
        var found: CGRect?
        var containsFirst = false

        source.drawBehindText = { page in
            found = page.boundingRect(forCharacterRange: NSRange(location: 0, length: 5))
            containsFirst = page.contains(characterAt: 0)
        }
        _ = source.pageCount(for: rect.size)
        UIGraphicsImageRenderer(size: CGSize(width: 500, height: 600)).image { _ in
            source.drawPage(at: 0, in: rect)
        }

        XCTAssertTrue(containsFirst)
        let bounds = try? XCTUnwrap(found)
        XCTAssertEqual(bounds?.minX ?? 0, rect.minX, accuracy: 1)
        XCTAssertEqual(bounds?.minY ?? 0, rect.minY, accuracy: 1)
    }

    // MARK: - Renderer

    func testLongTextPrintsToSeveralPDFPages() {
        let job = PrintJob(name: "Long", content: .attributedText(paragraphs(400)))
        XCTAssertGreaterThan(pageCount(of: NeutrinoPrintPageRenderer(job: job).pdfData()), 1)
    }

    func testPDFCarriesHeaderAndPageNumbers() {
        let job = PrintJob(name: "Minutes of the meeting", content: .attributedText(paragraphs(1)))
        let pdf = NeutrinoPrintPageRenderer(job: job).pdfData()
        let text = PDFDocument(data: pdf)?.page(at: 0)?.string ?? ""

        XCTAssertTrue(text.contains("Minutes of the meeting"), text)
        XCTAssertTrue(text.contains("Page 1 of 1"), text)
    }

    func testContentSitsInsideTheBandsAndMargins() {
        var drawnIn: CGRect?
        let job = PrintJob(name: "a", content: .pages(ProbeSource { drawnIn = $0 }))
        _ = NeutrinoPrintPageRenderer(job: job).pdfData(paperSize: NeutrinoPrintPageRenderer.letter)

        let margin = NeutrinoPrintPageRenderer.pdfHardwareMargin
        let band = NeutrinoPrintPageRenderer.bandHeight
        XCTAssertEqual(drawnIn?.minX ?? 0, margin + job.margins.left, accuracy: 0.5)
        XCTAssertEqual(drawnIn?.minY ?? 0, margin + band + job.margins.top, accuracy: 0.5)
        XCTAssertEqual(drawnIn?.maxY ?? 0, 792 - margin - band - job.margins.bottom, accuracy: 0.5)
    }

    func testNoBandsWhenTurnedOff() {
        let job = PrintJob(name: "a", content: .attributedText(paragraphs(1)),
                           showsHeader: false, showsPageNumbers: false)
        let renderer = NeutrinoPrintPageRenderer(job: job)
        XCTAssertEqual(renderer.headerHeight, 0)
        XCTAssertEqual(renderer.footerHeight, 0)
    }

    func testPageLabelCountsFromOne() {
        XCTAssertEqual(NeutrinoPrintPageRenderer.pageLabel(page: 0, of: 3), "Page 1 of 3")
        XCTAssertEqual(NeutrinoPrintPageRenderer.pageLabel(page: 2, of: 3), "Page 3 of 3")
    }

    /// Dark Mode must not reach the paper: `.label` is drawn black, not white.
    func testPagesAreDrawnInTheLightAppearance() {
        var resolved: UIUserInterfaceStyle?
        let probe = ProbeSource { _ in resolved = UITraitCollection.current.userInterfaceStyle }
        let job = PrintJob(name: "a", content: .pages(probe))

        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            _ = NeutrinoPrintPageRenderer(job: job).pdfData()
        }

        XCTAssertEqual(resolved, .light)
    }

    // MARK: - Printer

    @MainActor
    func testConfigureClearsThePreviousJob() {
        let controller = UIPrintInteractionController.shared
        NeutrinoPrinter.configure(controller, for: PrintJob(name: "pdf", content: .pdf(Data())))
        XCTAssertNotNil(controller.printingItem)

        NeutrinoPrinter.configure(controller,
                                  for: PrintJob(name: "Text", content: .attributedText(paragraphs(1))))
        XCTAssertNil(controller.printingItem)
        XCTAssertTrue(controller.printPageRenderer is NeutrinoPrintPageRenderer)
        XCTAssertEqual(controller.printInfo?.jobName, "Text")
    }
}

// MARK: - Fixtures

/// One page, reporting the rect it was asked to draw into.
private final class ProbeSource: PrintPageSource {
    let onDraw: (CGRect) -> Void
    init(onDraw: @escaping (CGRect) -> Void) { self.onDraw = onDraw }
    func pageCount(for contentSize: CGSize) -> Int { 1 }
    func drawPage(at index: Int, in rect: CGRect) { onDraw(rect) }
}
