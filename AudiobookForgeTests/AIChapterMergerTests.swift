import XCTest
@testable import AudiobookForge

/// Plan 7.2 — merging of AI chapters below `minAIChapterCharacters`.
final class AIChapterMergerTests: XCTestCase {
    private func chapter(title: String, group: String?, text: String) -> SummarizerClient.AIChapterResult {
        SummarizerClient.AIChapterResult(title: title, groupTitle: group, sourceText: "Quelle: \(title)", summarizedText: text)
    }

    /// The plan's worked example: lengths [300, 4000, 500, 700, 2500] with
    /// parents [A, A, B, B, B], minimum 1200.
    func testPlanDistribution() {
        let chapters = [
            chapter(title: "A1", group: "A", text: String(repeating: "a", count: 300)),
            chapter(title: "A2", group: "A", text: String(repeating: "b", count: 4000)),
            chapter(title: "B1", group: "B", text: String(repeating: "c", count: 500)),
            chapter(title: "B2", group: "B", text: String(repeating: "d", count: 700)),
            chapter(title: "B3", group: "B", text: String(repeating: "e", count: 2500)),
        ]
        let merged = AIChapterMerger.merge(chapters, minCharacters: 1200)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].title, "A1", "Kleines Kapitel verschmilzt mit dem Folgekapitel, Titel des ersten")
        XCTAssertEqual(merged[0].summarizedText.count, 300 + 2 + 4000)
        XCTAssertEqual(merged[1].title, "B1")
        XCTAssertEqual(merged[1].summarizedText.count, 500 + 2 + 700, "500+700 = 1202 übersteigt die Grenze")
        XCTAssertEqual(merged[2].title, "B3")
        XCTAssertEqual(merged[2].summarizedText.count, 2500)
    }

    /// Last mini chapter of a parent group is appended to the previous one.
    func testLastMiniChapterOfGroupAppendsToPrevious() {
        let chapters = [
            chapter(title: "G1", group: "G", text: String(repeating: "x", count: 3000)),
            chapter(title: "G2", group: "G", text: String(repeating: "y", count: 400)),
        ]
        let merged = AIChapterMerger.merge(chapters, minCharacters: 1200)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].title, "G1", "Der vorherige Titel bleibt")
        XCTAssertTrue(merged[0].summarizedText.hasSuffix(String(repeating: "y", count: 400)))
    }

    /// Never merges across parent groups: a small chapter whose neighbors
    /// belong to another parent stays on its own.
    func testNeverMergesAcrossParents() {
        let chapters = [
            chapter(title: "A", group: "A", text: String(repeating: "a", count: 3000)),
            chapter(title: "B", group: "B", text: String(repeating: "b", count: 200)),
            chapter(title: "C", group: "C", text: String(repeating: "c", count: 3000)),
        ]
        let merged = AIChapterMerger.merge(chapters, minCharacters: 1200)
        XCTAssertEqual(merged.map(\.title), ["A", "B", "C"])
    }

    /// Parts without a parent (non-book documents) merge with the previous.
    func testPartsWithoutGroupMergeWithPrevious() {
        let chapters = [
            chapter(title: "T1", group: nil, text: String(repeating: "a", count: 5000)),
            chapter(title: "T2", group: nil, text: String(repeating: "b", count: 300)),
            chapter(title: "T3", group: nil, text: String(repeating: "c", count: 4000)),
        ]
        let merged = AIChapterMerger.merge(chapters, minCharacters: 1200)
        XCTAssertEqual(merged.map(\.title), ["T1", "T3"])
        XCTAssertEqual(merged[0].summarizedText.count, 5000 + 2 + 300)
    }

    /// No character is ever lost: the components of every merged text,
    /// flattened, are exactly the original texts in order.
    func testNoCharacterLoss() {
        let chapters = [
            chapter(title: "A1", group: "A", text: "Erster Teil."),
            chapter(title: "A2", group: "A", text: "Zweiter Teil."),
            chapter(title: "A3", group: "A", text: "Dritter."),
            chapter(title: "B1", group: "B", text: String(repeating: "b", count: 2000)),
            chapter(title: "B2", group: "B", text: "Winzig."),
        ]
        let merged = AIChapterMerger.merge(chapters, minCharacters: 1200)
        let flattened = merged.flatMap { $0.summarizedText.components(separatedBy: "\n\n") }
        XCTAssertEqual(flattened, chapters.map(\.summarizedText))
    }

    /// Merging joins with a blank line — no synthesized heading.
    func testMergeInsertsBlankLineNotHeading() {
        let chapters = [
            chapter(title: "A1", group: "A", text: "Satz eins."),
            chapter(title: "A2", group: "A", text: "Satz zwei."),
        ]
        let merged = AIChapterMerger.merge(chapters, minCharacters: 1200)
        XCTAssertEqual(merged[0].summarizedText, "Satz eins.\n\nSatz zwei.")
        XCTAssertFalse(merged[0].summarizedText.contains("##"))
    }

    func testOffWhenMinIsZero() {
        let chapters = [
            chapter(title: "A1", group: "A", text: "Kurz."),
            chapter(title: "A2", group: "A", text: "Kurz."),
        ]
        XCTAssertEqual(AIChapterMerger.merge(chapters, minCharacters: 0).count, 2)
    }

    func testSingleChapterStays() {
        let chapters = [chapter(title: "A1", group: "A", text: "Kurz.")]
        XCTAssertEqual(AIChapterMerger.merge(chapters, minCharacters: 1200).count, 1)
    }

    /// The real-book distribution from plan section 1: 54 of 696 chapters
    /// below 800 characters — after merging with the plan's default (1200),
    /// nothing is left below the limit except single-chapter parents.
    func testRealDistributionLeavesNoMicroChapters() {
        var chapters: [SummarizerClient.AIChapterResult] = []
        for group in 0..<696 {
            let parent = "Kapitel \(group / 3)"
            let text = (group % 13 == 0 && group % 3 != 2)
                ? String(repeating: "x", count: 400)   // ~54 mini chapters
                : String(repeating: "x", count: 2000)
            chapters.append(chapter(title: "Abschnitt \(group)", group: parent, text: text))
        }
        let merged = AIChapterMerger.merge(chapters, minCharacters: 1200)
        XCTAssertLessThan(merged.count, chapters.count, "Mini-Kapitel sind aufgegangen")
        let singles = merged.filter { $0.summarizedText.count < 1200 }
        // Remaining small chapters must be single-chapter parents (nothing
        // to merge with), never squeezed between siblings.
        for single in singles {
            let siblings = merged.filter { $0.groupTitle == single.groupTitle }
            XCTAssertEqual(siblings.count, 1, "Kapitel unter dem Limit mit Geschwistern: \(single.title)")
        }
    }
}

/// Plan 7.3 — groupTitle/title separation and packaged chapter-mark names.
final class ChapterNamingTests: XCTestCase {
    private func chapter(title: String, group: String? = nil) -> Chapter {
        Chapter(title: title, groupTitle: group, rawText: "", cleanedText: "", order: 0)
    }

    func testDisplayTitleComposesGroupAndTitle() {
        XCTAssertEqual(chapter(title: "Schulterdystokie", group: "Kapitel 12").displayTitle, "Kapitel 12 — Schulterdystokie")
        XCTAssertEqual(chapter(title: "Einzeltitel", group: "Einzeltitel").displayTitle, "Einzeltitel")
        XCTAssertEqual(chapter(title: "Ohne Gruppe").displayTitle, "Ohne Gruppe")
    }

    func testLongNamesShortenToGroupNumber() {
        let longTitle = String(repeating: "T", count: 80)
        let chapters = [
            chapter(title: longTitle, group: "Erste Gruppe"),
            chapter(title: longTitle + "x", group: "Zweite Gruppe"), // distinct titles: no (2)
        ]
        let names = ChapterNaming.markTitles(for: chapters)
        XCTAssertEqual(names[0], "1 · " + longTitle)
        XCTAssertEqual(names[1], "2 · " + longTitle + "x")
    }

    func testLongNameWithoutGroupUsesPosition() {
        let longTitle = String(repeating: "T", count: 80)
        let chapters = [chapter(title: longTitle), chapter(title: longTitle + "x")]
        let names = ChapterNaming.markTitles(for: chapters)
        XCTAssertEqual(names[0], "1 · " + longTitle)
        XCTAssertEqual(names[1], "2 · " + longTitle + "x")
    }

    func testDuplicateTitlesGetCounter() {
        let chapters = [
            chapter(title: "Schulterdystokie", group: "Kapitel 1"),
            chapter(title: "Schulterdystokie", group: "Kapitel 9"),
            chapter(title: "Schulterdystokie", group: "Kapitel 20"),
        ]
        let names = ChapterNaming.markTitles(for: chapters)
        XCTAssertEqual(names[0], "Kapitel 1 — Schulterdystokie")
        XCTAssertEqual(names[1], "Kapitel 9 — Schulterdystokie (2)")
        XCTAssertEqual(names[2], "Kapitel 20 — Schulterdystokie (3)")
        XCTAssertEqual(Set(names).count, 3, "Namen sind eindeutig")
    }

    func testShortChapterTitlesPassThrough() {
        let chapters = [chapter(title: "Einleitung", group: "Kapitel 1")]
        XCTAssertEqual(ChapterNaming.markTitles(for: chapters), ["Kapitel 1 — Einleitung"])
    }

    func testChapterCodableRoundTripKeepsGroupTitle() throws {
        let original = chapter(title: "Heading", group: "Parent")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Chapter.self, from: data)
        XCTAssertEqual(decoded.title, "Heading")
        XCTAssertEqual(decoded.groupTitle, "Parent")

        // Old payload without the key decodes with nil.
        let legacyJSON = """
        {"id": "\(UUID().uuidString)", "title": "Alt", "rawText": "", "cleanedText": "", "order": 0, "audioStatus": "pending"}
        """
        let legacy = try JSONDecoder().decode(Chapter.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.groupTitle)
    }

    func testChapterMetadataRoundTripKeepsGroupTitle() throws {
        var source = Chapter(title: "Heading", groupTitle: "Parent", rawText: "R", cleanedText: "C", order: 2)
        source.id = UUID()
        let metadata = LibraryLayout.ChapterMetadata(chapter: source)
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(LibraryLayout.ChapterMetadata.self, from: data)
        XCTAssertEqual(decoded.chapter.groupTitle, "Parent")
        XCTAssertEqual(decoded.title, "Heading")

        // v3 book.json written before Phase 4 has no groupTitle key.
        let legacyJSON = """
        {"id": "\(UUID().uuidString)", "title": "Alt", "order": 0, "audioStatus": "pending"}
        """
        let legacy = try JSONDecoder().decode(LibraryLayout.ChapterMetadata.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.groupTitle)
    }
}
