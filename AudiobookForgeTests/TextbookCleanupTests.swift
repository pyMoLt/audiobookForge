import AppKit
import CoreText
import PDFKit
import XCTest
@testable import AudiobookForge

/// A small synthetic "textbook" with every layout problem found in a real
/// 714-page histology textbook: running heads, page numbers, a photo with
/// printed labels and a caption, a drawn schema with labels, line-end
/// hyphenation, a ligature, a sentence running across a page break, and
/// numbered headings.
enum TextbookPDFBuilder {
    static var body: NSFont { NSFont.systemFont(ofSize: 10) }
    static var heading: NSFont { NSFont.boldSystemFont(ofSize: 16) }
    static var subheading: NSFont { NSFont.boldSystemFont(ofSize: 13) }
    static var label: NSFont { NSFont.systemFont(ofSize: 8) }
    static var caption: NSFont { NSFont.systemFont(ofSize: 9) }

    static let prose = "Das ist ein ganz normaler Satz im Fließtext dieses Testlehrbuchs, gesetzt in"

    static func make() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("textbook-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 420, height: 600)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!

        func page(_ number: Int, _ draw: (CGContext) -> Void) {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            text("Testbuch Histologie", at: CGPoint(x: 40, y: 575), font: label)       // running head
            text("\(number)", at: CGPoint(x: 205, y: 20), font: label)                // page number
            text("1", at: CGPoint(x: 410, y: 300), font: label)                       // thumb tab
            draw(context)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }

        // Cover page: the PDF importer treats page 1's largest line as the
        // book title (real textbooks open with a cover).
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text("Testbuch Histologie", at: CGPoint(x: 60, y: 400), font: NSFont.boldSystemFont(ofSize: 28))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()

        page(1) { _ in
            text("1 Einleitung in die Zellbiologie", at: CGPoint(x: 40, y: 530), font: heading)
            var y: CGFloat = 505
            for _ in 0..<24 { text(prose, at: CGPoint(x: 40, y: y), font: body); y -= 13 }
            text("Hier steht ein Wort mit Silbentrennung, die Differen-", at: CGPoint(x: 40, y: y), font: body); y -= 13
            text("zierung der Zellen ist betroﬀen und bleibt ein Thema.", at: CGPoint(x: 40, y: y), font: body); y -= 13
            text("Dieser Satz endet nicht auf dieser Seite, sondern geht auf der nächsten", at: CGPoint(x: 40, y: y), font: body)
        }

        page(2) { context in
            // Photo (noise, so it doesn't compress below the KB filter) with
            // printed labels, then its caption.
            let photo = CGRect(x: 60, y: 330, width: 300, height: 220)
            context.draw(noiseImage(width: 600, height: 440), in: photo)
            text("rER", at: CGPoint(x: 90, y: 500), font: label)
            text("N*", at: CGPoint(x: 200, y: 420), font: label)
            text("MP", at: CGPoint(x: 300, y: 360), font: label)
            text("Abb. 1.1 Testbild mit Zellen und Organellen.", at: CGPoint(x: 60, y: 312), font: caption)
            text("Seite weiter und endet erst hier.", at: CGPoint(x: 40, y: 285), font: body)
            text("1.1 Erster Abschnitt", at: CGPoint(x: 40, y: 255), font: subheading)
            var y: CGFloat = 235
            for _ in 0..<14 { text(prose, at: CGPoint(x: 40, y: y), font: body); y -= 13 }
            text("Ende des ersten Abschnitts.", at: CGPoint(x: 40, y: y), font: body)
        }

        page(3) { context in
            text("1.2 Zweiter Abschnitt", at: CGPoint(x: 40, y: 540), font: subheading)
            var y: CGFloat = 520
            for _ in 0..<6 { text(prose, at: CGPoint(x: 40, y: y), font: body); y -= 13 }
            text("Ende des Absatzes vor dem Schema.", at: CGPoint(x: 40, y: y), font: body)
            // Drawn schema: boxes and connecting lines with labels.
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1)
            for row in 0..<3 {
                for column in 0..<3 {
                    context.stroke(CGRect(x: 80 + CGFloat(column) * 90, y: 240 + CGFloat(row) * 50, width: 60, height: 30))
                }
                context.move(to: CGPoint(x: 140, y: 255 + CGFloat(row) * 50)); context.addLine(to: CGPoint(x: 170, y: 255 + CGFloat(row) * 50)); context.strokePath()
            }
            text("ZA", at: CGPoint(x: 100, y: 250), font: label)
            text("ZO", at: CGPoint(x: 190, y: 300), font: label)
            text("GL", at: CGPoint(x: 280, y: 350), font: label)
            text("Abb. 1.2 Schema der Zellkontakte.", at: CGPoint(x: 80, y: 222), font: caption)
            y = 195
            for _ in 0..<6 { text(prose, at: CGPoint(x: 40, y: y), font: body); y -= 13 }
            text("Schluss.", at: CGPoint(x: 40, y: y), font: body)
        }
        context.closePDF()
        return url
    }

    private static func text(_ string: String, at point: CGPoint, font: NSFont) {
        NSAttributedString(string: string, attributes: [.font: font]).draw(at: point)
    }

    private static func noiseImage(width: Int, height: Int) -> CGImage {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
            bytes[index + 1] = UInt8.random(in: 0...255, using: &generator)
            bytes[index + 2] = UInt8.random(in: 0...255, using: &generator)
            bytes[index + 3] = 255
        }
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}

final class TextbookCleanupTests: XCTestCase {
    // MARK: Whole synthetic textbook

    func testSyntheticTextbookIsCleanedAndFiguresArePlacedAtParagraphEnds() async throws {
        let url = TextbookPDFBuilder.make()
        defer { try? FileManager.default.removeItem(at: url) }
        var settings = AppSettings()
        settings.minimumImageKilobytes = 8
        let extracted = try await PDFExtractor(settings: settings).extract(from: url)
        let marked = extracted.chapters.map(\.text).joined(separator: "\n\n")
        let plain = ImageDescriptionMarker.stripPlaceholders(from: marked)
        let flat = plain.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        // Labels, running head, page numbers and thumb tab are gone.
        for junk in ["rER", "N*", "MP", "ZA", "ZO", "GL", "Testbuch Histologie"] {
            XCTAssertFalse(plain.contains(junk), "\(junk) should not be narrated: \(plain)")
        }
        XCTAssertFalse(plain.components(separatedBy: "\n").contains { ["1", "2", "3"].contains($0.trimmingCharacters(in: .whitespaces)) })
        // Hyphenation and ligature.
        XCTAssertTrue(flat.contains("die Differenzierung der Zellen ist betroffen"), flat)
        // The sentence crossing the page break is not interrupted by the
        // figure and its caption.
        XCTAssertTrue(flat.contains("geht auf der nächsten Seite weiter und endet erst hier."), flat)
        // Captions are kept.
        XCTAssertTrue(flat.contains("Abb. 1.1 Testbild mit Zellen und Organellen."))
        XCTAssertTrue(flat.contains("Abb. 1.2 Schema der Zellkontakte."))

        // Two figures (photo + drawn schema), each placed right after its
        // caption, never mid-sentence.
        let figures = ImageDescriptionMarker.figures(in: marked)
        XCTAssertEqual(figures.count, 2, "\(figures.map(\.ref))")
        XCTAssertEqual(figures.first?.ref.kind, "raster")
        XCTAssertEqual(figures.first?.ref.caption, "Abb. 1.1 Testbild mit Zellen und Organellen.")
        XCTAssertEqual(figures.last?.ref.kind, "vector")
        XCTAssertEqual(figures.first?.ref.page, 2)
        let resolved = ImageDescriptionMarker.resolveFigures(in: marked) { ref, _ in .describe("BILD(\(ref.caption ?? "?"))", .full) }
        let narration = ImageDescriptionMarker.unwrap(resolved).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        XCTAssertTrue(narration.contains("endet erst hier. Abb. 1.1 Testbild mit Zellen und Organellen. BILD(Abb. 1.1"), narration)
        XCTAssertTrue(narration.contains("Abb. 1.2 Schema der Zellkontakte. BILD(Abb. 1.2"), narration)

        // Numbered headings give the chapter structure.
        XCTAssertEqual(extracted.chapters.map(\.title), ["1 Einleitung in die Zellbiologie", "1.1 Erster Abschnitt", "1.2 Zweiter Abschnitt"])
    }

    func testSmallImagesAndLogosAreNotFigures() async throws {
        let url = TextbookPDFBuilder.make()
        defer { try? FileManager.default.removeItem(at: url) }
        var settings = AppSettings()
        settings.minimumImageDimensionForVisionPass = 2000 // photo is 600×440 px
        settings.detectVectorFigures = false
        let extracted = try await PDFExtractor(settings: settings).extract(from: url)
        let figures = ImageDescriptionMarker.figures(in: extracted.chapters.map(\.text).joined())
        // Only the caption-inferred region of figure 1.1 is left (the
        // photo itself fails the pixel filter); never the tiny labels.
        XCTAssertTrue(figures.allSatisfy { $0.ref.kind == "vector" })
    }

    // MARK: Building blocks

    func testDehyphenation() {
        XCTAssertEqual(PDFColumnTextExtractor.dehyphenatedJoin("die Differen-", next: "zierung der"), "die Differen")
        XCTAssertEqual(PDFColumnTextExtractor.dehyphenatedJoin("die DNA-", next: "Fehler werden"), "die DNA-")
        XCTAssertEqual(PDFColumnTextExtractor.dehyphenatedJoin("Ein-", next: "und Ausgang"), "Ein- ")
        XCTAssertNil(PDFColumnTextExtractor.dehyphenatedJoin("Werte 3-", next: "5 Tage"))
        XCTAssertNil(PDFColumnTextExtractor.dehyphenatedJoin("normale Zeile", next: "weiter"))
        let lines = [
            PDFColumnTextExtractor.Line(text: "Die Differen-", bounds: CGRect(x: 0, y: 20, width: 100, height: 10)),
            PDFColumnTextExtractor.Line(text: "zierung ist wichtig.", bounds: CGRect(x: 0, y: 10, width: 100, height: 10), endsParagraph: true),
        ]
        XCTAssertEqual(PDFColumnTextExtractor.joinedText(lines), "Die Differenzierung ist wichtig.")
    }

    func testLineNormalization() {
        XCTAssertEqual(PDFTextbookCleaner.normalizeLineText("betroﬀen und ﬁnden"), "betroffen und finden")
        XCTAssertEqual(PDFTextbookCleaner.normalizeLineText("Funktion: ( a) Gene"), "Funktion: (a) Gene")
        XCTAssertEqual(PDFTextbookCleaner.normalizeLineText("eines zellulären„Unfalls“"), "eines zellulären „Unfalls“")
        XCTAssertEqual(PDFTextbookCleaner.normalizeLineText("M e r k e"), "Merke")
        XCTAssertEqual(PDFTextbookCleaner.normalizeLineText("I M P P - H i t s"), "IMPP-Hits")
        XCTAssertEqual(PDFTextbookCleaner.normalizeLineText("1 1"), "11")
        XCTAssertEqual(PDFTextbookCleaner.normalizeLineText("a b"), "a b", "two-letter panel labels stay")
    }

    func testCrossReferencesAreRemovedButContentKept() {
        let text = "Die Apoptose ist ein programmierter Zelltod (▶ Abb. 6.8). Siehe Thymozyten (S. 403). Makrophagen (vgl. Kap. 3.2) und Tumoren (z. B. Adenom)."
        XCTAssertEqual(PDFTextbookCleaner.removeCrossReferences(text), "Die Apoptose ist ein programmierter Zelltod. Siehe Thymozyten. Makrophagen und Tumoren (z. B. Adenom).")
    }

    func testNumberedHeadingParsing() {
        XCTAssertEqual(PDFNumberedHeadingDetector.parse("6.4.2 Zelltod")?.number, [6, 4, 2])
        XCTAssertEqual(PDFNumberedHeadingDetector.parse("7Epithelgewebe")?.title, "Epithelgewebe")
        XCTAssertNotNil(PDFNumberedHeadingDetector.parse("6.3 Zelldifferenzierung, Zellumsatz,"))
        XCTAssertNil(PDFNumberedHeadingDetector.parse("5 Zellorganellen und Zytosol . . . . . . 63"))
        XCTAssertNil(PDFNumberedHeadingDetector.parse("7 Tage nach der Ovulation verdämmert es."))
        XCTAssertNil(PDFNumberedHeadingDetector.parse("7 Epithelgewebe 127"))
    }

    func testTinyLabelClusters() {
        let labels = ["EZR", "Na+", "IZR", "K+"].enumerated().map { index, text in
            PDFColumnTextExtractor.Line(text: text, bounds: CGRect(x: 100 + CGFloat(index) * 20, y: 300, width: 15, height: 8))
        }
        let prose = PDFColumnTextExtractor.Line(text: "Ein ganz normaler Satz mit vielen Wörtern.", bounds: CGRect(x: 40, y: 100, width: 300, height: 10))
        XCTAssertEqual(PDFTextbookCleaner.labelClusters(in: labels + [prose]).count, 1)
        XCTAssertTrue(PDFTextbookCleaner.labelClusters(in: Array(labels.prefix(2)) + [prose]).isEmpty, "two labels are not a figure")
        XCTAssertFalse(PDFTextbookCleaner.isTinyLabel("dar."))
    }

    // MARK: EPUB

    func testEPUBTableIsReadRowByRow() throws {
        let html = """
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <p>Beispiele:</p>
        <table><tr><td>Formel</td><td>Name</td></tr>
        <tr><td>NaHCO3</td><td>Natron</td></tr>
        <tr><td>BaSO4</td><td>Bariumsulfat</td></tr></table>
        </body></html>
        """
        XCTAssertEqual(EPUBHTMLTextExtractor.extractText(from: Data(html.utf8)), "Beispiele:\n\nFormel: NaHCO3, Name: Natron.\n\nFormel: BaSO4, Name: Bariumsulfat.")
    }

    func testEPUBImagesBecomeFiguresAtTheirPositionWithCaptionAndSizeFilter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epub-\(UUID().uuidString)", isDirectory: true)
        let images = root.appendingPathComponent("OEBPS/img", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try pngData(width: 640, height: 480, noise: true).write(to: images.appendingPathComponent("niere.png"))
        try pngData(width: 32, height: 32, noise: false).write(to: images.appendingPathComponent("icon.png"))
        let html = """
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <p>Vorher <img src="img/icon.png" alt="Pfeil"/> ein Satz.</p>
        <figure><img src="img/niere.png" alt="Niere im Schnitt"/><figcaption>Abb. 3 Niere.</figcaption></figure>
        <p>Nachher.</p>
        </body></html>
        """
        let document = root.appendingPathComponent("OEBPS/kapitel.xhtml")
        let context = EPUBHTMLTextExtractor.ImageContext(documentURL: document, archiveRoot: root, thresholds: PDFFigureDetector.Thresholds(minimumPixelSize: 180, minimumAreaFraction: 0, minimumKilobytes: 8, maximumAspectRatio: 6, detectVectorFigures: false))
        let text = EPUBHTMLTextExtractor.extractText(from: Data(html.utf8), images: context)
        let figures = ImageDescriptionMarker.figures(in: text)
        XCTAssertEqual(figures.count, 1, "the 32 px icon is filtered out")
        XCTAssertEqual(figures.first?.ref.path, "OEBPS/img/niere.png")
        XCTAssertEqual(figures.first?.ref.altText, "Niere im Schnitt")
        XCTAssertEqual(figures.first?.ref.caption, "Abb. 3 Niere.")
        XCTAssertEqual(ImageDescriptionMarker.displayText(text), "Vorher ein Satz.\n\n[Abbildung]\n\nAbb. 3 Niere.\n\nNachher.")
        XCTAssertNotNil(FigureImageLoader.loadArchiveImage(archiveRoot: root, path: "OEBPS/img/niere.png"))
    }

    func testPDFRegionRendering() throws {
        let url = TextbookPDFBuilder.make()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let jpeg = try XCTUnwrap(FigureImageLoader.renderPDFRegion(document: document, pageIndex: 2, rect: CGRect(x: 60, y: 330, width: 300, height: 220)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        // 300 pt + 2×4 pt margin, upscaled at most 4× (beyond that only blur).
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 1232)
    }

    func testFillerOpeningsAreRemovedFromDescriptions() {
        XCTAssertEqual(PipelineController.withoutFillerOpening("Die Abbildung zeigt zwei Mitochondrien."), "Zwei Mitochondrien.")
        XCTAssertEqual(PipelineController.withoutFillerOpening("The image shows a kidney."), "A kidney.")
        XCTAssertEqual(PipelineController.withoutFillerOpening("Zwei Elektronenmikroskop-Aufnahmen."), "Zwei Elektronenmikroskop-Aufnahmen.")
    }

    private func pngData(width: Int, height: Int, noise: Bool) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<width { for y in 0..<height {
            let value = noise ? CGFloat.random(in: 0...1) : 0.5
            rep.setColor(NSColor(deviceRed: value, green: noise ? CGFloat.random(in: 0...1) : 0.5, blue: 0.5, alpha: 1), atX: x, y: y)
        } }
        return rep.representation(using: .png, properties: [:])!
    }
}
