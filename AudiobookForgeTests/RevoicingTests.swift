import XCTest
@testable import AudiobookForge

/// v4 re-voicing: snapshot/reset, restore after failure, position mapping.
/// Uses a temporary chapter-audio root only.
final class RevoicingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("abf-revoice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBook(mode: ProcessingMode = .transcription) -> BookProject {
        var book = BookProject(title: "Test", author: "Autor", sourceType: .epub, sourceURL: URL(fileURLWithPath: "/dev/null"),
                               chapters: [], outputFormat: .m4b, voice: "af_heart", speechSpeed: 1.0)
        book.engineID = .kokoro
        book.mode = mode
        book.status = .completed
        var a = Chapter(title: "Eins", rawText: "A", cleanedText: "Text eins. [[Abbildung]]", order: 0)
        a.audioStatus = .ready; a.audioDurationSeconds = 100; a.audioFileURL = URL(fileURLWithPath: "/out/01.mp3")
        a.summarizedText = mode == .summary ? "Kurz eins." : nil
        var b = Chapter(title: "Zwei", rawText: "B", cleanedText: "Text zwei.", order: 1)
        b.audioStatus = .ready; b.audioDurationSeconds = 50; b.audioFileURL = URL(fileURLWithPath: "/out/02.mp3")
        b.summarizedText = mode == .summary ? "Kurz zwei." : nil
        book.chapters = [a, b]
        if mode == .summary {
            book.sourceChapters = [Chapter(title: "Original", rawText: "O", cleanedText: "Original lang.", order: 0)]
        }
        return book
    }

    func testPrepareKeepsTextResetsAudioAndRemembersOldNarration() {
        var book = makeBook(mode: .summary)
        Revoicing.prepare(&book, engine: .phonon, voice: "de/Henrik", speed: 1.1, resummarize: false, chapterAudioRoot: root)
        XCTAssertEqual(book.engineID, .phonon)
        XCTAssertEqual(book.voice, "de/Henrik")
        XCTAssertEqual(book.chapters.map(\.summarizedText), ["Kurz eins.", "Kurz zwei."], "LLM-Text bleibt")
        XCTAssertEqual(book.chapters.first?.cleanedText, "Text eins. [[Abbildung]]", "Bildbeschreibung bleibt")
        XCTAssertTrue(book.chapters.allSatisfy { $0.audioStatus == .pending && $0.audioFileURL == nil })
        XCTAssertEqual(book.revoiceBackup?.engineID, .kokoro)
        XCTAssertEqual(book.revoiceBackup?.chapters.first?.audioFileURL?.path, "/out/01.mp3")
    }

    func testResummarizeStartsFromTheOriginalDocument() {
        var book = makeBook(mode: .summary)
        Revoicing.prepare(&book, engine: .phonon, voice: "de/Nele", speed: 1, resummarize: true, chapterAudioRoot: root)
        XCTAssertEqual(book.chapters.map(\.title), ["Original"])
        XCTAssertNil(book.chapters.first?.summarizedText)
    }

    func testRestorePutsEverythingBack() {
        let original = makeBook()
        var book = original
        Revoicing.prepare(&book, engine: .phonon, voice: "de/Nele", speed: 1, resummarize: false, chapterAudioRoot: root)
        book.status = .failed
        Revoicing.restore(&book, chapterAudioRoot: root)
        XCTAssertNil(book.revoiceBackup)
        XCTAssertEqual(book.engineID, original.engineID)
        XCTAssertEqual(book.voice, original.voice)
        XCTAssertEqual(book.status, .completed)
        XCTAssertEqual(book.chapters, original.chapters)
    }

    func testChapterAudioInAppFolderIsMovedAsideAndBack() throws {
        var book = makeBook()
        let live = root.appendingPathComponent(book.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let file = live.appendingPathComponent("000.m4a")
        try Data("old".utf8).write(to: file)
        book.chapters[0].audioFileURL = file
        Revoicing.prepare(&book, engine: .phonon, voice: "de/Nele", speed: 1, resummarize: false, chapterAudioRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "neuer Lauf kann alte Datei nicht überschreiben")
        // The new run writes a partial file into the live folder, then fails.
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: file)
        Revoicing.restore(&book, chapterAudioRoot: root)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old")
        XCTAssertEqual(book.chapters[0].audioFileURL?.path, file.path)
    }

    func testBackupIsWrittenToDiskSoACrashCanStillRestore() throws {
        var book = makeBook()
        Revoicing.prepare(&book, engine: .phonon, voice: "de/Nele", speed: 1, resummarize: false, chapterAudioRoot: root)
        try LibraryLayout.writeBook(book, root: root)
        // Chapter status updates during the run rewrite only book.json —
        // the backup (with all segment texts) is not part of it.
        try LibraryLayout.writeBook(book, root: root, writeTexts: false)
        let metadata = try String(contentsOf: LibraryLayout.bookMetadataURL(root, bookID: book.id), encoding: .utf8)
        XCTAssertFalse(metadata.contains("revoiceBackup"))
        var stored = try XCTUnwrap(LibraryLayout.readBook(bookID: book.id, root: root))
        LibraryLayout.hydrate(&stored, root: root)
        XCTAssertEqual(stored.revoiceBackup?.engineID, .kokoro)
        XCTAssertEqual(stored.revoiceBackup?.chapters.count, 2)
        // Committed/restored: the backup file goes away with the next text write.
        book.revoiceBackup = nil
        try LibraryLayout.writeBook(book, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LibraryLayout.revoiceBackupURL(root, bookID: book.id).path))
    }

    func testPositionKeepsChapterAndShare() throws {
        let saved = PlaybackProgressStore.Saved(chapterIndex: 1, time: 25, isAbsolute: false, lastPlayedAt: nil)
        let mapped = try XCTUnwrap(Revoicing.mapPosition(saved, oldDurations: [100, 50], newDurations: [80, 40], newIsPackaged: false))
        XCTAssertEqual(mapped.chapterIndex, 1)
        XCTAssertEqual(mapped.time, 20, accuracy: 0.001)
        let packaged = try XCTUnwrap(Revoicing.mapPosition(saved, oldDurations: [100, 50], newDurations: [80, 40], newIsPackaged: true))
        XCTAssertTrue(packaged.isAbsolute)
        XCTAssertEqual(packaged.time, 100, accuracy: 0.001)
    }

    func testPositionFollowsBookShareWhenChaptersChange() throws {
        let saved = PlaybackProgressStore.Saved(chapterIndex: 0, time: 75, isAbsolute: true, lastPlayedAt: nil)
        let mapped = try XCTUnwrap(Revoicing.mapPosition(saved, oldDurations: [100, 50], newDurations: [30, 30, 30], newIsPackaged: false))
        XCTAssertEqual(mapped.chapterIndex, 1)
        XCTAssertEqual(mapped.time, 15, accuracy: 0.001)
    }

    func testCommitMapsSavedPositionAndClearsBackup() {
        let defaults = UserDefaults(suiteName: "abf-revoice-\(UUID().uuidString)")!
        var book = makeBook()
        PlaybackProgressStore.save(.init(chapterIndex: 0, time: 50, isAbsolute: false, lastPlayedAt: nil), bookID: book.id, defaults: defaults)
        Revoicing.prepare(&book, engine: .phonon, voice: "de/Nele", speed: 1, resummarize: false, chapterAudioRoot: root)
        book.chapters[0].audioDurationSeconds = 200
        book.chapters[1].audioDurationSeconds = 100
        book.status = .completed
        Revoicing.commit(&book, chapterAudioRoot: root, defaults: defaults)
        XCTAssertNil(book.revoiceBackup)
        XCTAssertEqual(PlaybackProgressStore.load(bookID: book.id, defaults: defaults)?.time ?? 0, 100, accuracy: 0.001)
    }
}

/// v4 regression: a freshly imported book must persist its chapter texts
/// even when it is looked up (hydrated) before the first flush.
@MainActor
final class LibraryStoreNewBookTextTests: XCTestCase {
    func testNewBookTextsSurviveLookupBeforeFlushAndReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abf-lib-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Start from an existing v3 library (index present), as in the app.
        let store = LibraryStore(root: root)
        var seed = BookProject(title: "Alt", author: "A", sourceType: .epub, sourceURL: URL(fileURLWithPath: "/dev/null"),
                               chapters: [Chapter(title: "K", rawText: "Alt.", cleanedText: "Alt.", order: 0)],
                               outputFormat: .m4b, voice: "af_heart", speechSpeed: 1)
        seed.status = .completed
        store.upsert(seed)
        store.flush()
        _ = LibraryMigrator.migrateIfNeeded(root: root)
        XCTAssertTrue(LibraryLayout.hasV3Index(root))

        let reopened = LibraryStore(root: root)
        let book = BookProject(title: "Neu", author: "A", sourceType: .epub, sourceURL: URL(fileURLWithPath: "/dev/null"),
                               chapters: [Chapter(title: "Kapitel", rawText: "Roh.", cleanedText: "Ein ganzer Satz.", order: 0)],
                               outputFormat: .m4b, voice: "af_heart", speechSpeed: 1)
        reopened.upsert(book)
        _ = reopened.book(id: book.id)
        reopened.flush()

        let fresh = LibraryStore(root: root)
        XCTAssertEqual(fresh.book(id: book.id)?.chapters.first?.cleanedText, "Ein ganzer Satz.")
    }
}

/// v4.1: an interrupted re-voicing (crash) is rolled back at launch.
@MainActor
final class RevoiceCrashRecoveryTests: XCTestCase {
    func testInterruptedRevoicingIsRestoredAtLaunchButPausedIsKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abf-recover-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root.appendingPathComponent("library", isDirectory: true))
        let settings = SettingsStore(fileURL: root.appendingPathComponent("settings.json"))
        func makeBook(_ title: String) -> BookProject {
            var book = BookProject(title: title, author: "A", sourceType: .epub, sourceURL: URL(fileURLWithPath: "/dev/null"),
                                   chapters: [Chapter(title: "K", rawText: "Text.", cleanedText: "Text.", order: 0)],
                                   outputFormat: .mp3Chapters, voice: "af_heart", speechSpeed: 1)
            book.engineID = .kokoro
            book.status = .completed
            book.chapters[0].audioStatus = .ready
            book.chapters[0].audioDurationSeconds = 10
            return book
        }
        var crashed = makeBook("Abgestürzt")
        Revoicing.prepare(&crashed, engine: .phonon, voice: "de/Nele", speed: 1, resummarize: false,
                          chapterAudioRoot: root.appendingPathComponent("chapter_audio"))
        crashed.status = .processing
        var paused = makeBook("Pausiert")
        Revoicing.prepare(&paused, engine: .phonon, voice: "de/Nele", speed: 1, resummarize: false,
                          chapterAudioRoot: root.appendingPathComponent("chapter_audio"))
        paused.status = .paused
        library.upsert(crashed)
        library.upsert(paused)
        library.flush()

        let controller = PipelineController(libraryStore: library, settingsStore: settings,
                                            chapterAudioRoot: root.appendingPathComponent("chapter_audio"))
        let restored = controller.recoverInterruptedRevoicing()
        XCTAssertEqual(restored, [crashed.id])
        let after = try XCTUnwrap(library.book(id: crashed.id))
        XCTAssertEqual(after.engineID, .kokoro)
        XCTAssertEqual(after.status, .completed)
        XCTAssertNil(after.revoiceBackup)
        XCTAssertNotNil(after.lastErrorMessage)
        XCTAssertNotNil(library.book(id: paused.id)?.revoiceBackup, "pausierte Neuvertonung bleibt fortsetzbar")
    }
}
