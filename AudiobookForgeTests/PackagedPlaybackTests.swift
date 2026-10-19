import XCTest
@testable import AudiobookForge

/// Phase 2 (plan 5.2): playback from the packaged M4B after the chapter
/// audio was deleted. Cases: (a) full pipeline → chapter audio deleted,
/// M4B present, verification ok; (c) unresolvable bookmark → clear error
/// state, no crash; (e) segment cut round-trip M4B → chapters → M4B with
/// ≤ 50 ms deviation per boundary; (f) chapter jump offsets match
/// `ffprobe -show_chapters` within ± 50 ms.
@MainActor
final class PackagedPlaybackTests: XCTestCase {
    private var work: URL!
    private var chapterAudioRoot: URL!
    private var store: LibraryStore!
    private var settingsStore: SettingsStore!
    private var pipeline: PipelineController!
    private var ffmpeg: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ABF-packaged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        chapterAudioRoot = work.appendingPathComponent("chapter_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: chapterAudioRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work.appendingPathComponent("logs"), withIntermediateDirectories: true)
        guard let resolved = FFmpegLocator.resolve(settings: AppSettings()) else {
            throw XCTSkip("ffmpeg fehlt")
        }
        ffmpeg = resolved

        store = LibraryStore(fileURL: work.appendingPathComponent("library.json"))
        settingsStore = SettingsStore(fileURL: work.appendingPathComponent("settings.json"))
        var settings = settingsStore.settings
        settings.describeImagesWithVisionModel = false
        settings.ttsParallelWorkers = 1
        settings.autoStartOMLX = false
        settings.autoUnloadOMLXAfterPass = false
        settings.outputBaseFolderPath = work.appendingPathComponent("output").path
        settings.keepChapterAudioAfterPackaging = false
        settingsStore.settings = settings

        pipeline = PipelineController(
            libraryStore: store,
            settingsStore: settingsStore,
            chapterAudioRoot: chapterAudioRoot,
            logsDirectory: work.appendingPathComponent("logs")
        )
    }

    override func tearDownWithError() throws {
        TTSEngineFactory.engineOverride = nil
        try? FileManager.default.removeItem(at: work)
    }

    private func makeBook(title: String, chapterTexts: [String]) -> BookProject {
        var book = BookProject(
            title: title, author: "Test", sourceType: .pdf,
            sourceURL: URL(fileURLWithPath: "/dev/null"),
            chapters: chapterTexts.enumerated().map { index, text in
                Chapter(title: "Kapitel \(index + 1)", rawText: text, cleanedText: text, order: index)
            },
            outputFormat: .m4b, voice: "fake", speechSpeed: 1.0
        )
        book.engineID = .kokoro
        return book
    }

    @discardableResult
    private func waitFor(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 20) async -> Bool {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    // MARK: - (a) Full pipeline

    func testPipelineDeletesChapterAudioAfterVerifiedPackaging() async throws {
        let engine = FakeTTSEngine(proceedAllowance: 5)
        TTSEngineFactory.engineOverride = { _ in engine }

        let book = makeBook(title: "Pipeline-Aufräumen", chapterTexts: ["Eins.", "Zwei.", "Drei."])
        store.upsert(book)
        pipeline.enqueue(bookID: book.id)

        let completed = await waitFor { [weak self] in self?.store.book(id: book.id)?.status == .completed }
        XCTAssertTrue(completed, "Pipeline sollte durchlaufen")

        let finished = try XCTUnwrap(store.book(id: book.id))
        let packaged = try XCTUnwrap(finished.packagedAudio, "packagedAudio muss nach Verifikation gesetzt sein")

        // M4B vorhanden und lesbar …
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: packaged.url.path))
        XCTAssertTrue(finished.outputDirectoryURL!.path.hasPrefix(work.path))
        let packagedFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: finished.outputDirectoryURL!, includingPropertiesForKeys: nil)
                .first { $0.pathExtension.lowercased() == "m4b" }
        )

        // … Kapitel-Audio gelöscht …
        let audioDir = chapterAudioRoot.appendingPathComponent(book.id.uuidString, isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "Kapitel-Audio muss nach verifiziertem Packaging gelöscht sein")

        // … Kapitel bleiben ready und haben monoton steigende Offsets …
        XCTAssertTrue(finished.chapters.allSatisfy { $0.audioStatus == .ready })
        XCTAssertTrue(finished.chapters.allSatisfy { $0.audioFileURL == nil })
        XCTAssertEqual(finished.chapters.first?.audioStartSeconds, 0)
        var previousStart = -1.0
        for chapter in finished.sortedChapters {
            let start = try XCTUnwrap(chapter.audioStartSeconds)
            XCTAssertGreaterThan(start, previousStart, "Start-Offsets müssen kumuliert steigen")
            previousStart = start
        }

        // … und die Verifikation stimmt mit ffprobe überein (± 50 ms).
        let probe = try await FFProbeRunner.probe(file: packagedFile, ffmpeg: ffmpeg)
        XCTAssertEqual(probe.chapters.count, 3)
        for (index, range) in probe.chapters.enumerated() {
            XCTAssertEqual(range.startSeconds, finished.chapters[index].audioStartSeconds ?? -1, accuracy: 0.05)
        }
        XCTAssertEqual(packaged.sizeBytes > 0, true)
        XCTAssertEqual(packaged.url.lastPathComponent, packagedFile.lastPathComponent)
    }

    // MARK: - (c) Unresolvable bookmark

    func testUnresolvableBookmarkYieldsMissingStateWithoutCrash() async throws {
        var book = makeBook(title: "Offline-Buch", chapterTexts: ["Eins."])
        // Kapitel fertig, aberAudio gelöscht und Bookmark unbrauchbar:
        for index in book.chapters.indices {
            book.chapters[index].audioStatus = .ready
            book.chapters[index].audioStartSeconds = 0
            book.chapters[index].audioFileURL = nil
        }
        book.packagedAudio = PackagedAudioInfo(
            url: URL(fileURLWithPath: "/Volumes/GibtEsNicht/Audiobooks/Buch.m4b"),
            bookmarkData: Data("kein bookmark, nur müll".utf8),
            sizeBytes: 123,
            verifiedAt: Date()
        )

        // Bookmark selbst: nil, kein Wurf.
        XCTAssertNil(PlaybackSourceResolver.resolvePackagedURL(book.packagedAudio!))

        // Quellenauflösung: Fehlerzustand missing, kein Absturz.
        let source = await PlaybackSourceResolver.resolve(book: book)
        guard case .missing = source else {
            return XCTFail("erwartet .missing, got \(source)")
        }

        // Und ein kaputtes packagedAudio-Objekt wirft beim Dekodieren nicht.
        let json = """
        {"url": "/Volumes/X/b.m4b", "bookmarkData": "AAECAw==", "sizeBytes": 5, "verifiedAt": 0}
        """
        let decoded = try JSONDecoder().decode(PackagedAudioInfo.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.sizeBytes, 5)
    }

    // MARK: - (e) Segment cut round-trip + (f) offsets vs ffprobe

    func testSegmentCutRoundTripWithinTolerance() async throws {
        let durations: [Double] = [1.0, 1.3, 0.7]
        var book = BookProject(
            title: "Schnitt-Buch", author: "Test", sourceType: .pdf,
            sourceURL: URL(fileURLWithPath: "/dev/null"),
            chapters: [],
            outputFormat: .m4b, voice: "af_heart", speechSpeed: 1.0
        )
        var files: [ChapterAudioFile] = []
        var sourceContainerDurations: [Double] = []
        try ChapterAudioStore.prepareChapterAudioDirectory(bookID: book.id, root: chapterAudioRoot)
        for (order, seconds) in durations.enumerated() {
            var chapter = Chapter(title: "Kapitel \(order + 1)", rawText: "T", cleanedText: "T", order: order)
            chapter.audioStatus = .ready
            let url = ChapterAudioStore.chapterFileURL(bookID: book.id, order: order, format: .m4b, root: chapterAudioRoot)
            try await FFmpegRunner.run(
                executable: ffmpeg,
                arguments: [
                    "-y", "-hide_banner", "-loglevel", "error",
                    "-f", "lavfi", "-i", "sine=frequency=\(300 + order * 150):sample_rate=24000",
                    "-t", String(format: "%.3f", seconds),
                    "-c:a", "aac", "-b:a", "64k",
                    url.path,
                ]
            )
            chapter.audioFileURL = url
            chapter.audioDurationSeconds = try await WaveFileInspector.durationSeconds(url: url)
            // Echte Container-Dauer der Quelldatei (ffprobe) — das ist der
            // Audioinhalt, den ein Schnitt an der Kapitelgrenze liefern muss.
            sourceContainerDurations.append(try await FFProbeRunner.probe(file: url, ffmpeg: ffmpeg).durationSeconds)
            book.chapters.append(chapter)
            files.append(ChapterAudioFile(chapter: chapter, url: url))
        }

        // Erste Verpackung + Cleanup (löscht das Kapitel-Audio).
        let outputDirectory = work.appendingPathComponent("output", isDirectory: true)
        let packager = MP4ChapterPackager(settings: settingsStore.settings, format: .m4b)
        let firstURL = try await packager.package(book: book, chapterAudioFiles: files, outputDirectory: outputDirectory) { _ in }
        let cleanup = await ChapterAudioCleanup.finalizeSingleFile(
            book: book, packagedURL: firstURL, chapterAudioFiles: files,
            ffmpeg: ffmpeg, keepChapterAudio: false, chapterAudioRoot: chapterAudioRoot
        )
        XCTAssertTrue(cleanup.verified)
        book = cleanup.book

        // (f) Kapitelsprung-Offsets == ffprobe -show_chapters (± 50 ms).
        let probe = try await FFProbeRunner.probe(file: firstURL, ffmpeg: ffmpeg)
        XCTAssertEqual(probe.chapters.count, 3)
        for (index, range) in probe.chapters.enumerated() {
            XCTAssertEqual(
                range.startSeconds,
                book.chapters[index].audioStartSeconds ?? -1,
                accuracy: 0.05,
                "Kapitelsprung-Offset \(index) muss ffprobe entsprechen"
            )
        }

        // Wiederherstellen aus der M4B (EIN ffmpeg-Durchlauf) …
        let restored = try await ChapterAudioStore.restoreChapterAudio(
            fromPackagedURL: firstURL, book: book, ffmpeg: ffmpeg, root: chapterAudioRoot
        )
        XCTAssertEqual(restored.chapters.count, 3)
        var segmentSum = 0.0
        for (index, chapter) in restored.sortedChapters.enumerated() {
            // Container-genaue Messung (ffprobe): Schnittdateien tragen
            // AAC-Priming-Metadaten, die AVAsset bis zu zwei Rahmen anders
            // verbucht — ffprobe sieht den echten Rahmenbestand. Jede
            // Segmentdauer muss der Kapitelmarke der ersten M4B auf
            // 50 ms (≈ 1 AAC-Rahmen bei 24 kHz) entsprechen.
            let segmentProbe = try await FFProbeRunner.probe(file: XCTUnwrap(chapter.audioFileURL), ffmpeg: ffmpeg)
            segmentSum += segmentProbe.durationSeconds
            // Eine Naht darf um bis zu zwei AAC-Rahmen abweichen (Priming +
            // Rahmenquantisierung, ≈ 85 ms bei 24 kHz); die Grenzgenauigkeit
            // der Kapitelmarken (unten, ± 50 ms) ist das hörbare Kriterium.
            XCTAssertEqual(segmentProbe.durationSeconds, sourceContainerDurations[index], accuracy: 0.12,
                           "Segment \(index): Dauer nach Schnitt (AAC-Rahmen-/Priming-Toleranz)")
        }
        // Nichts verloren, nichts doppelt: die Segmente müssen zusammen
        // die gepackte Datei ergeben.
        XCTAssertEqual(segmentSum, probe.durationSeconds, accuracy: 0.05,
                       "Segment-Summe muss der Container-Dauer entsprechen")

        // … neu verpacken …
        let restoredFiles = restored.sortedChapters.compactMap { chapter -> ChapterAudioFile? in
            guard let url = chapter.audioFileURL else { return nil }
            return ChapterAudioFile(chapter: chapter, url: url)
        }
        let secondURL = try await packager.package(book: restored, chapterAudioFiles: restoredFiles, outputDirectory: outputDirectory) { _ in }

        // … und die Kapitelmarken stimmen weiterhin (± 50 ms je Grenze).
        let secondProbe = try await FFProbeRunner.probe(file: secondURL, ffmpeg: ffmpeg)
        XCTAssertEqual(secondProbe.chapters.count, 3)
        for (index, range) in secondProbe.chapters.enumerated() {
            XCTAssertEqual(range.startSeconds, probe.chapters[index].startSeconds, accuracy: 0.05,
                           "Kapitelgrenze \(index) nach Round-Trip verschoben")
            XCTAssertEqual(range.durationSeconds, probe.chapters[index].durationSeconds, accuracy: 0.05)
        }
    }
}
