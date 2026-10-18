import Foundation
import XCTest
@testable import AudiobookForge

final class ChapterRebundlerTests: XCTestCase {

    func testRebundleEmptyAndSingle() {
        XCTAssertTrue(ChapterRebundler.rebundle(chapters: [], targetCharacters: 10_000).isEmpty)

        let single = Chapter(title: "Einleitung", rawText: "Hallo", cleanedText: "Hallo", order: 0)
        let result = ChapterRebundler.rebundle(chapters: [single], targetCharacters: 10_000)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].title, "Einleitung")

        // Non-positive target returns chapters unchanged
        let multiple = [
            Chapter(title: "1.1 A", rawText: "A", cleanedText: "A", order: 0),
            Chapter(title: "1.2 B", rawText: "B", cleanedText: "B", order: 1)
        ]
        let unchanged = ChapterRebundler.rebundle(chapters: multiple, targetCharacters: 0)
        XCTAssertEqual(unchanged.count, 2)
    }

    func testRebundleRespectsMajorChapterBoundaries() {
        let chapters = [
            Chapter(title: "1.1 Wegweiser", rawText: "Text 1", cleanedText: String(repeating: "x", count: 2000), order: 0),
            Chapter(title: "1.2 Pharmakokinetik", rawText: "Text 2", cleanedText: String(repeating: "x", count: 2000), order: 1),
            Chapter(title: "2.1 Herzkreislauf", rawText: "Text 3", cleanedText: String(repeating: "x", count: 2000), order: 2),
            Chapter(title: "2.2 Blutdruck", rawText: "Text 4", cleanedText: String(repeating: "x", count: 2000), order: 3)
        ]

        // Even with a huge target (50,000 chars), Chapter 1 and Chapter 2 should never merge!
        let rebundled = ChapterRebundler.rebundle(chapters: chapters, targetCharacters: 50_000)
        XCTAssertEqual(rebundled.count, 2)

        XCTAssertTrue(rebundled[0].title.contains("1.1–1.2"))
        XCTAssertTrue(rebundled[1].title.contains("2.1–2.2"))
    }

    func testRebundleCombinesWithinTargetAndGeneratesCleanTitles() {
        let chapters = [
            Chapter(title: "1.1 Wegweiser", rawText: "T1", cleanedText: String(repeating: "a", count: 3000), order: 0),
            Chapter(title: "1.2 Resorption", rawText: "T2", cleanedText: String(repeating: "b", count: 4000), order: 1),
            Chapter(title: "1.3 Verteilung", rawText: "T3", cleanedText: String(repeating: "c", count: 3500), order: 2),
            Chapter(title: "1.4 Elimination", rawText: "T4", cleanedText: String(repeating: "d", count: 9000), order: 3)
        ]

        // Target: 10,000 characters
        // 1.1 + 1.2 + 1.3 = 10,500 chars (within 135% tolerance) -> Group 1
        // 1.4 = 9,000 chars -> Group 2
        let rebundled = ChapterRebundler.rebundle(chapters: chapters, targetCharacters: 10_000)
        XCTAssertEqual(rebundled.count, 2)

        XCTAssertEqual(rebundled[0].title, "1.1–1.3 Wegweiser … Verteilung")
        XCTAssertEqual(rebundled[1].title, "1.4 Elimination")

        // Subheadings must be included in the merged text for narration
        XCTAssertTrue(rebundled[0].cleanedText.contains("1.2 Resorption"))
        XCTAssertTrue(rebundled[0].cleanedText.contains("1.3 Verteilung"))
    }

    func testTitleSynthesisVariations() {
        let ch1 = Chapter(title: "1 Grundlagen der Pharmakologie", rawText: "", cleanedText: "", order: 0)
        let ch2 = Chapter(title: "1.1 Wegweiser", rawText: "", cleanedText: "", order: 1)
        let ch3 = Chapter(title: "1.3 Pharmakodynamik", rawText: "", cleanedText: "", order: 2)

        let topAndSub = ChapterRebundler.synthesizeTitle(from: [ch1, ch2, ch3])
        XCTAssertEqual(topAndSub, "1 Grundlagen der Pharmakologie (bis 1.3 Pharmakodynamik)")

        let twoSubs = ChapterRebundler.synthesizeTitle(from: [ch2, ch3])
        XCTAssertEqual(twoSubs, "1.1–1.3 Wegweiser & Pharmakodynamik")

        let ch4 = Chapter(title: "1.2 Resorption", rawText: "", cleanedText: "", order: 1)
        let threeSubs = ChapterRebundler.synthesizeTitle(from: [ch2, ch4, ch3])
        XCTAssertEqual(threeSubs, "1.1–1.3 Wegweiser … Pharmakodynamik")

        let unnumberedA = Chapter(title: "Vorwort", rawText: "", cleanedText: "", order: 0)
        let unnumberedB = Chapter(title: "Einleitung", rawText: "", cleanedText: "", order: 1)
        let unnumbered = ChapterRebundler.synthesizeTitle(from: [unnumberedA, unnumberedB])
        XCTAssertEqual(unnumbered, "Vorwort – Einleitung")
    }

    func testStripLeadingNumber() {
        XCTAssertEqual(ChapterRebundler.stripLeadingNumber(from: "1.2 Pharmakokinetik"), "Pharmakokinetik")
        XCTAssertEqual(ChapterRebundler.stripLeadingNumber(from: "Kapitel 3: Physiologie"), "Physiologie")
        XCTAssertEqual(ChapterRebundler.stripLeadingNumber(from: "10.4.1 Resorption"), "Resorption")
        XCTAssertEqual(ChapterRebundler.stripLeadingNumber(from: "Ohne Nummer"), "Ohne Nummer")
    }
}
