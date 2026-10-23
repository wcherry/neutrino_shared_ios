import UIKit

// MARK: - NeutrinoPrintPageRenderer

/// Lays a ``PrintJob`` out on paper: the running header, the content, and `Page n of m`.
///
/// ## Paper is light
///
/// Every page is drawn with a light-appearance trait collection made current. The apps build their
/// content from dynamic colours — `.label`, `.secondaryLabel` — so that it follows the system
/// appearance on screen, and printed from a phone in Dark Mode those resolve to white: a document
/// that prints as blank pages. Forcing the light appearance here means no app has to build a
/// separate, print-only palette for its content.
///
/// ## Beyond the print dialog
///
/// ``pdfData(paperSize:)`` runs the same pages into a PDF, which is what tests assert against and
/// what an app's "Export as PDF" would share.
public final class NeutrinoPrintPageRenderer: UIPrintPageRenderer {

    public let job: PrintJob

    /// Set for the content kinds this renderer paginates itself; `nil` when a print formatter does.
    private let pageSource: PrintPageSource?

    /// Overrides the printer's paper while rendering a PDF, where there is no printer to ask.
    private var pdfPaper: (paper: CGRect, printable: CGRect)?

    // MARK: - Metrics

    static let bandHeight: CGFloat = 28
    static let bandFont = UIFont.systemFont(ofSize: 9)
    static let bandColor = UIColor(white: 0.4, alpha: 1)

    /// US Letter, in points.
    public static let letter = CGSize(width: 612, height: 792)
    /// ISO A4, in points.
    public static let a4 = CGSize(width: 595.2, height: 841.8)

    /// A typical printer's unprintable edge, used for the imageable area of a PDF.
    static let pdfHardwareMargin: CGFloat = 18

    // MARK: - Init

    public init(job: PrintJob) {
        self.job = job

        switch job.content {
        case .attributedText(let text):
            pageSource = AttributedTextPageSource(text: text)
        case .pages(let source):
            pageSource = source
        case .markup, .pdf, .images:
            pageSource = nil
        }

        super.init()

        headerHeight = job.header == nil ? 0 : Self.bandHeight
        footerHeight = job.showsPageNumbers ? Self.bandHeight : 0

        if case .markup(let html) = job.content {
            let formatter = UIMarkupTextPrintFormatter(markupText: html)
            // A formatter's insets are measured from the printable area, not from the content area
            // between the bands, so the bands are added in or the first line runs under the header.
            var insets = job.margins
            insets.top += headerHeight
            insets.bottom += footerHeight
            formatter.perPageContentInsets = insets
            addPrintFormatter(formatter, startingAtPageAt: 0)
        }
    }

    // MARK: - Paper

    public override var paperRect: CGRect { pdfPaper?.paper ?? super.paperRect }
    public override var printableRect: CGRect { pdfPaper?.printable ?? super.printableRect }

    /// Where the content goes on a page: the printable area less the header and footer bands and
    /// the job's margins.
    var contentRect: CGRect {
        let printable = printableRect
        let bands = CGRect(x: printable.minX,
                           y: printable.minY + headerHeight,
                           width: printable.width,
                           height: printable.height - headerHeight - footerHeight)
        return bands.inset(by: job.margins)
    }

    // MARK: - Pages

    public override var numberOfPages: Int {
        guard let pageSource else { return super.numberOfPages }
        let size = contentRect.size
        guard size.width > 0, size.height > 0 else { return 0 }
        return pageSource.pageCount(for: size)
    }

    public override func drawPage(at pageIndex: Int, in printableRect: CGRect) {
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            super.drawPage(at: pageIndex, in: printableRect)
        }
    }

    public override func drawContentForPage(at pageIndex: Int, in contentRect: CGRect) {
        guard let pageSource else { return }
        pageSource.drawPage(at: pageIndex, in: self.contentRect)
    }

    public override func drawHeaderForPage(at pageIndex: Int, in headerRect: CGRect) {
        guard let header = job.header, !header.isEmpty else { return }
        drawBand(header, in: headerRect, alignment: .natural)
    }

    public override func drawFooterForPage(at pageIndex: Int, in footerRect: CGRect) {
        guard job.showsPageNumbers else { return }
        drawBand(Self.pageLabel(page: pageIndex, of: numberOfPages), in: footerRect,
                 alignment: .center)
    }

    /// `Page 3 of 7`, counting from one.
    static func pageLabel(page index: Int, of count: Int) -> String {
        "Page \(index + 1) of \(max(count, index + 1))"
    }

    /// One line of small grey text, vertically centred in a band and inset to line up with the
    /// content's left and right edges.
    private func drawBand(_ text: String, in band: CGRect, alignment: NSTextAlignment) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.bandFont,
            .foregroundColor: Self.bandColor,
            .paragraphStyle: paragraph,
        ]

        let lineHeight = ceil(Self.bandFont.lineHeight)
        let line = CGRect(x: band.minX + job.margins.left,
                          y: band.midY - lineHeight / 2,
                          width: band.width - job.margins.left - job.margins.right,
                          height: lineHeight)
        (text as NSString).draw(with: line, options: [.usesLineFragmentOrigin],
                                attributes: attributes, context: nil)
    }

    // MARK: - PDF

    /// Every page of the job as a PDF, on paper of `paperSize`.
    ///
    /// Only the kinds this renderer lays out — attributed text, pages and markup. A ``PrintContent/pdf(_:)``
    /// job already *is* its PDF, and images are laid out by the print system; both come back as an
    /// empty document here.
    public func pdfData(paperSize: CGSize = NeutrinoPrintPageRenderer.letter) -> Data {
        let paper = CGRect(origin: .zero, size: paperSize)
        pdfPaper = (paper, paper.insetBy(dx: Self.pdfHardwareMargin, dy: Self.pdfHardwareMargin))
        defer { pdfPaper = nil }

        let count = numberOfPages
        let renderer = UIGraphicsPDFRenderer(bounds: paper)
        return renderer.pdfData { context in
            guard count > 0 else { return }
            prepare(forDrawingPages: NSRange(location: 0, length: count))
            for index in 0..<count {
                context.beginPage()
                drawPage(at: index, in: printableRect)
            }
        }
    }
}
