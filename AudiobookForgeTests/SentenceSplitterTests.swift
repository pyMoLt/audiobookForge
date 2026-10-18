import XCTest
@testable import AudiobookForge

final class SentenceSplitterTests: XCTestCase {
    func testHardWrappedLinesDoNotFragmentASingleSentence() {
        // Real example: a Gutenberg-style hard-wrapped paragraph where the
        // source text embeds a literal newline mid-sentence. NLTokenizer
        // treats a bare "\n" as a forced sentence boundary on its own,
        // which used to split this one sentence into several TTS segments —
        // audible as a pause in the middle of the sentence.
        let text = """
        There is such a thing as robbing a story of its reality by trying
        to make it too true, and The Black Arrow is so inartistic as
        not to contain a single anachronism to boast of, while the transformation
        of Dr. Jekyll reads dangerously like an experiment out of the Lancet.
        """

        let sentences = SentenceSplitter.split(text)

        XCTAssertEqual(sentences.count, 1)
        XCTAssertFalse(sentences[0].contains("\n"))
        XCTAssertTrue(sentences[0].hasPrefix("There is such a thing"))
        XCTAssertTrue(sentences[0].hasSuffix("out of the Lancet."))
    }

    func testMultipleRealSentencesAcrossHardWrappedLinesAreStillSeparated() {
        let text = "This is the first sentence,\nwrapped across two lines. This is a second,\nseparate sentence."

        let sentences = SentenceSplitter.split(text)

        XCTAssertEqual(sentences, [
            "This is the first sentence, wrapped across two lines.",
            "This is a second, separate sentence.",
        ])
    }

    func testCollapsesMultipleConsecutiveNewlinesToo() {
        let text = "First sentence.\n\n\nSecond sentence."
        XCTAssertEqual(SentenceSplitter.split(text), ["First sentence.", "Second sentence."])
    }

    func testEmptyAndWhitespaceOnlyInputYieldsNoSentences() {
        XCTAssertTrue(SentenceSplitter.split("").isEmpty)
        XCTAssertTrue(SentenceSplitter.split("   \n\n  ").isEmpty)
    }

    /// One TTS segment per sentence means a false break after an
    /// abbreviation would be spoken as its own sentence.
    func testAbbreviationsInitialsAndOrdinalDatesDoNotEndSentences() {
        XCTAssertEqual(
            SentenceSplitter.split("Am 3. Oktober 2026 las Dr. Martina Schulz vor. Rund 250 Gäste hörten zu."),
            ["Am 3. Oktober 2026 las Dr. Martina Schulz vor.", "Rund 250 Gäste hörten zu."]
        )
        XCTAssertEqual(
            SentenceSplitter.split("Mr. Smith met Dr. Jones. They talked."),
            ["Mr. Smith met Dr. Jones.", "They talked."]
        )
        XCTAssertEqual(
            SentenceSplitter.split("Prof. Dr. Meier u. a. widersprachen. Siehe S. 14 für Details."),
            ["Prof. Dr. Meier u. a. widersprachen.", "Siehe S. 14 für Details."]
        )
        XCTAssertEqual(
            SentenceSplitter.split("Das Buch schrieb J. R. R. Tolkien. Es ist lang."),
            ["Das Buch schrieb J. R. R. Tolkien.", "Es ist lang."]
        )
    }

    func testRealSentenceEndingInANumberStillSplits() {
        XCTAssertEqual(
            SentenceSplitter.split("Die Antwort lautet 42. Danach war Ruhe."),
            ["Die Antwort lautet 42.", "Danach war Ruhe."]
        )
    }
}
