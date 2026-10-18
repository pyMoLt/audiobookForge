import XCTest
import PDFKit
@testable import AudiobookForge

final class PDFExtractorTests: XCTestCase {
    func testMetadataAndOutlineChapters() async throws {
        let url = TestPDFBuilder.makeSingleColumnBookWithOutline(
            title: "The Great Test Paper",
            author: "Ada Lovelace",
            chapters: [
                (title: "Introduction", body: "This is the introduction of the paper. It explains the motivation behind the research in clear prose."),
                (title: "Methodology", body: "This chapter describes the methodology used throughout the study, including data collection and analysis steps."),
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let extractor = PDFExtractor()
        let document = try await extractor.extract(from: url)

        let generatedPDF = PDFDocument(url: url)
        XCTAssertEqual(document.suggestedTitle, "The Great Test Paper")
        XCTAssertEqual(document.suggestedAuthor, "Ada Lovelace")
        XCTAssertEqual(document.chapters.count, 2, "pages=\(generatedPDF?.pageCount ?? -1), outlineChildren=\(generatedPDF?.outlineRoot?.numberOfChildren ?? -1), extracted=\(document.chapters.map { $0.title })")
        guard document.chapters.count >= 2 else { return }
        XCTAssertEqual(document.chapters[0].title, "Introduction")
        XCTAssertTrue(document.chapters[0].text.contains("motivation"))
        XCTAssertEqual(document.chapters[1].title, "Methodology")
        let normalizedChapterTwoText = document.chapters[1].text.replacingOccurrences(of: "\n", with: " ")
        XCTAssertTrue(normalizedChapterTwoText.contains("data collection"))
    }

    func testTwoColumnLayoutIsReadInColumnOrder() throws {
        let leftLines = (1...20).map { "Left column sentence number \($0)." }
        let rightLines = (1...20).map { "Right column sentence number \($0)." }
        let url = TestPDFBuilder.makeTwoColumnPage(leftLines: leftLines, rightLines: rightLines)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let document = PDFDocumentLoader.load(url), let page = document.page(at: 0) else {
            XCTFail("Could not load test PDF page")
            return
        }

        let extracted = PDFColumnTextExtractor.extractText(from: page)
        let leftIndex = extracted.range(of: "Left column sentence number 1.")
        let rightIndex = extracted.range(of: "Right column sentence number 1.")
        let leftLastIndex = extracted.range(of: "Left column sentence number 20.")

        XCTAssertNotNil(leftIndex)
        XCTAssertNotNil(rightIndex)
        XCTAssertNotNil(leftLastIndex)

        if let leftIndex, let rightIndex, let leftLastIndex {
            // The whole left column should be emitted before the right column
            // starts, even though on the page itself the lines are
            // horizontally interleaved.
            XCTAssertTrue(leftLastIndex.lowerBound < rightIndex.lowerBound)
            XCTAssertTrue(leftIndex.lowerBound < rightIndex.lowerBound)
        }
    }

    func testWholeDocumentFallbackWhenNoStructure() {
        let fullText = "Just a wall of text with no headings at all, repeated. " .repeated(20)
        let chapters = ChapterHeadingHeuristic.split(fullText: fullText)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].title, "Gesamtes Dokument")
    }

    func testHeadingHeuristicDetectsChapterMarkers() {
        let text = """
        Chapter 1
        This is the first chapter with enough body text to count as real content for the heuristic to latch onto.

        Chapter 2
        This is the second chapter, again with enough body text so it is not filtered out as noise by the heuristic.
        """
        let chapters = ChapterHeadingHeuristic.split(fullText: text)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertTrue(chapters[0].title.contains("Chapter 1"))
        XCTAssertTrue(chapters[1].title.contains("Chapter 2"))
    }
}

private extension String {
    func repeated(_ times: Int) -> String {
        String(repeating: self, count: times)
    }
}

enum PDFDocumentLoader {
    static func load(_ url: URL) -> PDFDocument? {
        PDFDocument(url: url)
    }
}

final class PDFFrontMatterTests: XCTestCase {
    func testNIHStyleLetterheadDoesNotBecomeTheTitleAndIsExcludedFromNarration() async throws {
        let url = TestPDFBuilder.makeNIHStyleReprint(
            title: "Nutlin-3a Activates p53 to Induce Senescence",
            bodyText: "Nutlin-3, an MDM2 inhibitor, activates p53, resulting in several types of cancer cells undergoing apoptosis. In this report, we found that nutlin-3a can induce senescence in normal human fibroblasts. This finding has implications for cancer therapy and highlights the role of p53 in regulating cellular senescence pathways in response to pharmacological activation."
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let extractor = PDFExtractor()
        let document = try await extractor.extract(from: url)

        XCTAssertEqual(document.suggestedTitle, "Nutlin-3a Activates p53 to Induce Senescence")

        let fullText = document.chapters.map(\.text).joined(separator: "\n")
        XCTAssertFalse(fullText.contains("NIH Public Access"), "Letterhead banner should not be narrated")
        XCTAssertFalse(fullText.contains("Author Manuscript"), "Letterhead sub-line should not be narrated")
        XCTAssertFalse(fullText.contains("Jane A. Researcher"), "Author names should not be narrated")
        XCTAssertFalse(fullText.contains("Requests for reprints"), "Footnote block should not be narrated")
        XCTAssertTrue(fullText.contains("apoptosis"), "Real abstract/body content should still be present")
    }

    func testBookTitlePageFrontMatterTrimmedWithoutAbstractHeading() async throws {
        let url = TestPDFBuilder.makeBookStyleTitlePage(
            title: "The Long Voyage Home",
            author: "A. N. Author",
            bodyText: "The ship left port at dawn, its sails catching the first light of morning as the crew prepared for the long journey ahead across the wide and restless sea toward distant shores none of them had ever seen before, and no one aboard could say for certain when, or whether, they would ever return home again to the harbor they had known since childhood."
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let extractor = PDFExtractor()
        let document = try await extractor.extract(from: url)

        let fullText = document.chapters.map(\.text).joined(separator: "\n")
        XCTAssertFalse(fullText.contains("Fictional Press"), "Publisher imprint should not be narrated")
        XCTAssertFalse(fullText.contains("All rights reserved"), "Copyright line should not be narrated")
        XCTAssertTrue(fullText.contains("left port at dawn"), "Real body content should still be present")
    }
}
