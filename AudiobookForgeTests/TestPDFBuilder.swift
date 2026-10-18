import Foundation
import PDFKit
import AppKit

/// Builds small, synthetic PDFs for testing PDFExtractor without depending
/// on real-world test documents.
enum TestPDFBuilder {
    static func makeSingleColumnBookWithOutline(title: String, author: String, chapters: [(title: String, body: String)]) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)

        var info: [CFString: Any] = [
            kCGPDFContextTitle: title,
            kCGPDFContextAuthor: author,
        ]
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            fatalError("Could not create PDF context")
        }

        let bodyAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 18)]

        for chapter in chapters {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.current = nsContext

            let titleString = NSAttributedString(string: chapter.title, attributes: titleAttributes)
            titleString.draw(at: CGPoint(x: 72, y: 700))

            let bodyString = NSAttributedString(string: chapter.body, attributes: bodyAttributes)
            let framesetter = CTFramesetterCreateWithAttributedString(bodyString)
            let path = CGPath(rect: CGRect(x: 72, y: 72, width: 468, height: 600), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, context)

            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()

        // Add an outline (table of contents) after the fact via PDFKit, since
        // CGPDFContext has no direct outline API.
        guard let document = PDFDocument(url: url) else { return url }
        let root = PDFOutline()
        document.outlineRoot = root
        for (index, chapter) in chapters.enumerated() {
            guard let page = document.page(at: index) else { continue }
            let destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 792))
            let outlineItem = PDFOutline()
            outlineItem.label = chapter.title
            outlineItem.destination = destination
            root.insertChild(outlineItem, at: index)
        }
        document.write(to: url)

        return url
    }

    static func makeTwoColumnPage(leftLines: [String], rightLines: [String]) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-2col-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fatalError("Could not create PDF context")
        }

        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext

        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        var y: CGFloat = 720
        for line in leftLines {
            NSAttributedString(string: line, attributes: attributes).draw(at: CGPoint(x: 60, y: y))
            y -= 20
        }
        y = 720
        for line in rightLines {
            NSAttributedString(string: line, attributes: attributes).draw(at: CGPoint(x: 320, y: y))
            y -= 20
        }

        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// Mimics the very common NIH/PMC "author manuscript" reprint layout:
    /// a large repository-banner box at the very top (taller than the real
    /// title), a title, an author/affiliation block, an "Abstract" heading,
    /// abstract + body text, and a small-font footnote block at the bottom.
    /// Used to test that title detection isn't fooled by the banner and
    /// that narration skips the letterhead/author block and the footnote.
    static func makeNIHStyleReprint(title: String, bodyText: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-nih-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fatalError("Could not create PDF context")
        }

        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext

        let bannerAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .bold)]
        NSAttributedString(string: "NIH Public Access", attributes: bannerAttributes).draw(at: CGPoint(x: 72, y: 760))

        let smallAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        NSAttributedString(string: "Author Manuscript", attributes: smallAttributes).draw(at: CGPoint(x: 72, y: 730))
        NSAttributedString(string: "Cancer Res. Author manuscript; available in PMC 2009 May 1.", attributes: smallAttributes).draw(at: CGPoint(x: 72, y: 710))

        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .bold)]
        NSAttributedString(string: title, attributes: titleAttributes).draw(at: CGPoint(x: 72, y: 650))

        NSAttributedString(string: "Jane A. Researcher, John B. Scientist, and Kim C. Investigator", attributes: smallAttributes).draw(at: CGPoint(x: 72, y: 610))
        NSAttributedString(string: "Department of Something, University of Somewhere", attributes: smallAttributes).draw(at: CGPoint(x: 72, y: 592))

        let headingAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .bold)]
        NSAttributedString(string: "Abstract", attributes: headingAttributes).draw(at: CGPoint(x: 72, y: 550))

        let bodyString = NSAttributedString(string: bodyText, attributes: smallAttributes)
        let framesetter = CTFramesetterCreateWithAttributedString(bodyString)
        let path = CGPath(rect: CGRect(x: 72, y: 100, width: 468, height: 430), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)

        let footnoteAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 7)]
        NSAttributedString(string: "Requests for reprints: Jane A. Researcher, test@example.com", attributes: footnoteAttributes).draw(at: CGPoint(x: 72, y: 40))
        NSAttributedString(string: "Note: Supplementary data for this article are available online.", attributes: footnoteAttributes).draw(at: CGPoint(x: 72, y: 28))

        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// A non-paper title page: title, author, publisher imprint line — no
    /// "Abstract" anywhere. Used to test that front-matter trimming still
    /// works via the generic body-text-run detector alone, not just the
    /// paper-specific "Abstract" fast path.
    static func makeBookStyleTitlePage(title: String, author: String, bodyText: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-book-titlepage-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fatalError("Could not create PDF context")
        }

        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext

        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .bold)]
        NSAttributedString(string: title, attributes: titleAttributes).draw(at: CGPoint(x: 72, y: 650))

        let smallAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        NSAttributedString(string: "by \(author)", attributes: smallAttributes).draw(at: CGPoint(x: 72, y: 600))
        NSAttributedString(string: "Fictional Press, Some City", attributes: smallAttributes).draw(at: CGPoint(x: 72, y: 580))
        NSAttributedString(string: "Copyright \u{00A9} 2024. All rights reserved.", attributes: smallAttributes).draw(at: CGPoint(x: 72, y: 560))

        let bodyString = NSAttributedString(string: bodyText, attributes: smallAttributes)
        let framesetter = CTFramesetterCreateWithAttributedString(bodyString)
        let path = CGPath(rect: CGRect(x: 72, y: 100, width: 468, height: 430), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)

        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()

        // A plain second page of ordinary body text, so the front-matter
        // detector has a reliable page to estimate "normal" body size from.
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        let nsContext2 = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext2
        let page2Body = NSAttributedString(string: bodyText + " " + bodyText, attributes: smallAttributes)
        let framesetter2 = CTFramesetterCreateWithAttributedString(page2Body)
        let path2 = CGPath(rect: CGRect(x: 72, y: 100, width: 468, height: 600), transform: nil)
        let frame2 = CTFramesetterCreateFrame(framesetter2, CFRange(location: 0, length: 0), path2, nil)
        CTFrameDraw(frame2, context)
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()

        context.closePDF()
        return url
    }
}
