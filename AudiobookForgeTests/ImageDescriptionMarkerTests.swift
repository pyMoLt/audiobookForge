import XCTest
@testable import AudiobookForge

final class ImageDescriptionMarkerTests: XCTestCase {
    private let pdfRef = FigureReference(source: .pdf, page: 4, rect: [10, 20, 200, 150], kind: "raster", caption: "Abb. 6.8 Apoptose.", pixelWidth: 800, pixelHeight: 600, encodedBytes: 90_000)

    func testPlaceholderRoundTripsReferenceInReadingOrder() {
        let epubRef = FigureReference(source: .epub, path: "OEBPS/img/fig1.jpg", caption: nil, altText: "Niere")
        let text = "Erster Absatz.\n\n" + ImageDescriptionMarker.placeholder(for: pdfRef) + "\n\nZweiter.\n\n" + ImageDescriptionMarker.placeholder(for: epubRef)
        let figures = ImageDescriptionMarker.figures(in: text)
        XCTAssertEqual(figures.map(\.ref), [pdfRef, epubRef])
        XCTAssertTrue(figures.allSatisfy { $0.existing == nil })
    }

    func testDescriptionLandsExactlyAtTheFigurePosition() {
        let text = "Vorher.\n\n" + ImageDescriptionMarker.placeholder(for: pdfRef) + "\n\nNachher."
        let resolved = ImageDescriptionMarker.resolveFigures(in: text) { _, _ in .describe("Abbildung: Ein Makrophage frisst Zelltrümmer.", .full) }
        XCTAssertEqual(ImageDescriptionMarker.unwrap(resolved), "Vorher.\n\nAbbildung: Ein Makrophage frisst Zelltrümmer.\n\nNachher.")
        XCTAssertEqual(ImageDescriptionMarker.stripBlocks(from: resolved), "Vorher.\n\nNachher.")
        // Stored description is recognized again (cache) with its length.
        XCTAssertEqual(ImageDescriptionMarker.figures(in: resolved).first?.existing, .full)
        XCTAssertEqual(ImageDescriptionMarker.existingDescription(for: pdfRef, in: resolved), "Abbildung: Ein Makrophage frisst Zelltrümmer.")
    }

    func testKeepAndRemove() {
        let text = "A.\n\n" + ImageDescriptionMarker.placeholder(for: pdfRef) + "\n\nB."
        let kept = ImageDescriptionMarker.resolveFigures(in: text) { _, _ in .keep }
        XCTAssertEqual(ImageDescriptionMarker.figures(in: kept).count, 1)
        let removed = ImageDescriptionMarker.resolveFigures(in: text) { _, _ in .remove }
        XCTAssertEqual(removed, "A.\n\nB.")
    }

    func testUnwrapAndStripRemoveUndescribedPlaceholders() {
        let text = "A.\n\n" + ImageDescriptionMarker.placeholder(for: pdfRef) + "\n\nB."
        XCTAssertEqual(ImageDescriptionMarker.unwrap(text), "A.\n\nB.")
        XCTAssertEqual(ImageDescriptionMarker.stripBlocks(from: text), "A.\n\nB.")
        XCTAssertEqual(ImageDescriptionMarker.displayText(text), "A.\n\n[Abbildung (Seite 5)]\n\nB.")
    }

    func testLegacyBlocksStillUnwrap() {
        let text = "Body." + ImageDescriptionMarker.wrap("A bar chart.")
        XCTAssertEqual(ImageDescriptionMarker.unwrap(text), "Body.\n\nA bar chart.")
        XCTAssertEqual(ImageDescriptionMarker.stripBlocks(from: text), "Body.")
    }

    func testPlainTextUnchanged() {
        let plain = "No figures here."
        XCTAssertEqual(ImageDescriptionMarker.unwrap(plain), plain)
        XCTAssertEqual(ImageDescriptionMarker.stripBlocks(from: plain), plain)
    }
}
