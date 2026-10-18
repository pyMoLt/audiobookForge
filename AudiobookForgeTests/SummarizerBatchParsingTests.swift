import XCTest
@testable import AudiobookForge

final class SummarizerBatchParsingTests: XCTestCase {
    // MARK: - parseHeadedSections

    func testParsesWellFormedHeadedSections() {
        let response = """
        ## First Topic
        Condensed text for the first section.

        ## Second Topic
        Condensed text for the second section.
        """

        let sections = SummarizerClient.parseHeadedSections(response)

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].heading, "First Topic")
        XCTAssertEqual(sections[0].text, "Condensed text for the first section.")
        XCTAssertEqual(sections[1].heading, "Second Topic")
        XCTAssertEqual(sections[1].text, "Condensed text for the second section.")
    }

    func testPrefersH2OverH3ToAvoidOverfragmentation() {
        let response = """
        # Attention Is All You Need

        ## 1. Introduction
        Main intro text.
        ### 1.1 Background
        Detailed background prose that belongs inside the introduction.

        ## 2. Model Architecture
        Architecture overview.
        ### 2.1 Multi-Head Attention
        Specific attention equations.
        """

        let sections = SummarizerClient.parseHeadedSections(response)

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].heading, "1. Introduction")
        XCTAssertTrue(sections[0].text.contains("Detailed background prose"))
        XCTAssertEqual(sections[1].heading, "2. Model Architecture")
        XCTAssertTrue(sections[1].text.contains("Specific attention equations"))
    }

    func testNoHeadingsReturnsEmptyArray() {
        let response = "Just plain condensed prose, no headings at all."
        XCTAssertTrue(SummarizerClient.parseHeadedSections(response).isEmpty)
    }

    func testPreambleBeforeFirstHeadingIsDiscarded() {
        let response = """
        Sure, here is the condensed text:

        ## Only This Counts
        Everything after the heading.
        """

        let sections = SummarizerClient.parseHeadedSections(response)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].heading, "Only This Counts")
        XCTAssertEqual(sections[0].text, "Everything after the heading.")
    }

    func testHeadingRequiresSpaceAfterHashesToAvoidFalsePositives() {
        // A literal "##something" (no space) or "###" run inside prose
        // should not be mistaken for a real heading.
        let response = """
        ## Real Heading
        Some text with ##nospace inline should not split anything.
        """

        let sections = SummarizerClient.parseHeadedSections(response)

        XCTAssertEqual(sections.count, 1)
        XCTAssertTrue(sections[0].text.contains("##nospace"))
    }

    func testEmptyResponseYieldsNoSections() {
        XCTAssertTrue(SummarizerClient.parseHeadedSections("").isEmpty)
    }

    // MARK: - sanitizeHeadingMarkers

    func testSanitizeRemovesRunsOfTwoOrMoreHashes() {
        let text = "Section 2.1 ## Overview\nSome prose with ### three hashes."
        let sanitized = SummarizerClient.sanitizeHeadingMarkers(text)

        XCTAssertFalse(sanitized.contains("##"))
        XCTAssertFalse(sanitized.contains("###"))
        XCTAssertTrue(sanitized.contains("Overview"))
    }

    func testSanitizeLeavesSingleHashAlone() {
        let text = "Room #42 is down the hall."
        XCTAssertEqual(SummarizerClient.sanitizeHeadingMarkers(text), text)
    }

    func testSanitizeLeavesPlainTextUnaffected() {
        let text = "Nothing unusual in this paragraph at all."
        XCTAssertEqual(SummarizerClient.sanitizeHeadingMarkers(text), text)
    }

    // MARK: - buildBatches

    func testBookDocumentTypeAlwaysGetsOneChapterPerBatch() {
        let chapters = [
            (title: "Stave One", text: String(repeating: "a", count: 100)),
            (title: "Stave Two", text: String(repeating: "b", count: 100)),
            (title: "Stave Three", text: String(repeating: "c", count: 100)),
        ]

        let batches = SummarizerClient.buildBatches(chapters: chapters, documentType: .book, budget: 100_000)

        XCTAssertEqual(batches, [[0], [1], [2]])
    }

    func testPaperCombinesShortSectionsIntoOneBatchWhenTheyAllFit() {
        let chapters = [
            (title: "Abstract", text: String(repeating: "a", count: 1000)),
            (title: "Introduction", text: String(repeating: "b", count: 1000)),
            (title: "Conclusion", text: String(repeating: "c", count: 1000)),
        ]

        let batches = SummarizerClient.buildBatches(chapters: chapters, documentType: .paper, budget: 10_000)

        XCTAssertEqual(batches, [[0, 1, 2]])
    }

    func testSmallTrailingRemainderIsFoldedIntoASingleBatchNotItsOwnCall() {
        // Total is just over budget (75,400 vs. 75,000) -- per the ±15%
        // tolerance this should still resolve to ONE batch rather than a
        // second call for a tiny 400-character leftover.
        let chapters = [
            (title: "Part A", text: String(repeating: "a", count: 75_000)),
            (title: "Part B", text: String(repeating: "b", count: 400)),
        ]

        let batches = SummarizerClient.buildBatches(chapters: chapters, documentType: .paper, budget: 75_000)

        XCTAssertEqual(batches, [[0, 1]])
    }

    func testLongDocumentSplitsIntoEvenlySizedBatchesNotOneBigOneSmall() {
        // 190,000 chars at a 75,000 budget: floor(190000/75000) = 2, but
        // 190000/2 = 95,000 exceeds 75000*1.15 = 86,250, so it should step
        // up to 3 roughly-equal batches instead of 2 uneven ones.
        let chapters = (0..<19).map { index in
            (title: "Section \(index)", text: String(repeating: "x", count: 10_000))
        }

        let batches = SummarizerClient.buildBatches(chapters: chapters, documentType: .paper, budget: 75_000)

        XCTAssertEqual(batches.count, 3)
        // Every batch should be a contiguous run of the original indices.
        let flattened = batches.flatMap { $0 }
        XCTAssertEqual(flattened, Array(0..<19))
    }

    func testChapterAloneBiggerThanCapGetsItsOwnSoloBatch() {
        let chapters = [
            (title: "Normal", text: String(repeating: "a", count: 1000)),
            (title: "Huge Outlier", text: String(repeating: "b", count: 200_000)),
            (title: "Normal Again", text: String(repeating: "c", count: 1000)),
        ]

        let batches = SummarizerClient.buildBatches(chapters: chapters, documentType: .paper, budget: 75_000)

        XCTAssertTrue(batches.contains([1]), "the oversized chapter should get a dedicated solo batch")
    }

    func testEmptyChapterListReturnsNoBatches() {
        XCTAssertTrue(SummarizerClient.buildBatches(chapters: [], documentType: .paper, budget: 75_000).isEmpty)
    }
}

final class OversizedAIChapterTests: XCTestCase {
    func testOverlongAIChapterIsSplitIntoTitledParts() {
        let paragraph = String(repeating: "Satz mit Inhalt. ", count: 60) // ~1000 chars
        let long = Array(repeating: paragraph, count: 25).joined(separator: "\n\n") // ~25k
        let input = [
            SummarizerClient.AIChapterResult(title: "Kurz", sourceText: "s", summarizedText: "Kurzer Text."),
            SummarizerClient.AIChapterResult(title: "Lang", sourceText: "s", summarizedText: long),
        ]
        let result = SummarizerClient.splitOversizedChapters(input, maxCharacters: 12_000)
        XCTAssertEqual(result.first?.title, "Kurz")
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[1].title, "Lang (Teil 1/3)")
        XCTAssertTrue(result.dropFirst().allSatisfy { $0.summarizedText.count <= 12_000 })
        XCTAssertEqual(result.dropFirst().map(\.summarizedText).joined(separator: "\n\n"), long)
        XCTAssertEqual(SummarizerClient.splitOversizedChapters(input, maxCharacters: 0).count, 2)
    }
}
