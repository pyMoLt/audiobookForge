import XCTest
@testable import AudiobookForge

/// Phase 3 (plan 6.2): front/back-matter + TOC classification — a
/// suggestion that preselects "nicht vorlesen", never a silent drop.
@MainActor
final class TocClassifierTests: XCTestCase {

    // MARK: - Classifier

    func testTocTitleClassifiesAsToc() {
        XCTAssertEqual(FrontBackMatterClassifier.classify(title: "Inhaltsverzeichnis", text: "Egal"), .toc)
        XCTAssertEqual(FrontBackMatterClassifier.classify(title: "Contents", text: "Egal"), .toc)
    }

    func testPageNumberLineShareClassifiesAsToc() {
        let lines = (1...10).map { "Kapitel \($0) \($0 * 13)" }.joined(separator: "\n")
        XCTAssertEqual(FrontBackMatterClassifier.classify(title: "Übersicht der Kapitel", text: lines), .toc)
    }

    func testBodyChapterWithOccasionalPageNumbersStaysBody() {
        // Fließtext mit einzelnen Seitenverweisen: darf NICHT als
        // Inhaltsverzeichnis gelten.
        let prose = """
        Die Therapie richtet sich nach dem Stadium (siehe S. 112). Bei fortgeschrittener Erkrankung kommt eine Kombination aus Chirurgie und Bestrahlung infrage, wie in mehreren Studien gezeigt wurde.
        Die Prognose ist abhängig vom Lymphknotenstatus; siehe auch die Übersicht auf Seite 34 im Anhang.
        """
        XCTAssertEqual(FrontBackMatterClassifier.classify(title: "Therapie der Erkrankung", text: prose), .body)
    }

    func testDotFillersClassifyAsToc() {
        let toc = ["Einleitung ……… 12", "Anamnese ……… 24", "Diagnostik ……… 57"].joined(separator: "\n")
        XCTAssertEqual(FrontBackMatterClassifier.classify(title: "Gliederung", text: toc), .toc)
    }

    func testFrontAndBackMatterTitles() {
        XCTAssertEqual(FrontBackMatterClassifier.classify(title: "Vorwort", text: "Liebe Leserin."), .frontMatter)
        XCTAssertEqual(FrontBackMatterClassifier.classify(title: "Impressum", text: "Verlag, 2026."), .frontMatter)
        XCTAssertEqual(FrontBackMatterClassifier.classify(title: "Literatur", text: "Mustermann 2020, S. 12."), .backMatter)
        XCTAssertEqual(FrontBackMatterClassifier.classify(title: "Sachverzeichnis", text: "A – Z"), .backMatter)
        XCTAssertEqual(FrontBackMatterClassifier.classify(title: "Diagnostik", text: "Der Weg zur Diagnose beginnt."), .body)
    }

    func testSuggestions() {
        XCTAssertTrue(FrontBackMatterClassifier.suggestsSkipping(.toc))
        XCTAssertTrue(FrontBackMatterClassifier.suggestsSkipping(.frontMatter))
        XCTAssertFalse(FrontBackMatterClassifier.suggestsSkipping(.backMatter))
        XCTAssertFalse(FrontBackMatterClassifier.suggestsSkipping(.body))
    }

    // MARK: - Persistence round-trip (v3 store)

    func testMatterKindAndInclusionRoundTripThroughBookMetadata() throws {
        var chapter = Chapter(title: "Inhaltsverzeichnis", rawText: "Kapitel 1 … 12", cleanedText: "Kapitel 1 … 12", order: 0)
        chapter.matterKind = .toc
        chapter.includeInNarration = false
        var book = BookProject(
            title: "RT", author: "T", sourceType: .pdf,
            sourceURL: URL(fileURLWithPath: "/dev/null"),
            chapters: [chapter],
            outputFormat: .m4b, voice: "af_heart", speechSpeed: 1.0
        )
        book.mode = .transcription

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ABF-matterkind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        try LibraryLayout.writeBook(book, root: work)
        let reloaded = try XCTUnwrap(LibraryLayout.readBook(bookID: book.id, root: work))
        XCTAssertEqual(reloaded.chapters.first?.matterKind, .toc)
        XCTAssertEqual(reloaded.chapters.first?.includeInNarration, false)
    }

    // MARK: - Pipeline honors the exclusion

    func testExcludedChapterIsNotSynthesized() async throws {
        guard FFmpegLocator.resolve(settings: AppSettings()) != nil else { throw XCTSkip("ffmpeg fehlt") }
        let engine = FakeTTSEngine(proceedAllowance: 5)
        TTSEngineFactory.engineOverride = { _ in engine }
        defer { TTSEngineFactory.engineOverride = nil }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ABF-exclusion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let store = LibraryStore(fileURL: work.appendingPathComponent("library.json"))
        let settingsStore = SettingsStore(fileURL: work.appendingPathComponent("settings.json"))
        var settings = settingsStore.settings
        settings.describeImagesWithVisionModel = false
        settings.ttsParallelWorkers = 1
        settings.autoStartOMLX = false
        settings.autoUnloadOMLXAfterPass = false
        settings.outputBaseFolderPath = work.appendingPathComponent("out").path
        settingsStore.settings = settings

        let pipeline = PipelineController(
            libraryStore: store,
            settingsStore: settingsStore,
            chapterAudioRoot: work.appendingPathComponent("chapter_audio"),
            logsDirectory: work.appendingPathComponent("logs")
        )

        var book = BookProject(
            title: "Ausschluss", author: "T", sourceType: .pdf,
            sourceURL: URL(fileURLWithPath: "/dev/null"),
            chapters: [
                Chapter(title: "Inhaltsverzeichnis", rawText: "Kapitel 1 … 12", cleanedText: "Kapitel 1 … 12", order: 0),
                Chapter(title: "Einleitung", rawText: "Wichtiger Inhalt.", cleanedText: "Wichtiger Inhalt.", order: 1)
            ],
            outputFormat: .m4b, voice: "fake", speechSpeed: 1.0
        )
        book.mode = .transcription
        book.engineID = .kokoro
        book.chapters[0].matterKind = .toc
        book.chapters[0].includeInNarration = false
        store.upsert(book)
        pipeline.enqueue(bookID: book.id)

        let completed = await { () -> Bool in
            let started = Date()
            while Date().timeIntervalSince(started) < 20 {
                if store.book(id: book.id)?.status == .completed { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }()
        XCTAssertTrue(completed, "Pipeline sollte durchlaufen")

        let calls = engine.synthesizeCalls.withLock { $0 }
        XCTAssertEqual(calls, ["Wichtiger Inhalt."], "ausgeschlossenes Kapitel darf nicht synthetisiert werden")
        XCTAssertEqual(store.book(id: book.id)?.chapters[0].audioStatus, ChapterAudioStatus.pending,
                       "ausgeschlossenes Kapitel bleibt pending")
    }
}
