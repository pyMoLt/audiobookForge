import XCTest
@testable import AudiobookForge

/// One-off sanity checks against real downloaded test documents (not
/// synthetic fixtures), to catch real-world extraction issues synthetic
/// tests can't reproduce — e.g. genuine two-column paper layouts, real
/// EPUB3 formatting quirks. Skips cleanly if the test files aren't present.
final class RealWorldSmokeTests: XCTestCase {
    private func printPostProcessed(_ label: String, chapters: [ExtractedChapter], settings: AppSettings = AppSettings()) -> [ExtractedChapter] {
        let processed = ChapterPostProcessor.mergeUndersizedChapters(
            settings.excludeBackMatterSections ? ChapterPostProcessor.filterBackMatter(chapters) : chapters,
            minimumCharacters: settings.minimumChapterCharacters
        )
        print("=== \(label): \(chapters.count) raw chapters -> \(processed.count) after post-processing ===")
        for chapter in processed {
            print("--- \(chapter.title) (\(chapter.text.count) chars) ---")
        }
        return processed
    }

    private func fixtureURL(_ filename: String) throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["AUDIOBOOKFORGE_SMOKE_FIXTURES_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set AUDIOBOOKFORGE_SMOKE_FIXTURES_DIR to run real-world smoke tests")
        }
        let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(filename)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "Smoke fixture not present: \(filename)")
        return url
    }

    func testExtractsAttentionPaperPDF() async throws {
        let url = try fixtureURL("Attention_Is_All_You_Need.pdf")

        let extractor = PDFExtractor()
        let document = try await extractor.extract(from: url)

        _ = printPostProcessed("Attention Is All You Need", chapters: document.chapters)

        XCTAssertFalse(document.chapters.isEmpty)
        let totalChars = document.chapters.reduce(0) { $0 + $1.text.count }
        XCTAssertGreaterThan(totalChars, 5000, "Expected substantial extracted text from a ~10 page paper")

        if let modelArch = document.chapters.first(where: { $0.title.contains("Model Architecture") }) {
            let outURL = URL(fileURLWithPath: "/tmp/model_architecture_chapter.txt")
            try? modelArch.text.write(to: outURL, atomically: true, encoding: .utf8)
        }
    }

    func testExtractsChristmasCarolEPUB() async throws {
        let url = try fixtureURL("A_Christmas_Carol.epub")

        let extractor = EPUBExtractor()
        let document = try await extractor.extract(from: url)

        _ = printPostProcessed("A Christmas Carol", chapters: document.chapters)

        XCTAssertFalse(document.chapters.isEmpty)
        XCTAssertTrue(document.suggestedTitle.localizedCaseInsensitiveContains("Christmas") || document.suggestedTitle.localizedCaseInsensitiveContains("Carol"))

        if let staveThree = document.chapters.first(where: { $0.title.contains("THREE") }) {
            try? staveThree.text.write(to: URL(fileURLWithPath: "/tmp/stave_three.txt"), atomically: true, encoding: .utf8)
        }
    }

    func testExtractsNestedTOCBookWithoutCollapsingChaptersIntoBooks() async throws {
        // Mill's "A System of Logic" — a single-file Gutenberg EPUB whose
        // nav.xhtml/toc.ncx nest real chapters inside each of the 6 "Books"
        // (Book I "Of Names and Propositions" containing many chapters,
        // etc.). A non-recursive TOC query only sees the 6 top-level Book
        // links, producing 6 (or here, ~8-10 after front/back matter)
        // "chapters" that are each an entire Book's worth of text.
        let url = try fixtureURL("pg27942-images-3.epub")

        let extractor = EPUBExtractor()
        let document = try await extractor.extract(from: url)

        let processed = printPostProcessed("A System of Logic", chapters: document.chapters)

        XCTAssertFalse(processed.isEmpty)
        XCTAssertGreaterThan(processed.count, 20, "the real nested TOC has ~93 entries — collapsing to top-level Books only would give ~10")

        // No single chapter should span an entire ~200-800k-character Book —
        // that was the direct symptom of the nesting bug. 150k is still well
        // above the longest genuine single chapter in this book (~115k, a
        // real, unusually long chapter with no further TOC subdivision
        // available) but far below what a whole collapsed Book looked like.
        let maxChapterLength = processed.map(\.text.count).max() ?? 0
        XCTAssertLessThan(maxChapterLength, 150_000, "a single chapter this large means nested TOC entries were dropped again")
    }

    func testExtractsUserProvidedPaperAndDumpsForManualLLMTesting() async throws {
        let url = try fixtureURL("1-s2.0-S0148296316302843-main-2.pdf")

        let extractor = PDFExtractor()
        let document = try await extractor.extract(from: url)

        _ = printPostProcessed("Social Media Marketing paper", chapters: document.chapters)

        XCTAssertFalse(document.chapters.isEmpty)

        let fullText = document.chapters.map(\.text).joined(separator: "\n\n")
        try? fullText.write(to: URL(fileURLWithPath: "/tmp/user_paper_full.txt"), atomically: true, encoding: .utf8)

        for (index, chapter) in document.chapters.enumerated() {
            let safeTitle = chapter.title.prefix(30).replacingOccurrences(of: "/", with: "-")
            try? chapter.text.write(to: URL(fileURLWithPath: "/tmp/user_paper_chapter_\(index)_\(safeTitle).txt"), atomically: true, encoding: .utf8)
        }
    }

    func testExtractsMDM2DatabasePaperWithNoOutlineNoOCR() async throws {
        let url = try fixtureURL("263453.pdf")

        let extractor = PDFExtractor()
        let document = try await extractor.extract(from: url)

        print("=== MDM2 database paper: usedOCR=\(document.usedOCR), \(document.chapters.count) RAW chapters (before merge) ===")
        for chapter in document.chapters {
            print("--- \"\(chapter.title)\" (\(chapter.text.count) chars) ---")
        }

        // "Introduction" (left column) must come before "Frequency of MDM2
        // Amplification" (right column, further down the page) — regression
        // guard for the two-column gutter-threshold bug where a narrower
        // real gutter fell back to whole-page top-to-bottom sorting and
        // interleaved the columns by height instead.
        let titles = document.chapters.map(\.title)
        let introIndex = titles.firstIndex { $0.localizedCaseInsensitiveContains("INTRODUCTION") }
        let frequencyIndex = titles.firstIndex { $0.localizedCaseInsensitiveContains("FREQUENCY OF MDM2") }
        if let introIndex, let frequencyIndex {
            XCTAssertLessThan(introIndex, frequencyIndex, "Introduction (left column) should be read before the right column's Frequency section")
        } else {
            XCTFail("Expected both 'Introduction' and 'Frequency of MDM2 Amplification' headings to be detected")
        }

        _ = printPostProcessed("MDM2 database paper", chapters: document.chapters)
    }

    func testVisionImagePassOnUserProvidedPaper() async throws {
        let url = try fixtureURL("1-s2.0-S0148296316302843-main-2.pdf")

        var settings = AppSettings()
        settings.describeImagesWithVisionModel = true
        settings.minimumImageDimensionForVisionPass = 180

        let extractor = PDFExtractor(settings: settings)
        let document = try await extractor.extract(from: url)

        let fullText = document.chapters.map(\.text).joined(separator: "\n\n")
        try? fullText.write(to: URL(fileURLWithPath: "/tmp/user_paper_with_images.txt"), atomically: true, encoding: .utf8)

        print("=== With vision pass: \(document.chapters.count) chapter(s), total \(fullText.count) chars ===")
        XCTAssertFalse(document.chapters.isEmpty)
    }
}
