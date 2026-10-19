import XCTest
import AppKit
@testable import AudiobookForge

/// v3.2 regression: a plain PDF (one font size, heading on top, no
/// metadata) got a body paragraph as its title — the column extractor's
/// "lines" are whole paragraph blocks and the tallest block won.
final class PDFTitleDetectionTests: XCTestCase {
    private func makePlainPDF(heading: String, paragraphs: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("title-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let font = NSFont(name: "Courier", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        var y: CGFloat = 760
        for block in [heading] + paragraphs {
            let text = NSAttributedString(string: block, attributes: [.font: font])
            let rect = text.boundingRect(with: CGSize(width: 520, height: 400), options: [.usesLineFragmentOrigin])
            y -= rect.height
            text.draw(with: CGRect(x: 46, y: y, width: 520, height: rect.height), options: [.usesLineFragmentOrigin])
            y -= 16
        }
        NSGraphicsContext.current = nil
        context.endPDFPage()
        context.closePDF()
        return url
    }

    func testPlainPDFUsesHeadingNotParagraph() async throws {
        let url = try makePlainPDF(heading: "Warum wir Geschichten gern hören", paragraphs: [
            "Seit es Menschen gibt, erzählen sie einander Geschichten. Lange bevor jemand das erste Wort aufschrieb, wurden Sagen am Feuer weitergegeben, von einer Generation zur nächsten.",
            "Ein Hörbuch knüpft genau daran an. Die Stimme gibt dem Text einen Rhythmus, setzt Pausen und Betonungen und lässt die Figuren lebendig werden. Viele Menschen hören beim Spazierengehen, auf dem Weg zur Arbeit oder abends kurz vor dem Einschlafen.",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await PDFExtractor().extract(from: url)
        XCTAssertEqual(document.suggestedTitle, "Warum wir Geschichten gern hören")
    }

    func testSentenceLikeTextIsNoTitle() {
        XCTAssertTrue(PDFExtractor.looksLikeTitle("Attention Is All You Need"))
        XCTAssertFalse(PDFExtractor.looksLikeTitle("Ein Hörbuch knüpft genau daran an. Die Stimme gibt dem Text einen Rhythmus."))
    }
}
