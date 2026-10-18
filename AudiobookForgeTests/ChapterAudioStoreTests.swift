import XCTest
@testable import AudiobookForge

/// Verifies the chapter audio housekeeping of the storage rework: chapter
/// files are small and compressed, deleting a book deletes its chapter
/// audio, orphaned directories are swept, and legacy WAV chapters from the
/// old pipeline are migrated to the compressed format once.
///
/// All tests run against an isolated temporary root — housekeeping must
/// never touch the developer's real chapter_audio directory.
final class ChapterAudioStoreTests: XCTestCase {
    private var settings: AppSettings!
    private var root: URL!

    override func setUp() {
        super.setUp()
        settings = AppSettings()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chapter-store-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testChapterFileURLMatchesOutputFormat() {
        let bookID = UUID()
        let m4aURL = ChapterAudioStore.chapterFileURL(bookID: bookID, order: 7, format: .m4b, root: root)
        XCTAssertEqual(m4aURL.lastPathComponent, "007.m4a")
        XCTAssertTrue(m4aURL.path.contains(bookID.uuidString))
        XCTAssertTrue(m4aURL.path.hasPrefix(root.path))

        let m4aAltURL = ChapterAudioStore.chapterFileURL(bookID: bookID, order: 7, format: .m4a, root: root)
        XCTAssertEqual(m4aAltURL.lastPathComponent, "007.m4a")

        let mp3URL = ChapterAudioStore.chapterFileURL(bookID: bookID, order: 12, format: .mp3Chapters, root: root)
        XCTAssertEqual(mp3URL.lastPathComponent, "012.mp3")
    }

    func testRemoveChapterAudioDeletesDirectory() throws {
        let bookID = UUID()
        let url = ChapterAudioStore.chapterFileURL(bookID: bookID, order: 0, format: .m4b, root: root)
        let directory = url.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        ChapterAudioStore.removeChapterAudio(bookID: bookID, root: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testOrphanSweepRemovesOnlyUnknownBooks() throws {
        let keepID = UUID()
        let orphanID = UUID()
        for id in [keepID, orphanID] {
            let url = ChapterAudioStore.chapterFileURL(bookID: id, order: 0, format: .m4b, root: root)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        let removed = ChapterAudioStore.removeOrphanChapterAudio(keeping: [keepID], root: root)

        XCTAssertEqual(removed, 1)
        // Assert on raw paths — chapterFileURL creates the directory as a
        // side effect and would resurrect it under the assertion.
        let keepDir = root.appendingPathComponent(keepID.uuidString, isDirectory: true)
        let orphanDir = root.appendingPathComponent(orphanID.uuidString, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keepDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanDir.path))
    }

    /// Generates a real (tiny) WAV via ffmpeg — the same kind of file the
    /// old pipeline left in every book's chapter directory.
    private func makeLegacyWAV(at url: URL) async throws {
        guard let ffmpeg = FFmpegLocator.resolve(settings: settings) else {
            throw XCTSkip("ffmpeg not found on this machine")
        }
        try await FFmpegRunner.run(executable: ffmpeg, arguments: [
            "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-ac", "1", "-ar", "22050", "-c:a", "pcm_s16le", url.path,
        ])
    }

    func testLegacyWAVMigrationTranscodesAndUpdatesBook() async throws {
        guard FFmpegLocator.resolve(settings: settings) != nil else {
            throw XCTSkip("ffmpeg not found on this machine")
        }
        let libraryFile = FileManager.default.temporaryDirectory.appendingPathComponent("library-migration-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: libraryFile) }
        let library = LibraryStore(fileURL: libraryFile)

        let bookID = UUID()
        let wavURL = ChapterAudioStore.chapterFileURL(bookID: bookID, order: 0, format: .m4b, root: root)
            .deletingLastPathComponent().appendingPathComponent("000.wav")
        try await makeLegacyWAV(at: wavURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavURL.path))
        let wavSize = try FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int ?? 0

        var chapter = Chapter(title: "Kapitel 1", rawText: "Text", cleanedText: "Text", order: 0)
        chapter.audioFileURL = wavURL
        chapter.audioStatus = .ready
        chapter.audioDurationSeconds = 1.0
        let book = BookProject(id: bookID, title: "Migrationsbuch", author: "Autor", sourceType: .pdf, sourceURL: URL(fileURLWithPath: "/dev/null"), chapters: [chapter], outputFormat: .m4b, voice: "af_heart", speechSpeed: 1.0)
        library.upsert(book)

        await ChapterAudioStore.migrateLegacyChapterAudio(libraryStore: library, settings: settings, root: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: wavURL.path), "Legacy WAV must be deleted after migration")
        let migratedURL = library.book(id: bookID)?.chapters.first?.audioFileURL
        XCTAssertEqual(migratedURL?.pathExtension, "m4a", "Chapter reference must point to the compressed file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: migratedURL?.path ?? "/nonexistent"), "Compressed chapter must exist")
        let m4aSize = try FileManager.default.attributesOfItem(atPath: migratedURL!.path)[.size] as? Int ?? 0
        XCTAssertLessThan(m4aSize, wavSize, "Migrated chapter should be smaller than the WAV")

        // A second run must be a no-op — nothing left to migrate.
        await ChapterAudioStore.migrateLegacyChapterAudio(libraryStore: library, settings: settings, root: root)
        XCTAssertEqual(library.book(id: bookID)?.chapters.first?.audioFileURL, migratedURL)
    }
}
