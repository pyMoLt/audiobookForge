import XCTest
@testable import AudiobookForge

final class HeaderFooterStripperTests: XCTestCase {
    func testStripsRecurringPageNumberFooter() {
        let pages = (1...6).map { page in
            "Some heading text\nBody paragraph line one.\nBody paragraph line two.\nPage \(page) of 6"
        }

        let stripped = HeaderFooterStripper.strip(pageTexts: pages)
        for text in stripped {
            XCTAssertFalse(text.contains("Page"), "Expected recurring footer to be stripped, got: \(text)")
        }
    }

    func testKeepsUniqueContentUntouched() {
        let pages = [
            "Unique first page content that should stay exactly as is.",
            "Unique second page content that should also remain untouched.",
        ]
        let stripped = HeaderFooterStripper.strip(pageTexts: pages)
        XCTAssertEqual(stripped, pages)
    }
}

final class SummarizerChunkingTests: XCTestCase {
    func testShortTextIsSingleChunk() {
        let text = "A short paragraph.\n\nAnother short paragraph."
        let chunks = SummarizerClient.chunk(text: text, maxCharacters: 1000)
        XCTAssertEqual(chunks.count, 1)
    }

    func testLongTextIsSplitOnParagraphBoundaries() {
        let paragraph = String(repeating: "word ", count: 200) // ~1000 chars
        let text = Array(repeating: paragraph, count: 10).joined(separator: "\n\n")
        let chunks = SummarizerClient.chunk(text: text, maxCharacters: 3000)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 3000 + paragraph.count)
        }
        XCTAssertEqual(chunks.joined().count > 0, true)
    }
}
