// iOS-only for now: this target is UIKit/SwiftUI-for-iOS and is compiled out on macOS, where
// only NeutrinoCore, NeutrinoAuth, NeutrinoCrypto and NeutrinoOOXML are built. See Package.swift.
#if os(iOS)

import UIKit

// MARK: - PrintJob

/// Everything a Neutrino app needs to say to print something: what it is called, what goes on the
/// paper, and how the pages are dressed.
///
/// An app's only job is to turn its own document into a ``PrintContent``. Pagination, the running
/// header, page numbers, the light-appearance rendering paper needs and presenting the system print
/// dialog are the same in every app, and live here — so Docs, Sheets, Notes and Slides print pages
/// that look like they came from one product.
public struct PrintJob {

    /// The job's name in the print queue, and the running header unless ``header`` says otherwise.
    /// Usually the document's title.
    public var name: String

    /// What goes on the paper.
    public var content: PrintContent

    /// Drawn at the top of every page; `nil` leaves the header off.
    public var header: String?

    /// Draws `Page 3 of 7` at the foot of every page.
    public var showsPageNumbers: Bool

    /// Space between the printer's imageable area and the content, in points. The printer's own
    /// hardware margin is outside this.
    public var margins: UIEdgeInsets

    /// `.general` mixes text and pictures; `.grayscale` suits a document that is all text, and
    /// `.photo` an image. Printers use it to pick paper and quality defaults.
    public var outputType: UIPrintInfo.OutputType

    public var orientation: UIPrintInfo.Orientation

    public var duplex: UIPrintInfo.Duplex

    public init(name: String,
                content: PrintContent,
                header: String? = nil,
                showsHeader: Bool = true,
                showsPageNumbers: Bool = true,
                margins: UIEdgeInsets = PrintJob.defaultMargins,
                outputType: UIPrintInfo.OutputType = .general,
                orientation: UIPrintInfo.Orientation = .portrait,
                duplex: UIPrintInfo.Duplex = .longEdge) {
        self.name = name
        self.content = content
        self.header = showsHeader ? (header ?? name) : nil
        self.showsPageNumbers = showsPageNumbers
        self.margins = margins
        self.outputType = outputType
        self.orientation = orientation
        self.duplex = duplex
    }

    /// Half an inch at the sides, a quarter above and below — the header and footer bands already
    /// put air between the content and the edge of the page vertically.
    public static let defaultMargins = UIEdgeInsets(top: 18, left: 36, bottom: 18, right: 36)
}

// MARK: - PrintContent

/// What goes on the paper, in whichever form the app finds natural to produce.
public enum PrintContent {

    /// Flowing text, paginated by TextKit. Attachments draw as they would on screen. The shape a
    /// word processor or a notes app has.
    case attributedText(NSAttributedString)

    /// Pages the app draws itself. For content that is not flowing text — a spreadsheet grid split
    /// into row and column bands, one slide per page — or for text that needs drawing beside it
    /// (see ``AttributedTextPageSource/drawBehindText``).
    case pages(PrintPageSource)

    /// HTML, paginated by WebKit's print formatter. The quickest route for a table: Sheets can
    /// render a range to `<table>` markup and let the formatter split it across pages.
    case markup(String)

    /// A finished PDF, printed as it is — no header, footer or margins are added to it.
    case pdf(Data)

    /// Pictures, one or more to a page as the print dialog decides — no header or footer.
    case images([UIImage])
}

// MARK: - PrintPageSource

/// Content that knows how to cut itself into pages.
///
/// Called with the size of the content area once the paper is known, which is only after the user
/// has picked a printer — so a source must not assume a paper size up front, and should cache its
/// layout per size since both calls arrive repeatedly while the preview is on screen.
///
/// Both methods may be called off the main thread while printing. A source must draw from state it
/// already holds; nothing in it may reach for a `@MainActor` object.
public protocol PrintPageSource: AnyObject {

    /// How many pages the content needs at this content-area size. At least one.
    func pageCount(for contentSize: CGSize) -> Int

    /// Draws one page into `rect`, which is the content area on the current graphics context.
    func drawPage(at index: Int, in rect: CGRect)
}

// MARK: - PrintError

public enum PrintError: LocalizedError, Equatable {
    /// This device has no printing support, or no window to present the dialog from.
    case unavailable
    /// The print system returned an error.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Printing isn't available on this device."
        case .failed(let reason):
            return "Couldn't print: \(reason)"
        }
    }
}

#endif
