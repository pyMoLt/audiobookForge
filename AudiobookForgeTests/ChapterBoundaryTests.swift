import XCTest
@testable import AudiobookForge

/// Phase 3 (plan 6.5, rule 3): sentence-boundary repair across chapter
/// splits — a chapter that begins mid-sentence gets its leading
/// fragment moved back to the predecessor.
final class ChapterBoundaryTests: XCTestCase {

    private func chapter(_ title: String, _ text: String, order: Int) -> Chapter {
        Chapter(title: title, rawText: text, cleanedText: text, order: order)
    }

    func testFragmentMovesToPredecessor() {
        let chapters = [
            chapter("Mamma", "Verbindungen bestehen auch zu kontralateralen Lymphabflusswegen", order: 0),
            chapter("Genitalfehlbildungen", "und drainieren das parenchymale Gewebe. Danach folgt normaler Text des neuen Kapitels.", order: 1),
        ]
        let repaired = ChapterBoundaryRepair.repairBoundaries(chapters: chapters)
        XCTAssertTrue(repaired[0].cleanedText.hasSuffix("und drainieren das parenchymale Gewebe."),
                      "Satzrest muss beim Vorgänger landen: \(repaired[0].cleanedText)")
        XCTAssertTrue(repaired[1].cleanedText.hasPrefix("Danach folgt normaler Text"),
                      "Kapitel muss am Satzanfang beginnen: \(repaired[1].cleanedText)")
    }

    func testCleanBoundariesAreUntouched() {
        let chapters = [
            chapter("Erstes", "Ein vollständiger Satz endet hier.", order: 0),
            chapter("Zweites", "Auch dieses Kapitel beginnt sauber.", order: 1),
        ]
        let repaired = ChapterBoundaryRepair.repairBoundaries(chapters: chapters)
        XCTAssertEqual(repaired.map(\.cleanedText), chapters.map(\.cleanedText))
    }

    func testLowercaseStartAfterSentenceEndStays() {
        // Vorgänger endet mit Doppelpunkt — absichtliche Fortsetzung
        // bleibt, wo sie ist (kein Flickwerk).
        let chapters = [
            chapter("A", "Die Diagnose lautet:", order: 0),
            chapter("B", "verdächtige Läsion im Sinne einer", order: 1),
        ]
        let repaired = ChapterBoundaryRepair.repairBoundaries(chapters: chapters)
        XCTAssertTrue(repaired[1].cleanedText.hasPrefix("verdächtige"))
    }

    func testMultipleChaptersRepairInOnePass() {
        let chapters = [
            chapter("A", "Der M. levator ani wird", order: 0),
            chapter("B", "durch den Plexus sacralis innerviert. Weitere Sätze bleiben hier.", order: 1),
            chapter("C", "Ein sauberes Kapitel beginnt.", order: 2),
        ]
        let repaired = ChapterBoundaryRepair.repairBoundaries(chapters: chapters)
        XCTAssertEqual(repaired[0].cleanedText, "Der M. levator ani wird durch den Plexus sacralis innerviert.")
        XCTAssertEqual(repaired[1].cleanedText, "Weitere Sätze bleiben hier.")
        XCTAssertEqual(repaired[2].cleanedText, "Ein sauberes Kapitel beginnt.")
    }

    func testChapterWithoutSentenceEndStaysInPlace() {
        // Ein Kapitel ohne jedes Satzende: der ganze Text wäre der
        // "Satzrest" — Verschieben wäre zu riskikal, also bleibt alles.
        let chapters = [
            chapter("A", "Der M. levator ani wird", order: 0),
            chapter("B", "durch den Plexus sacralis innerviert", order: 1),
        ]
        let repaired = ChapterBoundaryRepair.repairBoundaries(chapters: chapters)
        XCTAssertEqual(repaired.map(\.cleanedText), chapters.map(\.cleanedText))
    }

    func testRawTextMirrorsCleanedTextWhenIdentical() {
        let chapters = [
            chapter("A", "Text ohne Ende", order: 0),
            chapter("B", "des Satzes. Neuer Anfang.", order: 1),
        ]
        let repaired = ChapterBoundaryRepair.repairBoundaries(chapters: chapters)
        XCTAssertEqual(repaired[0].rawText, repaired[0].cleanedText)
        XCTAssertEqual(repaired[1].rawText, repaired[1].cleanedText)
    }
}
