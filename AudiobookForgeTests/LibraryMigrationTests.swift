import XCTest
import AppKit
@testable import AudiobookForge

/// Phase 2 (plan 5.1): v2 → v3 library migration — round-trip of every
/// field, text dedupe, permanent backup, mid-migration abort leaves the
/// v2 data untouched, idempotence on the second start, and resilience
/// against unknown JSON fields. Everything runs against temp directories.
final class LibraryMigrationTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ABF-library-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    // MARK: - Fixtures

    private func makeChapter(title: String, order: Int, raw: String, cleaned: String, summarized: String? = nil, ready: Bool = true) -> Chapter {
        var chapter = Chapter(title: title, rawText: raw, cleanedText: cleaned, order: order)
        chapter.summarizedText = summarized
        if ready {
            chapter.audioStatus = .ready
            chapter.audioDurationSeconds = Double(order + 1) * 12.5
            chapter.audioSegments = [TTSSegment(index: 0, startSeconds: 0, durationSeconds: 1.5, text: "Satz.")]
        }
        return chapter
    }

    private func makeCoverData(pixelSize: Int = 16) -> Data {
        let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill()
        image.unlockFocus()
        return image.tiffRepresentation ?? Data()
    }

    /// Three books covering the interesting cases: transcription mode,
    /// summary mode with sourceChapters == rawImportedChapters (dedupe),
    /// and summary mode with differing raw/cleaned texts + chapters where
    /// rawText == cleanedText (dedupe).
    private func makeFixtureBooks() -> [BookProject] {
        var plain = BookProject(
            title: "Kochbuch", author: "Ada Beispiel", sourceType: .pdf,
            sourceURL: URL(fileURLWithPath: "/tmp/kochbuch.pdf"),
            chapters: [
                makeChapter(title: "Suppen", order: 0, raw: "Gemüsebrühe kochen.", cleaned: "Gemüsebrühe kochen."),
                makeChapter(title: "Desserts", order: 1, raw: "Rohfassung mit Fußnote 12", cleaned: "Rohfassung mit Fußnote"),
            ],
            outputFormat: .m4b, voice: "af_heart", speechSpeed: 1.0
        )
        plain.engineID = .kokoro
        plain.detectedLanguageCode = "de"
        plain.narratorLabel = "AF"
        plain.sourceNote = "Testquelle"
        plain.coverImageData = makeCoverData()

        var summarySameRaw = BookProject(
            title: "Paper", author: "R. Esearcher", sourceType: .epub,
            sourceURL: URL(fileURLWithPath: "/tmp/paper.epub"),
            chapters: [
                makeChapter(title: "Intro", order: 0, raw: "Einführung lang.", cleaned: "Einführung lang.", summarized: "Kurze Einführung."),
                makeChapter(title: "Method", order: 1, raw: "Methodik lang.", cleaned: "Methodik lang.", summarized: "Kurze Methodik."),
            ],
            outputFormat: .m4a, voice: "thorsten", speechSpeed: 1.15
        )
        summarySameRaw.mode = .summary
        summarySameRaw.documentType = .paper
        summarySameRaw.summarizationBudget = 50_000
        let sourceChapters = [
            makeChapter(title: "Intro", order: 0, raw: "Einführung lang.", cleaned: "Einführung lang."),
            makeChapter(title: "Method", order: 1, raw: "Methodik lang.", cleaned: "Methodik lang."),
        ]
        // Identical arrays → must be stored once (sameAsRaw).
        summarySameRaw.sourceChapters = sourceChapters
        summarySameRaw.rawImportedChapters = sourceChapters

        var summaryDistinct = BookProject(
            title: "Roman", author: "N. Erzähler", sourceType: .pdf,
            sourceURL: URL(fileURLWithPath: "/tmp/roman.pdf"),
            chapters: [
                makeChapter(title: "Kapitel 1", order: 0, raw: "Erster Satz.", cleaned: "Erster bereinigter Satz.", summarized: "Zusammenfassung eins."),
            ],
            outputFormat: .mp3Chapters, voice: "eva_k", speechSpeed: 0.95
        )
        summaryDistinct.mode = .summary
        let sourceOnly = [makeChapter(title: "Kapitel 1", order: 0, raw: "Erster Satz.", cleaned: "Erster Satz.")]
        summaryDistinct.sourceChapters = sourceOnly
        summaryDistinct.rawImportedChapters = [makeChapter(title: "Kapitel 1", order: 0, raw: "Erster Rohsatz.", cleaned: "Erster Rohsatz.")]
        summaryDistinct.status = .completed
        summaryDistinct.topic = "Literatur & Belletristik"
        summaryDistinct.folderID = UUID()

        return [plain, summarySameRaw, summaryDistinct]
    }

    /// Writes a v2 `library.json`. `injectUnknownField` adds an extra key
    /// to the first book's JSON — migration must survive it (unknown keys
    /// neither crash the migration nor lose any known data).
    private func writeV2Fixture(books: [BookProject], injectUnknownField: Bool = false) throws {
        var jsonBooks = try JSONSerialization.jsonObject(with: JSONEncoder().encode(books)) as? [[String: Any]] ?? []
        if injectUnknownField, !jsonBooks.isEmpty {
            jsonBooks[0]["futurePhase9Field"] = "noch unbekannt"
        }
        let data = try JSONSerialization.data(withJSONObject: jsonBooks)
        try data.write(to: LibraryLayout.legacyLibraryURL(work), options: .atomic)
    }

    // MARK: - Round-trip

    func testMigrationRoundTripsAllFields() throws {
        let books = makeFixtureBooks()
        try writeV2Fixture(books: books)

        let result = LibraryMigrator.migrateIfNeeded(root: work)
        XCTAssertEqual(result, .migrated(bookCount: 3))

        let store = LibraryStore(root: work)
        XCTAssertTrue(store.books.count == 3, "v3 store must list all migrated books")

        for original in books {
            let migrated = try XCTUnwrap(store.book(id: original.id), "Buch fehlt nach Migration: \(original.title)")
            XCTAssertEqual(migrated.title, original.title)
            XCTAssertEqual(migrated.author, original.author)
            XCTAssertEqual(migrated.sourceType, original.sourceType)
            XCTAssertEqual(migrated.sourceURL, original.sourceURL)
            XCTAssertEqual(migrated.mode, original.mode)
            XCTAssertEqual(migrated.documentType, original.documentType)
            XCTAssertEqual(migrated.status, original.status)
            XCTAssertEqual(migrated.engineID, original.engineID)
            XCTAssertEqual(migrated.voice, original.voice)
            XCTAssertEqual(migrated.speechSpeed, original.speechSpeed, accuracy: 0.0001)
            XCTAssertEqual(migrated.detectedLanguageCode, original.detectedLanguageCode)
            XCTAssertEqual(migrated.narratorLabel, original.narratorLabel)
            XCTAssertEqual(migrated.sourceNote, original.sourceNote)
            XCTAssertEqual(migrated.outputFormat, original.outputFormat)
            XCTAssertEqual(migrated.summarizationBudget, original.summarizationBudget)
            XCTAssertEqual(migrated.topic, original.topic)
            XCTAssertEqual(migrated.folderID, original.folderID)
            XCTAssertEqual(migrated.createdAt.timeIntervalSince1970, original.createdAt.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertEqual(migrated.chapters.count, original.chapters.count)
            for (a, b) in zip(original.chapters, migrated.chapters) {
                XCTAssertEqual(b.id, a.id)
                XCTAssertEqual(b.title, a.title)
                XCTAssertEqual(b.order, a.order)
                XCTAssertEqual(b.rawText, a.rawText, "rawText muss identisch sein")
                XCTAssertEqual(b.cleanedText, a.cleanedText, "cleanedText muss identisch sein")
                XCTAssertEqual(b.summarizedText, a.summarizedText)
                XCTAssertEqual(b.audioStatus, a.audioStatus)
                XCTAssertEqual(b.audioDurationSeconds ?? -1, a.audioDurationSeconds ?? -1, accuracy: 0.001)
                XCTAssertEqual(b.audioSegments, a.audioSegments)
            }
            XCTAssertEqual(migrated.sourceChapters?.map(\.cleanedText), original.sourceChapters?.map(\.cleanedText))
            XCTAssertEqual(migrated.rawImportedChapters?.map(\.cleanedText), original.rawImportedChapters?.map(\.cleanedText))
            if let originalCover = original.coverImageData {
                let migratedCover = try XCTUnwrap(migrated.coverImageData, "Cover fehlt nach Migration")
                XCTAssertNotNil(NSImage(data: migratedCover), "Cover muss als Bild dekodierbar sein")
                XCTAssertEqual(
                    NSImage(data: migratedCover)?.size.width,
                    NSImage(data: originalCover)?.size.width,
                    "Cover-Breite muss erhalten bleiben"
                )
            }
        }
    }

    // MARK: - Dedupe

    func testMigrationDedupesRawTextAndIdenticalSourceChapters() throws {
        let books = makeFixtureBooks()
        try writeV2Fixture(books: books)
        XCTAssertEqual(LibraryMigrator.migrateIfNeeded(root: work), .migrated(bookCount: 3))

        // rawText == cleanedText → not stored twice in text/chapters.json.
        let plainID = books[0].id
        let textsURL = LibraryLayout.chapterTextsURL(work, bookID: plainID)
        let records = try LibraryLayout.decodeChapterTexts(Data(contentsOf: textsURL))
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].rawText, nil, "rawText == cleanedText darf nicht doppelt gespeichert werden")
        XCTAssertEqual(records[0].cleanedText, books[0].chapters[0].cleanedText)
        XCTAssertNotNil(records[1].rawText, "abweichender rawText muss gespeichert bleiben")

        // sourceChapters == rawImportedChapters → nur eine Datei (raw.json).
        let sameRawID = books[1].id
        XCTAssertTrue(FileManager.default.fileExists(atPath: LibraryLayout.rawChaptersURL(work, bookID: sameRawID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: LibraryLayout.sourceChaptersURL(work, bookID: sameRawID).path),
                       "identische sourceChapters dürfen nicht als zweite Datei landen")

        // Und unterschiedliche Arrays bleiben zwei Dateien.
        let distinctID = books[2].id
        XCTAssertTrue(FileManager.default.fileExists(atPath: LibraryLayout.sourceChaptersURL(work, bookID: distinctID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: LibraryLayout.rawChaptersURL(work, bookID: distinctID).path))

        // Hydration stellt rawText aus cleanedText wieder her.
        let store = LibraryStore(root: work)
        let hydrated = store.book(id: plainID)!
        XCTAssertEqual(hydrated.chapters[0].rawText, hydrated.chapters[0].cleanedText)
    }

    // MARK: - Backup

    func testMigrationCreatesPermanentAndDatedBackup() throws {
        let books = makeFixtureBooks()
        try writeV2Fixture(books: books)
        let originalData = try Data(contentsOf: LibraryLayout.legacyLibraryURL(work))

        XCTAssertEqual(LibraryMigrator.migrateIfNeeded(root: work), .migrated(bookCount: 3))

        let backupURL = LibraryLayout.legacyBackupURL(work)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path), "dauerhaftes Backup fehlt")
        XCTAssertEqual(try Data(contentsOf: backupURL), originalData, "Backup muss dem Original entsprechen")

        let backupsRoot = work.appendingPathComponent("backups", isDirectory: true)
        let dated = try FileManager.default.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(dated.count, 1, "datierte Backup-Kopie fehlt")
        let files = try FileManager.default.contentsOfDirectory(at: dated[0], includingPropertiesForKeys: nil)
        XCTAssertEqual(files.first?.lastPathComponent, "library.json")
        XCTAssertEqual(try Data(contentsOf: files[0]), originalData)

        XCTAssertFalse(FileManager.default.fileExists(atPath: LibraryLayout.legacyLibraryURL(work).path),
                      "nach erfolgreicher Migration ist die v2-Datei abgelöst")
    }

    // MARK: - Abort

    func testAbortedMigrationLeavesV2Unchanged() throws {
        let books = makeFixtureBooks()
        try writeV2Fixture(books: books)
        let originalData = try Data(contentsOf: LibraryLayout.legacyLibraryURL(work))

        XCTAssertThrowsError(try LibraryMigrator.migrate(root: work, abortAfterBooks: 1))

        XCTAssertTrue(FileManager.default.fileExists(atPath: LibraryLayout.legacyLibraryURL(work).path),
                      "v2-Datei muss nach Abbruch unverändert existieren")
        XCTAssertEqual(try Data(contentsOf: LibraryLayout.legacyLibraryURL(work)), originalData)
        XCTAssertFalse(LibraryLayout.hasV3Index(work), "kein index.json nach Abbruch — App startet mit v2-Daten")

        // The store falls back to v2 mode and serves the full data.
        let store = LibraryStore(root: work)
        XCTAssertEqual(store.books.count, 3)
        XCTAssertEqual(store.book(id: books[1].id)?.chapters.first?.cleanedText, books[1].chapters.first?.cleanedText)

        // A retry completes the migration.
        XCTAssertEqual(LibraryMigrator.migrateIfNeeded(root: work), .migrated(bookCount: 3))
    }

    // MARK: - Idempotence

    func testSecondStartDoesNotMigrateAgain() throws {
        try writeV2Fixture(books: makeFixtureBooks())
        XCTAssertEqual(LibraryMigrator.migrateIfNeeded(root: work), .migrated(bookCount: 3))
        XCTAssertEqual(LibraryMigrator.migrateIfNeeded(root: work), .notNeeded, "zweiter Start darf nicht erneut migrieren")
        XCTAssertEqual(LibraryMigrator.migrateIfNeeded(root: work), .notNeeded)
    }

    func testMissingV2FileIsNotNeeded() {
        XCTAssertEqual(LibraryMigrator.migrateIfNeeded(root: work), .notNeeded)
    }

    // MARK: - Unknown fields

    func testUnknownFieldsDoNotBreakMigrationOrLoseData() throws {
        let books = makeFixtureBooks()
        try writeV2Fixture(books: books, injectUnknownField: true)

        XCTAssertEqual(LibraryMigrator.migrateIfNeeded(root: work), .migrated(bookCount: 3))

        let store = LibraryStore(root: work)
        let first = try XCTUnwrap(store.book(id: books[0].id))
        XCTAssertEqual(first.title, books[0].title)
        XCTAssertEqual(first.chapters.count, 2)
        XCTAssertEqual(first.chapters[1].cleanedText, books[0].chapters[1].cleanedText,
                       "bekannte Felder dürfen durch unbekannte Felder nicht verloren gehen")
    }

    // MARK: - v3 store operation

    func testV3StoreUpsertsOnlyChangedBookAndKeepsOthers() throws {
        try writeV2Fixture(books: makeFixtureBooks())
        _ = LibraryMigrator.migrateIfNeeded(root: work)

        let store = LibraryStore(root: work)
        var changed = try XCTUnwrap(store.book(id: store.books[1].id))
        changed.lastErrorMessage = "neuer Fehler"
        store.upsert(changed)
        store.flush()
        let reread = LibraryStore(root: work)
        XCTAssertEqual(reread.book(id: changed.id)?.lastErrorMessage, "neuer Fehler")
        XCTAssertEqual(reread.book(id: store.books[0].id)?.title, store.books[0].title, "unverändertes Buch muss erhalten bleiben")
        XCTAssertEqual(reread.books.count, 3)

        // Remove drops the book and its directory.
        let removed = try XCTUnwrap(reread.book(id: reread.books[2].id))
        reread.remove(removed)
        reread.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: LibraryLayout.bookDirectory(work, bookID: removed.id).path))
        XCTAssertEqual(LibraryStore(root: work).books.count, 2)
    }
}
