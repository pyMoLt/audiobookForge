import XCTest
@testable import AudiobookForge

/// Phase 2 (plan 5.2): the post-packaging cleanup only deletes chapter
/// audio after the output was verified. Cases: truncated output →
/// nothing deleted; keep-setting → nothing deleted; MP3 chapter output
/// → `chapter_audio/` is dropped and the exported files become the
/// playback source. All audio is synthetic (ffmpeg sine/silence), no TTS.
final class ChapterAudioCleanupTests: XCTestCase {
    private var work: URL!
    private var chapterAudioRoot: URL!
    private var ffmpeg: URL!
    private var settings: AppSettings!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ABF-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        chapterAudioRoot = work.appendingPathComponent("chapter_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: chapterAudioRoot, withIntermediateDirectories: true)
        guard let resolved = FFmpegLocator.resolve(settings: AppSettings()) else {
            throw XCTSkip("ffmpeg fehlt")
        }
        ffmpeg = resolved
        settings = AppSettings()
        settings.outputBaseFolderPath = work.appendingPathComponent("output").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    // MARK: - Helpers

    private func makeSineFile(url: URL, seconds: Double, frequency: Int = 440) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await FFmpegRunner.run(
            executable: ffmpeg,
            arguments: [
                "-y", "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", "sine=frequency=\(frequency):sample_rate=24000",
                "-t", String(format: "%.3f", seconds),
                "-c:a", "aac", "-b:a", "64k",
                url.path,
            ]
        )
    }

    /// Book with 3 chapters whose audio files are real (sine) files.
    private func makePackagedBook(durations: [Double]) async throws -> (BookProject, [ChapterAudioFile], URL) {
        let bookID = UUID()
        var book = BookProject(
            title: "Aufräum-Testbuch", author: "Test", sourceType: .pdf,
            sourceURL: URL(fileURLWithPath: "/dev/null"),
            chapters: [],
            outputFormat: .m4b, voice: "af_heart", speechSpeed: 1.0
        )
        book.id = bookID
        var files: [ChapterAudioFile] = []
        for (order, seconds) in durations.enumerated() {
            var chapter = Chapter(title: "Kapitel \(order + 1)", rawText: "Text \(order)", cleanedText: "Text \(order)", order: order)
            chapter.audioStatus = .ready
            let url = ChapterAudioStore.chapterFileURL(bookID: bookID, order: order, format: .m4b, root: chapterAudioRoot)
            try await makeSineFile(url: url, seconds: seconds, frequency: 300 + order * 200)
            chapter.audioFileURL = url
            chapter.audioDurationSeconds = try await WaveFileInspector.durationSeconds(url: url)
            book.chapters.append(chapter)
            files.append(ChapterAudioFile(chapter: chapter, url: url))
        }
        let outputDirectory = work.appendingPathComponent("output", isDirectory: true)
        let packager = MP4ChapterPackager(settings: settings, format: .m4b)
        let packagedURL = try await packager.package(book: book, chapterAudioFiles: files, outputDirectory: outputDirectory) { _ in }
        return (book, files, packagedURL)
    }

    private func chapterAudioExists(_ book: BookProject) -> Bool {
        (try? FileManager.default.contentsOfDirectory(
            at: chapterAudioRoot.appendingPathComponent(book.id.uuidString, isDirectory: true),
            includingPropertiesForKeys: nil
        ))?.isEmpty == false
    }

    // MARK: - Cases

    /// (b) Truncated M4B → verification fails → NOTHING is deleted and no
    /// packagedAudio reference is recorded.
    func testTruncatedOutputPreventsDeletion() async throws {
        let (book, files, packagedURL) = try await makePackagedBook(durations: [1.0, 1.3, 0.7])

        // "Schneide die Datei ab": nur ein Bruchteil bleibt übrig.
        let full = try Data(contentsOf: packagedURL)
        try full.prefix(full.count / 4).write(to: packagedURL)

        let result = await ChapterAudioCleanup.finalizeSingleFile(
            book: book, packagedURL: packagedURL, chapterAudioFiles: files,
            ffmpeg: ffmpeg, keepChapterAudio: false, chapterAudioRoot: chapterAudioRoot
        )
        XCTAssertFalse(result.verified, "abgeschnittene Datei darf nicht als verifiziert gelten")
        XCTAssertTrue(chapterAudioExists(book), "Kapitel-Audio darf bei fehlgeschlagener Verifikation nicht gelöscht werden")
        XCTAssertNil(result.book.packagedAudio)
        XCTAssertTrue(result.book.chapters.allSatisfy { $0.audioFileURL != nil })
        XCTAssertFalse(result.messages.isEmpty, "es muss eine Warnung geloggt werden")
    }

    /// (d) keepChapterAudioAfterPackaging = true → verification runs, the
    /// packaged reference is stored, but the files stay on disk.
    func testKeepSettingPreventsDeletion() async throws {
        let (book, files, packagedURL) = try await makePackagedBook(durations: [1.0, 1.3, 0.7])

        let result = await ChapterAudioCleanup.finalizeSingleFile(
            book: book, packagedURL: packagedURL, chapterAudioFiles: files,
            ffmpeg: ffmpeg, keepChapterAudio: true, chapterAudioRoot: chapterAudioRoot
        )
        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertTrue(chapterAudioExists(book), "bei behalten-Setting darf nichts gelöscht werden")
        XCTAssertNotNil(result.book.packagedAudio)
        XCTAssertTrue(result.book.chapters.allSatisfy { $0.audioFileURL != nil && $0.audioStartSeconds != nil })
    }

    /// Missing output file → not verified, nothing deleted.
    func testMissingOutputPreventsDeletion() async throws {
        let (book, files, packagedURL) = try await makePackagedBook(durations: [1.0, 1.3, 0.7])
        try FileManager.default.removeItem(at: packagedURL)

        let result = await ChapterAudioCleanup.finalizeSingleFile(
            book: book, packagedURL: packagedURL, chapterAudioFiles: files,
            ffmpeg: ffmpeg, keepChapterAudio: false, chapterAudioRoot: chapterAudioRoot
        )
        XCTAssertFalse(result.verified)
        XCTAssertTrue(chapterAudioExists(book))
    }

    /// MP3-Kapitelausgabe: the exported files in the output folder ARE the
    /// playback source — `chapter_audio/` is dropped and the chapter URLs
    /// are repointed at the exports.
    func testMP3ChapterOutputRepointsToExportedFiles() async throws {
        let bookID = UUID()
        var book = BookProject(
            title: "MP3-Buch", author: "Test", sourceType: .pdf,
            sourceURL: URL(fileURLWithPath: "/dev/null"),
            chapters: [],
            outputFormat: .mp3Chapters, voice: "af_heart", speechSpeed: 1.0
        )
        book.id = bookID
        try ChapterAudioStore.prepareChapterAudioDirectory(bookID: bookID, root: chapterAudioRoot)
        var files: [ChapterAudioFile] = []
        for order in 0..<3 {
            var chapter = Chapter(title: "Kapitel \(order + 1)", rawText: "T", cleanedText: "T", order: order)
            chapter.audioStatus = .ready
            let url = ChapterAudioStore.chapterFileURL(bookID: bookID, order: order, format: .mp3Chapters, root: chapterAudioRoot)
            try await FFmpegRunner.run(
                executable: ffmpeg,
                arguments: [
                    "-y", "-hide_banner", "-loglevel", "error",
                    "-f", "lavfi", "-i", "sine=frequency=\(300 + order * 100):sample_rate=24000",
                    "-t", "0.9", "-c:a", "libmp3lame", "-qscale:a", "2",
                    url.path,
                ]
            )
            chapter.audioFileURL = url
            chapter.audioDurationSeconds = try await WaveFileInspector.durationSeconds(url: url)
            book.chapters.append(chapter)
            files.append(ChapterAudioFile(chapter: chapter, url: url))
        }

        let outputDirectory = work.appendingPathComponent("mp3-output", isDirectory: true)
        let packager = MP3ChapterPackager(settings: settings)
        let exportedDirectory = try await packager.package(book: book, chapterAudioFiles: files, outputDirectory: outputDirectory) { _ in }

        let result = await ChapterAudioCleanup.finalizeMP3Chapters(
            book: book, outputDirectory: exportedDirectory, chapterAudioFiles: files,
            keepChapterAudio: false, chapterAudioRoot: chapterAudioRoot
        )
        XCTAssertTrue(result.verified)
        XCTAssertFalse(chapterAudioExists(book), "chapter_audio entfällt bei MP3-Kapitelausgabe")
        XCTAssertTrue(result.book.chapters.allSatisfy { chapter in
            chapter.audioFileURL?.path.hasPrefix(exportedDirectory.path) == true
        }, "audioFileURL muss auf die exportierten Dateien zeigen")
        XCTAssertTrue(result.book.chapters.allSatisfy { $0.audioStatus == .ready })
        XCTAssertGreaterThan(result.freedBytes, 0)
    }

    /// v3.2 regression: regenerating one chapter of a finished MP3 book
    /// repackages from the files IN the output folder. The packager deleted
    /// each destination before encoding — which was its own source — and
    /// "01 - …mp3" vanished from the user's audiobook.
    private func makeMP3(url: URL, seconds: Double, frequency: Int) async throws {
        try await FFmpegRunner.run(executable: ffmpeg, arguments: [
            "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "sine=frequency=\(frequency):sample_rate=24000",
            "-t", String(seconds), "-c:a", "libmp3lame", "-qscale:a", "2", url.path,
        ])
    }

    /// v4.1: chapters tagged on their first encode are moved, not copied;
    /// an untagged (legacy) chapter is still copied with tags.
    func testTaggedMP3ChaptersAreMovedNotCopied() async throws {
        var book = BookProject(title: "Verschiebe-Buch", author: "Autorin", sourceType: .pdf,
                               sourceURL: URL(fileURLWithPath: "/dev/null"), chapters: [],
                               outputFormat: .mp3Chapters, voice: "af_heart", speechSpeed: 1.0)
        let chapters = (0..<2).map { order -> Chapter in
            var chapter = Chapter(title: "Teil \(order + 1)", rawText: "T", cleanedText: "T", order: order)
            chapter.audioStatus = .ready
            chapter.audioDurationSeconds = 0.8
            return chapter
        }
        book.chapters = chapters
        let tags = ChapterAudioTags.tags(for: book, narrated: chapters)
        let tagged = work.appendingPathComponent("tagged.mp3")
        let plain = work.appendingPathComponent("plain.mp3")
        try await FFmpegRunner.run(executable: ffmpeg, arguments: [
            "-y", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=400:sample_rate=24000",
            "-t", "0.8", "-c:a", "libmp3lame", "-qscale:a", "2"] + tags[chapters[0].id]!.ffmpegArguments + [tagged.path])
        try await makeMP3(url: plain, seconds: 0.8, frequency: 500)

        var settings = AppSettings()
        settings.keepChapterAudioAfterPackaging = false
        let output = work.appendingPathComponent("out", isDirectory: true)
        _ = try await MP3ChapterPackager(settings: settings).package(
            book: book,
            chapterAudioFiles: [ChapterAudioFile(chapter: chapters[0], url: tagged), ChapterAudioFile(chapter: chapters[1], url: plain)],
            outputDirectory: output, onProgress: { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: tagged.path), "getaggtes Kapitel wurde verschoben")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plain.path), "ungetaggtes Kapitel wurde kopiert")
        let names = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        XCTAssertEqual(names, ["01 - Teil 1.mp3", "02 - Teil 2.mp3"])
        let probe = FFProbeRunner.probeURL(for: ffmpeg)
        let second = await ChapterAudioTags.readTag(of: output.appendingPathComponent("02 - Teil 2.mp3"), ffprobe: probe)
        XCTAssertEqual(second, tags[chapters[1].id])
    }

    func testRepackagingMP3FromItsOwnOutputKeepsEveryChapter() async throws {
        var book = BookProject(
            title: "MP3-Buch", author: "Test", sourceType: .pdf,
            sourceURL: URL(fileURLWithPath: "/dev/null"),
            chapters: [],
            outputFormat: .mp3Chapters, voice: "af_heart", speechSpeed: 1.0
        )
        var firstFiles: [ChapterAudioFile] = []
        for order in 0..<3 {
            var chapter = Chapter(title: "Kapitel \(order + 1)", rawText: "T", cleanedText: "T", order: order)
            chapter.audioStatus = .ready
            let url = work.appendingPathComponent("src-\(order).mp3")
            try await makeMP3(url: url, seconds: 0.8, frequency: 300 + order * 100)
            chapter.audioFileURL = url
            book.chapters.append(chapter)
            firstFiles.append(ChapterAudioFile(chapter: chapter, url: url))
        }
        let output = work.appendingPathComponent("output/MP3-Buch", isDirectory: true)
        let packager = MP3ChapterPackager(settings: settings)
        _ = try await packager.package(book: book, chapterAudioFiles: firstFiles, outputDirectory: output, onProgress: { _ in })
        let exported = try FileManager.default.contentsOfDirectory(atPath: output.path).filter { $0.hasSuffix(".mp3") }.sorted()
        XCTAssertEqual(exported.count, 3)

        // Chapter 2 regenerated; chapters 1 and 3 come from the output folder.
        let regenerated = work.appendingPathComponent("regen.mp3")
        try await makeMP3(url: regenerated, seconds: 1.2, frequency: 880)
        let secondFiles = book.sortedChapters.enumerated().map { index, chapter in
            ChapterAudioFile(chapter: chapter, url: index == 1 ? regenerated : output.appendingPathComponent(exported[index]))
        }
        _ = try await packager.package(book: book, chapterAudioFiles: secondFiles, outputDirectory: output, onProgress: { _ in })

        let after = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        XCTAssertEqual(after, exported, "every chapter still there, no staging folder left")
        for name in after {
            let size = (try FileManager.default.attributesOfItem(atPath: output.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            XCTAssertGreaterThan(size, 1000, name)
        }
    }
}
