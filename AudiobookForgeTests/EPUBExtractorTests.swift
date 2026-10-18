import XCTest
@testable import AudiobookForge

final class EPUBExtractorTests: XCTestCase {
    func testExtractsChaptersFromNav() async throws {
        let url = try TestEPUBBuilder.makeBook(
            title: "A Native Test Book",
            author: "Grace Hopper",
            chapters: [
                (title: "The Beginning", body: "It all started on a quiet afternoon in the lab, or so the story goes."),
                (title: "The Middle", body: "Things got complicated, as they always do somewhere in the middle of a good story."),
                (title: "The End", body: "Eventually, everything resolved itself in a satisfying way."),
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let extractor = EPUBExtractor()
        let document = try await extractor.extract(from: url)

        XCTAssertEqual(document.suggestedTitle, "A Native Test Book")
        XCTAssertEqual(document.suggestedAuthor, "Grace Hopper")
        XCTAssertEqual(document.chapters.count, 3)
        XCTAssertEqual(document.chapters[0].title, "The Beginning")
        XCTAssertTrue(document.chapters[1].text.contains("complicated"))
        XCTAssertEqual(document.chapters[2].title, "The End")
    }

    func testHardWrappedSourceLinesAreJoinedNotKeptAsEmbeddedNewlines() async throws {
        // Gutenberg-style HTML keeps the plain-text edition's hard line
        // wraps (~70 chars) as literal newlines inside a single <p>. Left
        // in place, a downstream sentence tokenizer treats every such
        // newline as a forced sentence boundary — audible as a pause in the
        // middle of a sentence during narration (see SentenceSplitterTests).
        let hardWrappedBody = "This sentence is deliberately\nhard-wrapped across three\nseparate source lines."
        let url = try TestEPUBBuilder.makeBook(
            title: "Hard Wrap Test",
            author: "Test Author",
            chapters: [(title: "Only Chapter", body: hardWrappedBody)]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let extractor = EPUBExtractor()
        let document = try await extractor.extract(from: url)

        XCTAssertEqual(document.chapters.count, 1)
        // The heading block and body paragraph block are legitimately
        // joined with a real "\n\n" — only the body paragraph itself (a
        // single <p>) should never contain a bare, un-doubled newline.
        let bodyParagraph = document.chapters[0].text.components(separatedBy: "\n\n").last ?? ""
        XCTAssertFalse(bodyParagraph.contains("\n"), "embedded hard-wrap newlines within one paragraph should be collapsed to spaces")
        XCTAssertEqual(bodyParagraph, "This sentence is deliberately hard-wrapped across three separate source lines.")
    }
}
