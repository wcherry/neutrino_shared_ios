import UIKit

// MARK: - AttributedTextPageSource

/// Flows an attributed string across pages with TextKit 1: one text container per page, all fed by
/// one layout manager, so a paragraph that does not fit continues at the top of the next page.
///
/// TextKit 1 because it is what hands out per-page geometry: an app that draws beside its text — a
/// bullet the document's structure calls for, a panel behind a code block — gets the page's layout
/// manager, container and glyph range through ``drawBehindText`` and ``drawAboveText`` and can find
/// its lines the same way its editor does.
public final class AttributedTextPageSource: PrintPageSource {

    // MARK: - Page

    /// One laid-out page, as the drawing hooks see it.
    public struct Page {
        public let index: Int
        public let layoutManager: NSLayoutManager
        public let textContainer: NSTextContainer
        /// The glyphs on this page.
        public let glyphRange: NSRange
        /// The content area on the current graphics context. Container coordinates offset by
        /// `rect.origin` are drawing coordinates.
        public let rect: CGRect

        /// The rect of `characterRange`'s glyphs that fall on this page, in drawing coordinates, or
        /// `nil` when none of them do.
        public func boundingRect(forCharacterRange characterRange: NSRange) -> CGRect? {
            let glyphs = layoutManager.glyphRange(forCharacterRange: characterRange,
                                                  actualCharacterRange: nil)
            guard let onPage = glyphs.intersection(glyphRange), onPage.length > 0 else { return nil }
            let bounds = layoutManager.boundingRect(forGlyphRange: onPage, in: textContainer)
            guard bounds.height > 0 else { return nil }
            return bounds.offsetBy(dx: rect.minX, dy: rect.minY)
        }

        /// Whether the character at `index` is laid out on this page — the test for where a list
        /// marker belongs when its item breaks across two pages.
        public func contains(characterAt index: Int) -> Bool {
            guard index < layoutManager.textStorage?.length ?? 0 else { return false }
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            return NSLocationInRange(glyph, glyphRange)
        }
    }

    // MARK: - Hooks

    /// Drawn under the page's text.
    public var drawBehindText: ((Page) -> Void)?

    /// Drawn over the page's text.
    public var drawAboveText: ((Page) -> Void)?

    // MARK: - State

    private let textStorage: NSTextStorage
    private let layoutManager = NSLayoutManager()
    private var laidOutSize: CGSize?
    private var pages: [(container: NSTextContainer, glyphs: NSRange)] = []
    private let lock = NSLock()

    public init(text: NSAttributedString) {
        textStorage = NSTextStorage(attributedString: text)
        textStorage.addLayoutManager(layoutManager)
    }

    // MARK: - PrintPageSource

    public func pageCount(for contentSize: CGSize) -> Int {
        lock.lock(); defer { lock.unlock() }
        layOut(for: contentSize)
        return max(1, pages.count)
    }

    public func drawPage(at index: Int, in rect: CGRect) {
        lock.lock(); defer { lock.unlock() }
        layOut(for: rect.size)
        guard pages.indices.contains(index) else { return }

        let (container, glyphs) = pages[index]
        let page = Page(index: index, layoutManager: layoutManager, textContainer: container,
                        glyphRange: glyphs, rect: rect)

        drawBehindText?(page)
        if glyphs.length > 0 {
            layoutManager.drawBackground(forGlyphRange: glyphs, at: rect.origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphs, at: rect.origin)
        }
        drawAboveText?(page)
    }

    // MARK: - Layout

    /// Adds a page-sized container at a time until every glyph has somewhere to go.
    ///
    /// Re-done only when the size changes, which happens when the user changes paper or orientation
    /// in the dialog.
    private func layOut(for size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if let laidOutSize, laidOutSize == size { return }

        for index in layoutManager.textContainers.indices.reversed() {
            layoutManager.removeTextContainer(at: index)
        }
        pages = []
        laidOutSize = size

        let glyphCount = layoutManager.numberOfGlyphs
        var laidOut = 0
        repeat {
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            let glyphs = layoutManager.glyphRange(for: container)
            pages.append((container, glyphs))

            // A container that took nothing will never take anything: whatever is next is taller
            // than a page. Stop rather than add empty pages for ever; the rest is clipped.
            guard glyphs.length > 0 else {
                if pages.count > 1 { pages.removeLast() }
                break
            }
            laidOut = NSMaxRange(glyphs)
        } while laidOut < glyphCount
    }
}
